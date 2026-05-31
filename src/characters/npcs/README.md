# src/characters/npcs

3D NPC：能在镇里寻路漫游，带 idle/walking 动画。

## 文件

| 文件 | 用途 |
|---|---|
| `npc.gd` | `NPC extends CharacterBody3D`：状态机（falling / idle / walking）+ 漫游 + 动画切换 + 重力 |
| `npc.tscn` | `CharacterBody3D` 包一个 `FantasyKingdom_Characters.fbx` 实例（共 23 个角色 mesh 共用骨架），加 `CollisionShape3D` 胶囊 + `NavigationAgent3D` + 自带的 `AnimationPlayer`（root_node 指 `Visual`） |

## 架构

```
NPC [CharacterBody3D]      ← npc.gd
  CollisionShape3D         ← capsule h=1.79 r=0.22
  NavigationAgent3D
  Visual [Node3D]          ← instance of FantasyKingdom_Characters.fbx
    GeneralSkeleton [Skeleton3D]
      SM_Chr_* [MeshInstance3D] x23   ← script 隐藏 22 个，只显示 visible_mesh
    AnimationPlayer        ← FBX 自带，空，未用
  AnimationPlayer          ← 我们的，挂 idle.res / walking.res，root_node="../Visual"
```

不用 FK 的 `SM_Chr_*.tscn` prefab —— 那些是独立 Skeleton3D 用旧 Synty bone 名（`Hand_L` 等），跟我们 reimport 后的 humanoid 标准（`LeftHand`）对不上。直接 wrap FBX 最干净。

## 动画 pipeline

走 Godot 官方 BoneMap 重定向：源 FBX 和目标 FBX 都配 BoneMap → SkeletonProfileHumanoid + 开 BoneRenamer + 开 RestFixer/Overwrite Axis。reimport 后两边 bone 名同为 humanoid 标准（`Spine`/`LeftUpperArm`/`LeftHand`/...），rest pose 也 axis 对齐，**runtime 零数学**直接播。

资产：
- `assets/skeleton/fk_bone_map.tres` —— FK 角色用的 BoneMap（humanoid 槽 → Synty 名，如 `LeftUpperArm` ← `Shoulder_L`）。inline profile
- `assets/skeleton/mixamo_profile.tres` —— SkeletonProfileHumanoid，Mixamo FBX 的 BoneMap 引用它当 profile（避免每个 Mixamo FBX 重复创建 profile sub_resource）
- `assets/animations/*.res` —— Mixamo FBX import 时勾 save_to_file 出来的 Animation（不是 AnimationLibrary）

## 依赖

- `assets/animations/idle.res` 和 `walking.res`（Phase C reimport 产出）
- `assets/skeleton/fk_bone_map.tres` + `mixamo_profile.tres`（reimport 时 BoneMap 引用）
- `third-party/.../FantasyKingdom_Characters.fbx`（reimport 后 bone 名是 humanoid 标准）
- `third-party/.../PolygonFantasyKingdom_Mat_01_A_mat.tres`（角色材质，FBX import 不带，npc.gd 在 `_ready` 里 override）
- 同关卡需要 baked `NavigationRegion3D`（如 `town.tscn` 里的 `NavmeshTiler`），否则 `nav.is_target_reachable()` 永远 false，NPC 一直 idle

---

## 加新动画（如 Run / Jump）

1. 下载：去 Mixamo，**用 Y-Bot 或 X-Bot 这种自带角色**（不要上传 Synty 角色，会出空 track），动作选好后 download FBX (For Animation, 30fps)
2. 放到 `third-party/mixamo/Run.fbx`（路径随便，Mixamo 那个 dir 是约定）
3. Godot FileSystem 里双击 `Run.fbx` → **Advanced...**
4. 左边场景树点 **Skeleton3D**
5. 右边 Inspector：
   - **Bone Map** → New BoneMap
   - 点开它 → **Profile** → ⊃ Quick Load → 选 `res://assets/skeleton/mixamo_profile.tres`（**复用**，别新建）
   - auto-mapping 全自动对上 mixamorig_* → humanoid 槽，检查没红即可
