# src/characters/animals

3D 动物：在 spawn 点周围**散养游荡**，播自带 idle/walk 动画。分两类:

- **畜牧动物**（Quaternius Farm Animals,FBX）：cow/sheep/pig/horse/llama/pug/zebra
- **野外动物**（Quaternius Ultimate Animated Animals,glTF）：wolf/fox/deer/stag/bull/donkey/alpaca/husky/shiba_inu/horse_white

> 战斗按用户决定**后置**——野外动物现在也只游荡。它们的 attack/death/hit clip 已接好但休眠
> （`WildAnimal.play_attack()/take_hit()/die()`），等人物战斗系统接入时直接调。

## 文件

| 文件 | 用途 |
|---|---|
| `animal_species.gd` | `class_name AnimalSpecies`:物种注册表 `SPECIES`,id → `{model, body_radius, body_height, move_speed, wild}` + `scene_path(id)`。**scale 不在这**(见下) |
| `animal.gd` | `class_name Animal extends CharacterBody3D`:取烘焙模型、clip 解析、散养 FSM、动画同步。**不是 Character**(无背包/饥饿/钱包/group/agent) |
| `wild_animal.gd` | `class_name WildAnimal extends Animal`:预解析战斗 clip + 占位接口,留给战斗系统 |
| `animal.tscn` | **抽象 base**:`CharacterBody3D` + Collision + Nav + **空** `Visual` + Synchronizer + SiteMarker。不直接放进世界 |
| `wild_animal.tscn` | 抽象 base,继承 `animal.tscn`、脚本换 `wild_animal.gd`(野外物种的 base) |
| `species/<id>.tscn` | **每物种一个**(cow/sheep/.../wolf/deer…),继承对应 base、把模型烘焙在 `Visual` 下、`Visual.scale` = 调好的成年缩放、`species_id` 填好。**放进世界 / spawn 用的就是它** |

## 架构

```
Animal [CharacterBody3D]      ← animal.gd（collision_layer=2 mask=25,同 NPC）
  CollisionShape3D            ← _apply_body_size 按物种体型重建胶囊
  NavigationAgent3D
  Visual [Node3D]             ← scale = 该物种成年缩放（species/<id>.tscn 里目视调好）
    Model [Node3D]            ← species 场景烘焙的模型实例（不再 runtime load）
      Armature/Skeleton3D
        <Mesh> [MeshInstance3D]
      AnimationPlayer         ← **模型自带**,带烘焙好的 clip
  MultiplayerSynchronizer     ← position/rotation/anim_state/alive
  SiteMarker                  ← Phase 1 仅占位（不注册）；Phase 3 接交互/感知时 register
```

> `animal.gd._build_visual` 取 `Visual` 下烘焙好的 `Model`(`Visual.get_child(0)`),并把 `Visual.scale.x`
> 记为成年 `_base_scale`(幼崽再按 `young_scale_mult` 折减)。裸 base 场景(无 Model)运行时 `push_error`、
> 编辑器里安静返回(允许编辑抽象 base)。

## 动画 pipeline —— 跟人物完全不同

人物（NPC）走 Mixamo + 官方 BoneMap 重定向(23 角色共用 1 skeleton + 外部 Animation res)。
**动物不需要 BoneMap**:每个 Quaternius FBX/glTF 自带 Skeleton3D + AnimationPlayer + 烘焙
clip,runtime 直接用模型自己的 AnimationPlayer 播。

两套包 clip 命名不一致,`animal.gd._resolve_clip(logical)` 吸收差异:

| logical | farm 包(FBX) | animated 包(glTF) |
|---|---|---|
| idle | `Armature\|Idle` | `Idle` |
| walk | `Armature\|Walk` | `Walk` |
| jump | `Armature\|Jump` | —（无 walk 时的兜底移动） |
| run | `Armature\|Run` | `Gallop` |
| death | `Armature\|Death` | `Death` |
| attack | —（无） | `Attack` |
| hit | — | `Idle_HitReact1/2` |

解析器按 `_CLIP_CANDIDATES`(候选基名) × `_CLIP_PREFIXES`(`""` / `Armature\|` / `AnimalArmature\|`)
组合查找,命中即缓存。**只有 idle 必需 → 缺它 `push_error`**(fail-loud)。

> **farm 包动画不齐**:`Cow`/`Horse`/`Zebra` 有完整 Idle/Walk/Run/Death;但
> **`Llama`/`Pig`/`Pug`/`Sheep` 只有 Idle + Jump,没有 Walk**(2018 老包)。所以游荡的移动 clip
> **不写死 walk,而是按 `_LOCOMOTION_PRIORITY` 排序挑该模型第一个有的**:
> `walk → walk_slow → trot → run/gallop → jump`(`_resolve_locomotion`)。Sheep 这类只剩 jump 的就
> **循环 jump + 前进 = 蹦着走**(`hop_speed` 速度档);连 jump 都没有才 `_can_wander=false` 原地 idle。
> 加新移动动作:`_CLIP_CANDIDATES` 加 logical + `_LOCOMOTION_PRIORITY` 按顺序插一行。animated 包 12 种全有 Walk。
>
> 蹄类动物(deer/bull/horse…)的攻击 clip 叫 `Attack_Headbutt`/`Attack_Kick`,犬科/狼/狐是
> 干净的 `Attack`——解析器都覆盖。

`_patch_loops` 把 idle/walk/run 设 `LOOP_LINEAR`——两套包的 clip **导入时全是 `loop=NONE`**,
不打补丁会播完停在最后一帧(看起来"动画静止")。这步只在运行时跑(编辑器跳过,免把导入的 .scn 标脏)。

> **滑步**:两套包的 walk/run 都是**原地循环**(无 root motion),身体由代码按 `move_speed` 平移。
> 视觉步幅 = 模型本地步幅 × `Visual.scale`,跟世界位移速度对不上就会滑(脚不蹬地)。`animal.gd` 用
> `_sync_locomotion_anim_speed` 让腿频跟水平速度走,残余滑步靠每物种的 `walk_cycle_speed`(species 场景
> Inspector,默认 1.0)目视调:腿看着像蹬地而非滑冰即可。要更狠就一起调 `move_speed`(注册表)。

## 缩放 / 体型

两套包导入缩放差异巨大(farm FBX ~0.01 需放大 ~6-16×;animated glTF 偏大需 ~0.15-0.6×),所以
**成年缩放逐物种存在各自的 `species/<id>.tscn` 的 `Visual` 节点上**——打开物种场景、选中 `Visual`(或它下面
的 `Model`)、**直接拖 gizmo 调 scale**,所见即所得、自动持久化。每只动物想单独调,就开它的物种场景调
`Visual.scale`(单一来源,`animal.gd` 读它当 `_base_scale`)。**注册表 `animal_species.gd` 不再存 scale**。

> ⚠️ 别去缩 town.tscn 里实例的**根节点**(CharacterBody3D)——那会连碰撞体/导航一起缩,且和这里的
> Visual 缩放打架(这正是早先 cow_demo 被设成 0.01 却不对的原因)。要调大小就开物种场景调 `Visual`。

`体型`(碰撞胶囊 + Nav 半径)仍按 `animal_species.gd` 的 `body_radius/body_height`(世界米)在运行时重建,
与视觉 scale 解耦。`_align_feet()` 自动把模型抬到「mesh 最低点 = 本体 y」,避免缩放后脚陷地/悬空。

> ⚠️ **对地必须等 skeleton pose 完**:skinned mesh 的 `get_aabb()` 在 `_ready` 当帧返回的是**未初始化
> 的小盒子**(≈0.07),不是真实包围盒(pose 一帧后才变成真实的 ~2.7)。所以 `_align_feet` 经
> `_align_feet_when_posed()` **defer 一帧**再算,否则按错误小盒子对地→**模型悬空**(羊曾悬在半空 1.6m 就是
> 这个 bug——它的 model 原点在脚下方 1.6m,frame-0 只抬了 0.07)。`_align_feet` 幂等(按当前 feet 纠到 body
> 原点),所以 _ready 当帧那次错的、defer 后重算即纠正。验证:6 只 demo 动物对地后 `mesh_min_y - body_y` 全 = 0。

## 散养游荡 FSM（`animal.gd`,server-only）

`falling → idle ↔ walking`,比 NPC 简单:
- **不走 corridor planner**(动物不需要分层寻路):`_pick_wander_target` 直接在 `_origin`
  周围 `wander_radius`(8m)内随机取点,`NavigationServer3D.map_get_closest_point` snap 到
  navmesh,`NavigationAgent3D` 走过去
- `falling`:spawn 时给较高 Y,重力落地后记 `_origin` 开始游荡
- `idle`:停 `idle_min..idle_max`(2-6s),挑下个点
- `walking`(`_tick_walk`):**镜像 `npc.gd` 的消费方式**——到达用「到 `target` 的 XZ 距离 ≤
  `target_desired_distance`」判,**不**用 `nav.is_navigation_finished()`(路径异步,刚 set_target
  的头几帧会误报完成→一起步就 idle);朝 `get_next_path_position` 走,路径点退化(没算好/末端≈当前)
  时退回直接朝 `target`,**绝不**因为「下一点≈当前」原地 idle(那是走走停停、动画在播却不动的根因)。
  另有 `_STUCK_TIMEOUT`(1.5s 无进展)兜底回 idle 重选点
- **移动 clip 按 `_LOCOMOTION_PRIORITY` 挑**(`walk → walk_slow → trot → run/gallop → jump`),
  取该模型第一个有的当 `_loco_clip` + 对应 `_loco_speed`(move/hop 档);`_patch_loops` 把它设
  LOOP_LINEAR。没 walk 的 farm 动物(Sheep/Llama/Pig/Pug)落到 **jump → 循环播+前进=蹦着挪**
  (`hop_speed`,默认 0.8)。连 jump 都没有才 `_can_wander=false` 永远原地 idle。频率/速度靠
  `hop_speed` + `walk_cycle_speed` 调
- client 是 puppet:`_physics_process` 直接 return,position/anim_state 靠 synchronizer