6. **Bone Renamer** → Rename Bones ✓
7. **Unique Node** → Make Unique ✓，Skeleton Name = `GeneralSkeleton`（跟 FK 一致，否则路径不通）
8. **Rest Fixer** → 全勾（Apply Node Transform / Normalize Position / Reset All Bone Poses / Retarget Method=Overwrite Axis / Keep Global Rest）
9. **Remove Tracks** → Unmapped Bones 选 `Remove`
10. 顶部 _subresources / animations 折叠：找 **`mixamo_com`** 这条（不是 `Take 001` —— 那是 1 帧 stub），勾 `save_to_file/enabled`，path 设 `res://assets/animations/run.res`
11. **Reimport**

接入 NPC（npc.tscn）：
12. 编辑 `src/characters/npcs/npc.tscn`，AnimationLibrary 的 `_data` 加一行：
    ```
    &"Run": ExtResource("5_run"),
    ```
    并 `[ext_resource type="Animation" path="res://assets/animations/run.res" id="5_run"]`
13. 编辑 `npc.gd`，在合适状态（如 `walking` 高速时）调 `_play("Run")`。`_play` 自带"已经在播就不重启"逻辑

## 加新 FK 角色变体

不要复制 .tscn 也不要改 .tscn —— 直接在 town.tscn（或别处）放 NPC 实例，Inspector 改 `visible_mesh` 字段：
- `SM_Chr_Peasant_Male_01`（默认）
- `SM_Chr_Mage_01`、`SM_Chr_King_01`、`SM_Chr_Soldier_Male_01` 等 23 选 1

23 个完整名字：跑 `find third-party/polygon-fantasy-kingdom/Assets/PolygonFantasyKingdom/Models/extracted -name 'SM_Chr_*.mesh'` 即可看到（去掉 `.mesh` 后缀就是 mesh node 名）。

## 加非 FK 角色（不同 skeleton）

更复杂，需要：
1. 该角色的 FBX 也 reimport 配 BoneMap+Renamer+RestFixer，bone 名变 humanoid 标准
2. 复制 `npc.tscn` → 改 `Visual` 节点的 ext_resource 指向新 FBX
3. 调 CollisionShape3D 大小（不同角色身高不同）
4. `visible_mesh` 默认值改成新 FBX 里的 mesh name
5. 角色材质 path 改（`CHAR_MATERIAL` const）

如果新角色 skeleton 没配 BoneMap，跟我们 humanoid 动画完全不通用，就退化到自己一套动画 + AnimationPlayer。

## 行为

`npc.gd` 状态机：
- `falling`：spawn 时 Y 给较高位置（如 +5），重力下落，落地后等 `settle_delay`（0.5s）记录 `_origin = global_position` 然后挑新目标
- `idle`：原地播 `Idle`，等 `idle_min..idle_max` 秒（1.5–4s），挑下一个目标
- `walking`：`NavigationAgent3D.set_target_position()` + `get_next_path_position()` 沿 navmesh 走，到达后回 idle

挑目标时围绕 `_origin` 在 `wander_radius`（8m）半径内随机点，用 `NavigationServer3D.map_get_closest_point` snap 到 navmesh。最多 8 次找 reachable target，找不到就回 idle。

转身用 `lerp_angle(rotation.y, atan2(dir.x, dir.z), rotation_speed * delta)` 平滑。

## Inspector 可调

| 参数 | 默认 | 说明 |
|---|---|---|
| `visible_mesh` | `"SM_Chr_Peasant_Male_01"` | 显示哪一个 mesh（FK 23 选 1） |
| `move_speed` | 2.0 m/s | 步行速度 |
| `rotation_speed` | 8.0 rad/s | 转身速度 |
| `wander_radius` | 8.0 m | 漫游范围（围绕 spawn 落地点） |
| `idle_min`/`idle_max` | 1.5/4.0 s | 到达后停顿区间 |
| `gravity` | 9.8 | 重力，让 NPC 落到地面（spawn Y 给 +5 让它自然落地） |
| `settle_delay` | 0.5 s | 落地后等多久才开始漫游（避免 navmesh 还没 ready） |

## 跑通后扩展方向

- 区域感知：在 `_pick_new_target` 里用 `TownWorld.region_at_world(pos)` 限制在某区内或跨区行走
- 行为图：替换简单状态机为 BehaviorTree（waiting / walking / talking / working）
- LLM 驱动：`set_target_position` 由对话/计划系统决定，而不是随机
- avoidance：`NavigationAgent3D.avoidance_enabled = true` 让 NPC 互相避让
- 性能：50+ NPC 用 MultiMesh 或 LOD（idle 距离远的关动画）