> **headless 跑不出游荡**:动物用 `nav.get_navigation_map()` 取默认 map,要等 navmesh tile 注册同步后
> `map_get_closest_point` 才返回真实点(否则返回 `(0,0,0)`,候选全被拒→不走)。GUI 里 NavigationServer
> 会自然同步(TownWorld 还有 canary `map_force_update` 等就绪);但 `--headless -s` / 短 `--quit-after`
> boot 里 map 常没同步完,**动物原地不动是 headless 假象,不是 bug**——验证游荡得开窗口跑。

## 放进世界

`town.tscn` 里 `Animals` Node3D 下拖 **物种场景** `species/<id>.tscn`(物种 + scale 已烘焙好),
只需在 Inspector 填 `animal_id`(根节点 transform 保持 scale=1,只改位置)。当前 demo:cow×2 + sheep×2
(畜牧)+ wolf + deer(野外)。

`AnimalSpawner`(MultiplayerSpawner)+ `Animal.from_spawn_data`(实例化 `AnimalSpecies.scene_path(id)`)
供 **Phase 2 繁殖出生**运行时 spawn;scene-placed 的 demo 动物不走 spawner(场景在两端都加载,靠各自
synchronizer 同步)。

## 加新物种

1. 模型放进对应 third-party 包(已 gitignore,手工下载)
2. `animal_species.gd` 的 `SPECIES` 加一条:`"goat": {"model": _FARM % "Goat", "body_radius": ..., ...}`
   (畜牧的还要在 `_LIFE` 加生命周期参数)
3. **建 `species/goat.tscn`**:继承 `animal.tscn`(farm) 或 `wild_animal.tscn`(野外),`species_id="goat"`,
   `Visual` 下实例化模型、`Visual.scale` 设个初值(照抄相近物种)
4. `town.tscn` 放 `species/goat.tscn` 实例,填 `animal_id`
5. 开 `species/goat.tscn` 拖 gizmo 目视调 `Visual.scale` / 在注册表调 `body_*`

## 畜牧生命周期（Phase 2）

仅**畜牧物种**（`AnimalSpecies._LIFE` 里有条目：cow/sheep/pig/horse/llama）参与；野外动物 / pug / zebra 不参与。

- **成长**：`growth_stage` young→adult，由 `spawned_at_game_hour + maturation_hours` 派生（同 crop 时间轴）。幼崽视觉按 `young_scale_mult` 缩小（synced，client 也缩）。scene 预放的 founder 默认 `start_as_adult`（放下即成年）；繁殖出生的是幼崽。
- **fed**：0..100，`AnimalSimulator` 每 game-hour 衰减；喂养回补。
- **自动繁殖**：`src/autoload/animal_simulator.gd`（autoload，订阅 `GameClock.slow_tick`，**单一写者**）每小时：fed 衰减 + 成长 + 检测同物种 ≥2 成年、喂饱（`fed≥min_breed_fed`）、邻近（≤6m）、未超 `herd_cap` → 一方受孕；孕期到点用 `AnimalSpawner` 产仔。**喂饱才会繁殖**——不喂会饿到停繁殖。
- **持久化**：`Db.animal_instances` 表（UPSERT 单一写者，镜像 farm_plots）。founder 在 `_ready` 里 `take_animal_instance` 消费自己的行；出生动物由 `town.gd._hydrate_persisted_animals` 重建。

## 畜牧操作（Phase 3）—— 做到 Character，玩家 UI + NPC tool

操作逻辑单点在 `src/characters/parts/husbandry_runner.gd`（`Character.husbandry()`），玩家与 NPC 共用（见 [[feedback_player_npc_same_character]]）：
- `feed(animal)`：消耗背包一份饲料（带 `grain`/`fodder`… 标签，如小麦）→ 抬 `fed`。
- `slaughter(animal)`：产出生肉（+皮，按物种 `_LIFE.slaughter`，young 减量）进背包，满则掉地；动物播 death、清 DB、延时 free。
- 两者都 fail-closed：要在交互半径内（SiteMarker）、活着、是牲畜。

入口：
- **玩家**：右键动物（CameraRig `_pick_animal_under`）→ `AnimalContextMenu`（喂养/宰杀）→ `town._approach_and_husbandry` 走近后 `Player.request_husbandry` RPC。
- **NPC**：backend tool `tend_animal`（`{verb, species}`）→ wire `actions.ts` → `npc` instant action → `HusbandryHandlers.run_tend_animal` 找最近同物种牲畜 → 同一个 `husbandry_runner`。当前是即时动作，NPC 需自己已在动物旁（自主感知 + 走向动物属后续 perception 集成）。

产出物品：`data/items/raw_hide.tres` + `data/materials/raw_hide.tres`（肉复用 `raw_meat`）。

## 未做 / 后续

- **战斗**：野外动物 attack/death/hit clip 已接好但休眠，等人物战斗系统驱动。
- **动物进 NPC 感知**：NPC 暂不自主"看见"动物（`tend_animal` 靠 species + 就近），完整 perception + move-to-animal（`animal:<id>` site）是后续。
- **鸡鸭鹅**：两包都没有，补模型 + 一条 `SPECIES`(+`_LIFE`) 即可。
