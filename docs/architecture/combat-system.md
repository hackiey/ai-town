# Combat system

> Status: **drafting v1** — 设计稿，尚无对应代码。本文是哈利波特式魔杖咒语对战的完整 schema、运行时分层和实施路径。
>
> **配套文档**：
> - [reaction-schema.md §7.4b](./reaction-schema.md) — wand_charges 概念首次落地（v4 修订）
> - [entity-model.md §2.2](./entity-model.md#22-角色资源模型) — mana 从角色属性迁到魔杖
> - [player-stats.md](./player-stats.md) — hp / stamina 数值系统、buff / condition schema
> - [runtime-layers.md §2.2](./runtime-layers.md#22-战斗-cadence) — 战斗 cadence、worker 与 godot 分层
> - [scripting-layer.md](./scripting-layer.md) — Lua VM + ScriptExecutor 公共契约
> - [two-track-agent-session.md](./two-track-agent-session.md) — LLM runtime；战斗中如何切出 / 切回
>
> **不变量**：
> - 战斗每帧 / 每 tick **永远不进 LLM**，只有 godot + lua 跑（[memory: feedback_godot_is_authority](#)）
> - 咒语是 Lua 描述的"数据"，发明新咒不动 godot 代码
> - 魔力住在魔杖（不是角色），不自回，只能仪式 / 材料补
> - 体力住在角色，被 dodge / sprint / 受击消耗，不被施法消耗

---

## 1. Context

[design-doc.md §6](../design-doc.md) 提到战斗存在（PvP / PvE 威胁、守卫），但实际机制完全空白。现有 `Character.hp` 仅被饿死减少（[game-mechanics.md §4.2](./game-mechanics.md)），从未被战斗触发。

设计目标按用户原话："**几乎完全仿照哈利波特**" —— 魔杖式、可见弹道、对射、躺地能躲、柱子能挡。体力主要给奔跑 / 闪避用，魔力来自魔杖。LLM 不能指导即时战斗（节奏太慢），所以需要传统行为树 NPC AI。咒语逻辑用 Lua 是为了发明门槛低。

本文沉淀以下决策：

- 真 3D 弹道（Area3D）vs hit-scan：选 **真 3D 弹道**，否则"躺下躲飞行咒"这种哈利波特典型场景不成立
- 魔力资源模型：**单一魔力池 + 每咒 cast_time 充当 CD**，无独立 cooldown 字段。不自回
- 输入方式：**热键 loadout**（1-N 数字键绑 4 个咒），非战斗时配置
- NPC AI：**Behavior Tree**（自己写 ~200 行轻量版，不引第三方插件）
- LLM 边界：战斗中暂停该 NPC think loop；战前 / 战后 / 长期发明新咒可用。**短期内不锁死战中 LLM 接口**，预留 source 参数给将来战术微调

---

## 2. 时间分层

战斗最大的设计风险是节奏混淆。本系统强制三层：

| 层 | 频率 | 跑在 | 责任 |
|---|---|---|---|
| **Frame** | 60 Hz `_process` | Godot 主循环 | 弹道飞行、施法动画、玩家输入、shield 命中判定、视觉特效 |
| **Fast tick** | 4 Hz（250ms） | `GameClock.fast_tick`（待实现） | BT 评估、buff/condition 倒计时、命中事件结算、HP / charges 写入 |
| **Hour tick** | 现有 | `GameClock.slow_tick` | 仪式 cooldown、wand 长期衰减（如设计） |
| **LLM async** | 异步 | brain worker | **战斗中暂停**。战前选 loadout / 决定参战；战后 perception → memory；长期研究新咒 |

**为什么弹道和结算分两层**：
- 弹道必须 60 Hz 才不丢命中
- 但 BT 每帧 evaluate 太贵且会 jitter；fast tick 是 NPC 决策的天然边界
- 命中那一刻只往队列推 `hit_event`，下个 fast tick 边界统一 apply —— 沿用 [reaction-schema.md](./reaction-schema.md) 的"边界结算"原则，避免一发弹道在两个 tick 间反复改 HP

> Fast tick 框架在 [simulation-layer.md §2.1](./simulation-layer.md) 已设计但 Godot runtime 尚未实现；本系统是 fast tick 的第一个消费者，需要补落地。

---

## 3. 资源模型

| 资源 | 归属 | 上限 | 消耗 | 恢复 |
|---|---|---|---|---|
| **HP** | `Character.hp` | 100（`max_hp` 可改） | 受击 | 仪式 / 药水 / 医生；战后**不自回** |
| **Stamina** | `Character.stamina` | 100（动态 cap，受 hunger/rest 压低，见 [player-stats.md §3](./player-stats.md)） | dodge-roll（-25）、sprint（持续 drain）、被击退（-10） | 慢速自回（已有） |
| **Wand charges** | `wand.properties["charges"]`（实例字段） | wand 实例字段 `max_charges`，由 core 材质决定（meteor_iron 200 / moonstone 150 / oak 100 / crystal 50） | 每咒 `Spell.charge_cost` | **只靠仪式 / 魔法石 / 药水**，不自回 |

**关键决策**：

1. **施法不吃 stamina**，魔力来自魔杖、体力是身体的事，两条轴独立。"打不过就跑（stamina）"和"魔力没了（charges）"是不同战术决策。
2. **HP = 0 → Knockdown**（倒地一段时间后 1 HP 起身，倒地期间无敌防止连击死循环），MVP 无 permadeath。后续可加"重伤需仪式复活"。
3. **Cast time = de facto CD**。每咒 `cast_time_sec`（如 0.6s）期间不能切咒；念咒中被打断（受击 / stun）= **不扣 charges**。
4. **派生量也持久化**：`max_charges` 由 core 材质算出，**也写入实例字段**（[memory: feedback_derived_state_persist_single_writer](#)），避免读时反算。

---

## 4. 类型系统

新增两个 Resource 类 + 一个 Item 子类。

### 4.1 Spell

咒语元数据。每个咒一个 `.tres` + 一个 `.lua`。

```gdscript
# data/spells/expelliarmus.tres
class_name Spell
extends Resource

@export var id: StringName = &"expelliarmus"
@export var display_name_key: String = "spell.expelliarmus.name"  # i18n catalog

@export var charge_cost: int = 8
@export var cast_time_sec: float = 0.6        # 念咒 + 挥棒时长；也是 CD

@export var school: StringName = &"charm"     # charm / curse / jinx / transfiguration
@export var lua_path: String = "res://data/spells/expelliarmus.lua"

# 视觉 / 听觉占位
@export var projectile_visual: PackedScene
@export var sound_cast: AudioStream

# 可选：UI 用
@export var icon: Texture2D
@export var description_key: String           # tooltip i18n key
```

> Display name 走 i18n catalog（[memory: project_prompt_i18n_catalog](#)）：`data/i18n/<locale>/spells.json`。

### 4.2 Wand

`Item` 子类，本质就是 "kind=wand" + 额外的 spell_slots 字段。loadout 和 charges 走 `Item.properties: Dictionary`，因为它们是**每个魔杖实例独立**的状态（同样规格的两根魔杖可以装不同咒）。

```gdscript
# src/combat/wand.gd
class_name Wand
extends Item

@export var spell_slots: int = 4              # loadout 长度

# Item.properties 携带的实例字段：
#   "charges": int          — 当前魔力
#   "max_charges": int      — 上限（来自 core 材质 + 实例化时写入）
#   "loadout": Array        — 长度 = spell_slots 的 spell_id 数组；"" 表示空槽
#   "core_material": String — 杖芯材质 id（影响 max_charges / 学派偏好）
```

> 为什么 loadout 走 `properties` 而不是 `@export var`：`@export` 只能在 `.tres` 模板里固化，但 loadout 是**玩家运行时改**的实例状态，必须随 inventory 一起持久化。`properties` 就是这种场景设计的（[entity-model.md §2.2](./entity-model.md)）。

### 4.3 SpellProjectile

运行时节点，**不是 Resource**。Area3D 子类。

```gdscript
# src/combat/spell_projectile.gd
class_name SpellProjectile
extends Area3D

var spell_id: StringName
var source_id: String             # 施法者 id（伤害归属、感知归属、阵营判定）
var velocity: Vector3
var ttl_sec: float = 2.5
var pierce: bool = false
var on_hit_callback: Callable     # = SpellCaster.handle_hit
```

`_physics_process` 推进位置 + 倒计时 ttl；`area_entered` / `body_entered` 触发 `on_hit_callback`。

### 4.4 Buff / Condition

复用 `Character.active_conditions`（[player-stats.md §7](./player-stats.md)）schema，仅新增 `type` 值：

| Type | 来源 | 效果 |
|---|---|---|
| `stunned` | 控制咒 | 无法移动 / 施法 / dodge，N 秒 |
| `shielded` | protego 类 | 命中前消弹（HitResolver 检测），N 秒 |
| `silenced` | 沉默咒 | 不能施法但能动，N 秒 |
| `burning` | 火咒 | 每 tick 减 HP，N 秒 |
| `hexed` | 黑魔法 | 减 stamina cap / 命中率 debuff |
| `disarmed` | 缴械咒 | 强制 unequip wand 到地上 |

> 不新建表，复用 `active_conditions` 数组即可。落库走现有 `Character.upsert_snapshot()` 路径。

---

## 5. Lua 契约

每个咒 1 个 `.tres`（元数据）+ 1 个 `.lua`（行为）。**发明新咒只改这两个文件**，不动 godot 代码。

### 5.1 函数签名

```lua
-- data/spells/expelliarmus.lua

-- 施法时调用。返回值描述要生成的"东西"（弹道 / aura / instant 效果）
function on_cast(ctx)
  -- ctx: { caster_id, caster_pos, aim_origin, aim_dir, now_game }
  return {
    kind = "projectile",
    speed = 18.0,
    visual = "expelliarmus_bolt",   -- 视觉 id 或 .tscn 路径
    pierce = false,
    ttl_sec = 2.5,
  }
end

-- 弹道命中目标时调用
function on_hit(ctx, target)
  -- ctx: { caster_id, projectile_id, hit_pos, now_game }
  -- target: { id, kind, has_wand, hp, conditions, ... }
  affect.modify_stamina(target.id, -10)
  if target.has_wand then
    affect.disarm(target.id)
  end
end
```

### 5.2 `kind` 枚举

| Kind | 含义 | 必要参数 |
|---|---|---|
| `projectile` | 飞行弹道 | speed, ttl_sec, visual; 可选 pierce, gravity, homing_strength |
| `self_aura` | 在自己身上贴一层 | duration_sec, visual; 由 condition apply |
| `area` | 地面 / 区域效果 | center, radius, ttl_sec |
| `instant` | 立刻判定（hit-scan，少用） | max_range, cone_deg |

> 本系统**主推 projectile**；其他 kind 是为少数特殊咒预留（protego 是 self_aura、消失咒可能是 instant）。

### 5.3 `affect.*` API

参考 [scripting-layer.md](./scripting-layer.md) 的 `script_api.gd:inject` 模式 —— Lua 调 `affect.xxx(...)` 时不直接修改世界，而是往 `collected_effects` 队列里推一条声明，下个 fast tick 边界由 `HitResolver` 统一 apply。

P0 落地清单：

```
affect.modify_hp(target_id, delta)
affect.modify_stamina(target_id, delta)
affect.modify_charges(wand_id, delta)
```

P1 追加：

```
affect.add_condition(target_id, condition_type, duration_sec)
affect.remove_condition(target_id, condition_type)
affect.disarm(target_id)
affect.knock_back(target_id, dir: Vector3, force: float)
```

P2 追加：

```
affect.spawn_projectile(spell_id, origin, dir, params)   -- 让咒能链式产生子弹道
affect.spawn_aura(owner_id, aura_id, duration_sec)
```

> 现有 `effects.gd` 仅有 `modify_stamina` 一种 effect type；本系统每加一条 `affect.*` 都要同步加一个 effect type 实现。

---

## 6. 运行时模块

### 6.1 模块清单

| 模块 | 位置 | 责任 |
|---|---|---|
| `CastController` | `src/characters/parts/cast_controller.gd` | Character 子节点。接受 input（数字键 1-N）/ 外部命令 / LLM tool；查 loadout；播 cast 动画；动画 method-track 触发瞬间调 `SpellCaster.cast` 并扣 charges（见 §6.3）|
| `SpellCaster` | `src/combat/spell_caster.gd` | 工具类。调 `ScriptExecutor.execute(spell.lua_source, "on_cast", ctx)` → 拿 `collected_effects` → 路由（projectile → ProjectileService / aura → ConditionService / instant → HitResolver）|
| `ProjectileService` | `src/combat/projectile_service.gd`（autoload） | spawn / pool / 推进 / ttl / 命中回调；维护活跃列表给 BT 查询"附近来弹" |
| `HitResolver` | `src/combat/hit_resolver.gd` | fast tick 边界结算 `hit_event` 队列；调 `Spell.on_hit` Lua → 应用 `collected_effects`；shield 拦截在这里发生 |
| `CombatBrain` | `src/characters/parts/combat_brain.gd` | NPC 进战时挂载的 BT runner；非战斗时卸载或休眠 |
| `WandCharger` | 走现有 `src/sim/crafting/crafting_dispatcher.gd` | `ritual_recharge` reaction 当作普通仪式跑，charges 通过 `affect.modify_charges` 补回 |

### 6.2 输入入口收敛

```
                    ┌─ 键盘 1-4         ─┐
                    │                    │
玩家 ──────────────┼─ /cast 命令       ─┼─→ CastController.try_cast(spell_id, aim_ctx, source)
                    │                    │
LLM tool（未来） ──┴─ combat_action()  ─┘
```

`source: String` 参数标识入口（"input" / "command" / "llm"），方便后续埋点和权限校验。

### 6.3 动画驱动施法时机

**问题**：弹道必须在角色挥棒到最前那一帧生成，不能用代码硬编时间偏移——否则换动画就要改代码。

**方案**：用 Godot 内置 `AnimationPlayer` 的 **method 轨**（`CallMethod` track）。动画师在施法动画的"杖尖伸到最前"那一帧放一个 keyframe，method name 写 `_on_spell_release`。AnimationPlayer 播到那帧时自动调角色根节点的该函数。

```gdscript
# src/characters/parts/cast_controller.gd（简化）
func try_cast(spell: Spell, aim_ctx: Dictionary) -> bool:
    if _casting: return false
    if _wand_charges() < spell.charge_cost: return false

    _pending_spell = spell
    _pending_aim = aim_ctx
    _casting = true

    # 拉伸动画对齐 spell.cast_time_sec，让不同咒节奏不同
    var anim_len = anim_player.get_animation("cast_wand").length
    anim_player.speed_scale = anim_len / spell.cast_time_sec
    anim_player.play("cast_wand")
    anim_player.animation_finished.connect(_on_cast_done, CONNECT_ONE_SHOT)
    return true

# 动画 method 轨在峰值帧调这个
func _on_spell_release() -> void:
    if not _casting: return  # 被打断了，零状态机
    var origin = wand_tip_attachment.global_position
    SpellCaster.cast(self, _pending_spell, origin, _pending_aim.dir)
    _wand_set_charges(_wand_charges() - _pending_spell.charge_cost)

func _on_cast_done(_name: StringName) -> void:
    _casting = false
    _pending_spell = null

# 受击 / stun 调这个
func interrupt() -> void:
    anim_player.stop()       # method 轨不到目标帧就停了，_on_spell_release 不会被调
    _casting = false
```

**几个关键性质**：

1. **真值在动画文件，不在 `cast_time_sec`**。`Spell.cast_time_sec` 只是 UI 进度条 / CD 元数据；实际发射时机由动画方法轨决定。用 `speed_scale` 让动画时长对齐 cast_time。
2. **打断天然干净**。`anim_player.stop()` 让方法轨不到峰值帧，`_on_spell_release` 自然不被调用，charges 不扣，无需额外回滚逻辑。
3. **杖尖位置**：用 `BoneAttachment3D` 挂在右手骨，子节点偏移到杖尖（Mixamo / Synty rig 通过 [project_npc_pipeline](#) 的 BoneMap 配过的都通用）。`_on_spell_release` 当帧读 `global_position` 即得空间真位置，避免预测 / 插值偏差。
4. **方向锁定时机**：`try_cast` 进入时就把 `aim_ctx` 存到 `_pending_aim`，**不在释放帧重新采样**——否则 cast 期间转身会把弹道甩偏。
5. **MVP 一套动画走多咒**：先共用 `cast_wand` 通用动画，所有咒共用方法轨触发点。`Spell.cast_anim_id` 字段预留，特殊咒（长仪式、范围咒）后期覆盖默认。
6. **NPC 同源**：BT 的 `CastSpell` leaf 也调 `CastController.try_cast`，动画机制完全复用，无 NPC 专属代码路径。

**美术管线**：Mixamo 现成 `Standing 1H Magic Attack 01` 类动画按现有 NPC pipeline 走 BoneMap + Renamer 导入即可。第一版用 Mixamo placeholder，后期替换专门 cast 动画时动画名 / 方法轨保持不变，逻辑零修改。

### 6.4 受击反馈 / 击飞 / Ragdoll

**问题**：Stupefy 这种击飞咒命中后，希望"角色被打飞、撞墙、瘫倒"有合理观感。本节定**分档实现策略**和**Godot 4 能力边界**，避免后期实现时重新踩坑。

#### IK 不是这里的工具

IK（`LookAtModifier3D` / Skeleton modifier 系列）适合**持续性调整**：杖尖一直指向目标、脚踩楼梯不穿模、头部 look-at。**瞬时受击 + 撞墙是 ragdoll + canned 动画混合的领域**，不要往 IK 上凑。

#### Godot 4 能力档次

| 需求 | 工具 | 档次 |
|---|---|---|
| 基础 IK（脚 / 头 look-at） | `LookAtModifier3D` 等 Skeleton modifier | 够用 |
| Control Rig 级复杂 IK | 无原生，社区插件凑合 | 弱 |
| Ragdoll 切换 | `PhysicalBoneSimulator3D` + `PhysicalBone3D`（4.3+ 重写过） | 不错 |
| 动画 → ragdoll → 动画 来回切 | 同上，`physical_bones_start/stop_simulation()` | 不错 |
| Active ragdoll（电机驱动半物理） | 无原生，要自己写 PD controller | 难 / AAA 向 |
| 动画混合 / blend tree | `AnimationTree` + StateMachine | 够用 |

参考目标：Skyrim / Dark Souls 一档可达（它们都是 ragdoll + canned 反应）。Sifu / Sekiro 那种受击反馈精度需要 active ragdoll + 大量手调，**不在本项目目标范围**。

#### 标准击飞四段式

```
1. 命中瞬间：blend 0.2s "stagger_back" canned 动画（Mixamo "Hit Reaction" 类）
2. 同帧切 ragdoll：PhysicalBoneSimulator3D.physical_bones_start_simulation()
3. 给胸骨 apply_central_impulse(knockback_dir * force)：物理接管，自然飞 + 撞墙 + 滑落
4. 速度 < threshold 且接触地面 N 帧 → physical_bones_stop_simulation() → blend "get_up" 动画
```

**调对效果的三个关键**：
- **PhysicalBone3D 关节限制**（swing / twist limits）必须调，否则 ragdoll 会扭成鬼畜
- **碰撞层切换**：ragdoll 期间禁用角色 CapsuleCollider，启用 PhysicalBone 自带 collider，避免双重碰撞抖动
- **冲量数量级**：Stupefy ≈ 300 N·s 一档，普通击退 ≈ 100 N·s 一档，需要按 mass 和 ragdoll 关节 damping 联调

#### 分阶段落地

| 阶段 | 受击反馈 | 原因 |
|---|---|---|
| **P0-P2** | 纯 canned 动画（stagger / knockdown / get_up），物理上不挪位置 | 验证战斗循环够用；Mixamo 包现成；ragdoll 调试时间不在主线上 |
| **P3** | "轻 ragdoll" —— 上半身骨骼物理化、下半身保持动画，飞行轨迹由 CharacterBody3D 推。完全 ragdoll 留给死亡 / 重伤 | 大冲量咒（Stupefy / Bombarda）需要视觉冲击力；轻量先行降低关节调试负担 |
| **P4+（可选）** | Active ragdoll（PD controller 半物理半动画），被打飞时手脚还在挥扎 | AAA 级特性，Godot 没现成；除非演示需要，不值得做 |

#### 与 §6.3 cast 动画的关系

受击反馈触发时 **立即调 `CastController.interrupt()`**：
- 当前 cast 动画 stop → method 轨不到，spell 不发射，charges 不扣
- AnimationTree 切到 hit reaction state
- 后续 ragdoll 切换不影响 CastController（_casting=false 已干净）

打断模型由 §6.3 的"零状态机"性质自然兜底，无需额外协调代码。

### 6.5 持久区域效果 / 环境状态咒

**问题**：Incendio 这种环境咒不该是"打到东西扣血就完事"。期望行为：

- 击中草丛 / 木墙 / 稻草堆 → 着火 + 燃一段时间
- 击中石板路 / 铁砧 / 水井 → 不能点燃（fizzle）
- 站在火里的生物受持续伤害 + 贴 `burning` condition
- 玩家 / NPC / 雨 用水扑灭可以提前结束
- 不蔓延（用户明确：MVP 不要蔓延）

这要求世界知道**每个被打到的 mesh 是不是可燃**——粒度到具体物体而非区域。本节定 mesh-attached 材质机制和 BurningRegion 设计。

#### 为什么不走 RegionMap

直觉会想到给 `MapRegion` 加 `surface_type` 字段（north_meadow = grass，town_center = cobblestone）。**这是错的**：

- 北 meadow 里有房子、有石板路、有秃地，整块标 grass 就在撒谎
- Region 是 2D 投影，玩家瞄木屋墙、瞄屋顶、瞄树冠、瞄地上稻草，region 都是同一个，但燃料完全不同
- 哈利波特式战斗的"细节互动"在视觉物体级别发生，不在地块级别

RegionMap 仍然有用——但用于 NPC perception / agent context / 巡逻范围之类的**区域语义**，不用于火物理。两套系统语义不同，不混用。

#### 复用现有材质系统

`data/materials/*.tres` 已经有 30+ 个 `Material` Resource，每个带 `flammable: bool` 和 `ignite_temperature: int`（[reaction-schema.md §2.1](./reaction-schema.md#21-material)）。这是为这一刻准备的——只需要把材质**挂到 mesh 上**，弹道命中时读取即可。

新建若干"环境材质"：

| Material | flammable | ignite_temperature | 典型贴载体 |
|---|---|---|---|
| `grass` | true | 150 | grass_patch.tscn |
| `dry_hay` | true | 100 | hay_bale.tscn |
| `wood` | true | 250 | 木屋墙体 wrapper |
| `cobblestone` | false | -1 | 路面 mesh |
| `thatch` | true | 130 | 茅草屋顶 |
| `cloth` | true | 180 | 旗、衣物 |
| `flesh`（已存在） | 通过角色 condition 处理，不挂 BurnableSurface |  |  |

#### `BurnableSurface` 组件

每个可烧物的 scene 挂一个组件子节点，引用 Material：

```gdscript
# src/world/burnable_surface.gd
class_name BurnableSurface
extends Node3D

@export var material: Material               # data/materials/grass.tres 等
@export var burn_duration_mult: float = 1.0  # 稻草烧得快、木墙烧得久
@export var radius_hint: float = 1.5         # 该物着火时 BurningRegion 默认半径
@export var on_burnt_scene: PackedScene      # 烧完替换成什么（焦土 / 黑木结构）
```

scene 结构示例：

```
grass_patch.tscn
├ Node3D (root)
│  ├ MeshInstance3D (草丛 mesh)
│  ├ StaticBody3D
│  │  └ CollisionShape3D
│  └ BurnableSurface (material = res://data/materials/grass.tres)
```

```
assets/buildings/wood_wall_section.tscn   # 我们自己的 wrapper
├ Node3D (root)
│  ├ SM_Bld_House_Wall_*.tscn (instance 第三方 Synty)   ← 不动 third-party
│  ├ StaticBody3D + CollisionShape3D                    ← 碰撞由 wrapper 提供
│  └ BurnableSurface (material = res://data/materials/wood.tres, burn_duration_mult = 4.0)
```

第三方 Synty 资源**不动**（per [memory: project_world_environment_tres_modified](#) 那种教训），所有可燃属性都通过 wrapper scene 挂。

#### 弹道命中查询

SpellProjectile 命中时走 mesh → BurnableSurface 链：

```gdscript
# src/combat/spell_projectile.gd
func _on_body_entered(body: Node3D) -> void:
    var burnable := _find_burnable_surface(body)
    var hit_surface_info := {}
    if burnable:
        hit_surface_info = {
            "material_id": burnable.material.id,
            "flammable": burnable.material.flammable,
            "ignite_temperature": burnable.material.ignite_temperature,
            "burn_duration_mult": burnable.burn_duration_mult,
            "radius_hint": burnable.radius_hint,
            "node_path": burnable.get_path(),
        }
    
    SpellCaster.handle_hit(spell, source_id, global_position, body, hit_surface_info)

static func _find_burnable_surface(body: Node3D) -> BurnableSurface:
    # 1. 自己
    for child in body.get_children():
        if child is BurnableSurface: return child
    # 2. 兄弟（StaticBody 和 BurnableSurface 同为 root 子节点的常见结构）
    var parent := body.get_parent()
    if parent:
        for sibling in parent.get_children():
            if sibling is BurnableSurface: return sibling
    # 3. 父链（最多上溯 3 层）
    var p := body.get_parent()
    var depth := 0
    while p and depth < 3:
        for child in p.get_children():
            if child is BurnableSurface: return child
        p = p.get_parent()
        depth += 1
    return null
```

#### 咒语 Lua 不变

Lua 端 guard 在 `ctx.hit_surface` 上判断，不需要知道 raycast 机制：

```lua
-- data/spells/incendio.lua
function on_hit(ctx, target)
  if target then
    affect.modify_hp(target.id, -8)
  end
  
  local s = ctx.hit_surface
  if s.flammable and s.ignite_temperature <= 600 then  -- Incendio 假设 600°C
    affect.spawn_burning_region(ctx.hit_pos, {
      radius = s.radius_hint or 2.5,
      base_ttl_sec = 8.0 * (s.burn_duration_mult or 1.0),
      attached_to = s.node_path,  -- 让 BurningRegion 跟着物体走（车 / 帆船 / NPC 衣服）
    })
  end
end
```

#### BurningRegion node

```gdscript
# src/combat/burning_region.gd
class_name BurningRegion
extends Area3D

@export var intensity: float = 60.0          # 0-100；HP 减速度 ∝ intensity
@export var radius: float = 2.5
@export var ttl_remaining_sec: float = 8.0
@export var source_id: String = ""
@export var attached_to: NodePath            # 跟随移动物体（可空，static 火源就空）
@export var burning_node_path: NodePath      # 真正被烧的那个 BurnableSurface，despawn 时给它换 on_burnt_scene

# 子节点：GPUParticles3D（火）+ OmniLight3D（红色）+ AudioStreamPlayer3D（噼啪）

func _on_fast_tick() -> void:
    ttl_remaining_sec -= 0.25
    intensity -= 0.5 * 0.25                  # 自然 decay
    if attached_to:
        var anchor := get_node_or_null(attached_to)
        if anchor: global_position = anchor.global_position
    for body in get_overlapping_bodies():
        if body is Character:
            body.apply_damage(intensity * 0.05, source_id)
            body.add_condition("burning", 3.0)
    if intensity <= 0 or ttl_remaining_sec <= 0:
        _despawn()

func _despawn() -> void:
    # 给原物换 on_burnt_scene（焦草地 / 焦木墙）
    var bs := get_node_or_null(burning_node_path) as BurnableSurface
    if bs and bs.on_burnt_scene:
        var burnt := bs.on_burnt_scene.instantiate()
        bs.get_parent().add_sibling(burnt)
        bs.get_parent().queue_free()
    queue_free()

func on_water_applied(pos: Vector3, amount: float, water_radius: float) -> void:
    if global_position.distance_to(pos) <= radius + water_radius:
        intensity -= amount
```

#### 水事件总线协议

水源不知道有几团火、火不知道水从哪来——经过 EventBus 解耦：

```gdscript
# 任何水源 emit
EventBus.water_applied.emit(pos: Vector3, amount: float, radius: float)

# BurningRegion._ready 监听
EventBus.water_applied.connect(_on_water_applied_global)
```

水源候选（按实现顺序）：

| 水源 | emit 时机 | amount 量级 |
|---|---|---|
| Aguamenti 咒 | spell on_hit | 30-50 |
| 倾倒水桶 | 玩家 / NPC use item | 60-80 |
| 河 / 池塘进入 | Character 进入 water region | 持续小量（每 tick 10） |
| 雨天气（P3+） | DayNightCycle / WeatherSystem 周期 | 5/tick，全 town 范围 |

新加任何水源**只需要 emit 信号**，不用改 BurningRegion 代码。同理 BurningRegion 不知道谁在浇水。

#### 持久化

BurningRegion 落 sqlite 一张表：

```
burning_regions
  id PRIMARY KEY
  pos_x, pos_y, pos_z
  attached_node_path NULLABLE      -- 跟随物体的话存 NodePath
  burning_node_path                -- 用于 despawn 时替换 on_burnt_scene
  intensity, ttl_remaining
  source_id
  spawned_at_game_time
```

玩家离开村庄回来，未烧完的 BurningRegion 从表里 rehydrate。Godot server 一直在跑（[memory: feedback_godot_is_authority](#)），BurningRegion `_on_fast_tick` 持续运行，自动消亡。

#### NPC / BT 互动（免费）

`burning` condition 已经在 §4.4 buff/condition 表里。BT 添一个 leaf：

```
Sequence: CheckCondition("burning") → MoveAwayFrom(nearest_burning_region) → CheckWaterNearby → SeekWater
```

NPC 看到自己着火会跑、看到队友 / 自家房子着火（perception 事件 `world.burning_started`）会去引水扑——视设计需要再加 BT 模板。这部分**不在 P0-P2 范围**，仅写明接口预留。

#### 内容侧工作量

架构搭完后**实际工作在 content**：

- 建 `data/materials/grass.tres` / `wood.tres` / `dry_hay.tres` / `thatch.tscn` 等环境材质
- 建 `grass_patch.tscn` / `hay_bale.tscn` / `wood_pile.tscn` / `torch_lit.tscn` 等可烧 prop scene
- 给每栋 Synty 房屋做 wrapper scene（包第三方 prefab + 加 BurnableSurface + 适当 burn_duration_mult）
- 烧后视觉：`grass_scorched.tscn` / `wood_charred.tscn` / `hay_ash.tscn` 等 `on_burnt_scene` 资产
- 在 town.tscn 实际地块上散布 grass_patch、稻草堆，把 Synty 房子改成 wrapper 实例

第一版只做 1-2 种（草 + 木墙）就能验证全链路；其他材质后续追加只是数据工作。

#### 与 §6.3 / §6.4 的关系

- 咒语命中触发 BurningRegion spawn：走 §5 Lua → `affect.spawn_burning_region` → effects.gd 路由
- BurningRegion 给 Character 贴 `burning` condition：走 §4.4 condition 体系
- 着火 NPC 受击：与 §6.4 受击反馈互不冲突，condition 是持续 debuff，hit reaction 是瞬时动画

---

## 7. NPC Behavior Tree

不引第三方 BT 插件（如 Beehave、LimboAI），自己撸 ~200 行 GDScript。理由：

- 第三方 BT 框架复杂度远超我们需要
- 本项目所有 mechanic 已用 Lua / GDScript，再多一个 DSL 不值得
- 调试 / 可视化需求 P2 阶段可以慢慢加

### 7.1 节点接口

```gdscript
class_name BTNode
enum Status { SUCCESS, FAILURE, RUNNING }

func tick(bb: Blackboard) -> Status:
    return Status.SUCCESS
```

### 7.2 节点类型

| 类别 | 节点 |
|---|---|
| Composite | `Sequence`、`Selector`、`Parallel` |
| Decorator | `Inverter`、`Cooldown(sec)`、`AlwaysSucceed` |
| Leaf | `AimAt(target_key)`、`CastSpell(spell_id)`、`PickBestSpell`、`DodgeIncoming(threshold_dist)`、`MoveToCover`、`Retreat(safe_dist)`、`CheckHP(op, value)`、`CheckCharges(gt, value)`、`CheckTargetVisible` |

**Leaf 节点全部 GDScript**，不进 Lua —— 4 Hz × N NPC × M leaf 调 Lua 太贵。

### 7.3 Blackboard

强类型字段，不是任意 dict：

```gdscript
class_name Blackboard

var current_target: NodePath
var incoming_projectiles: Array[SpellProjectile]    # ProjectileService 推
var known_cover: Array[Vector3]                     # 静态地图标注 / 运行时探测
var last_seen_pos: Vector3
var my_loadout: Array[StringName]                   # 从 wand.properties.loadout 镜像
var my_hp: float
var my_charges: int
```

### 7.4 BT 模板（村庄守卫示例）

```
Selector
├ Sequence: CheckHP(<30%) → MoveToCover → CastSpell("episkey_self")
├ Sequence: CheckIncoming(<3m) → DodgeIncoming
├ Sequence: CheckTargetVisible → AimAt → PickBestSpell → CastSpell
├ Sequence: !TargetVisible → MoveTo(last_seen_pos)
└ Patrol
```

**Tick 节奏**：每 250ms tick 一次（fast tick）；Leaf 可 `yield RUNNING` 跨 tick（"正在 cast 中"状态）；`CastSpell` 占满整个 cast_time 都返回 RUNNING。

### 7.5 模板存放

`data/combat/bt_templates/*.tres`，每个职业 / 阵营一个。后期可加视觉编辑器，但先纯 GDScript 构造。

---

## 8. LLM 边界

LLM **绝对不进入战斗每帧或每 tick**。但**不是完全无关**。

### 8.1 三种 LLM 角色（按时机）

| 时机 | LLM 任务 | 实现 |
|---|---|---|
| 战前 | 决定参战立场 / 选 loadout（按 agent_memory 里常用咒） | 新 agent tool `equip_wand_loadout(preset_id)` / `engage_in_combat(target_id, reason)` |
| 战中 | **暂停 think loop**（[two-track-agent-session.md](./two-track-agent-session.md)）；BT 接管 | `CombatBrain` mount 时通知 backend `agent.combat_lock`；unmount 时解锁 |
| 战后 | 战斗事件批量进 perception → 写 memory；反思胜败 / 社交后果 | 走现有 perception manifest 通道；事件 schema 加 `combat_*` 类型 |
| 长期 | 研究 / 发明新咒（长时段任务） | LLM 输出 `.lua + .tres`，dev 审核后入库 |

### 8.2 战中 LLM 战术接口（开口，不锁死）

用户原话："**LLM 的作用日后再说，有可能想在战斗中做一些战术调整**"。

所以**预留接口形状但不实现**：

```
CastController.try_cast(spell_id: StringName, aim_ctx: Dictionary, source: String) -> bool
```

`source = "llm"` 走特殊路径：低优先级、可能延迟应用（LLM 响应慢，弹道飞过去可能目标已经死了）、不阻塞 BT 决策。具体在 P3 / P4 阶段视玩法需要再定。

短期内 BT 完全自主决策；LLM 只在 **战前选 loadout** 和 **战后写 memory**。

---

## 9. 实施路径

四个里程碑，每个独立可玩 / 可验证。

### P0 — 站桩对射（最小可玩）

详细切片见独立 plan 文件。摘要：

- `Spell` / `Wand` Resource 类
- 1 个咒（`stupefy`）：直伤 + Lua 数据驱动
- 真 3D Area3D 弹道、鼠标瞄准
- 独立 `combat_range.tscn` 测试场景（3 个静态木桩）
- HP / charges 写入 character & wand 实例
- 极简 HUD（准星 + charges + 1 slot）

**验证**：F5 启动，按 1，0.6s 后弹道飞出击中木桩扣血，wand charges 减少。改 lua 数值不动 godot 代码即生效。

### P1 — 玩家完整循环（防守 + 资源）

- `DodgeController`：双击方向 = roll，扣 25 stamina，i-frames 0.4s
- 第 2-3 咒：`protego`（盾，self_aura，挡弹）、`expelliarmus`（缴械，调用 disarm）
- Knockdown + 自动起身
- `ritual_recharge` reaction 走 crafting dispatcher 补 wand charges
- Fast tick 框架落地（GameClock 加 `fast_tick` signal）
- HitResolver 正式接 fast tick 边界结算
- `/cast` 命令路径与 CastController 收敛

### P2 — NPC AI 上线

- BT 框架（~200 行）+ Blackboard
- 1 个 BT 模板（村庄守卫）
- 1 个 NPC 在 town 里实战
- LLM `engage_in_combat` tool + combat_lock 协议
- 战斗事件进 perception manifest
- `target_dummy` 退役 / 改用真正的 NPC

### P3 — 内容扩展

- 多学派咒库（fire / heal / control / buff / curse 各 1-2）
- 多 BT 模板（盗贼=游击、巫师=爆发输出、骑士=近身）
- LLM 发明新咒 workflow（输出 lua + tres，dev 审核入库）
- 多 wand core 材质 + 学派偏好
- 视觉特效（粒子、轨迹）

### P4（可选）— LLM 战术微调

- 战中 LLM tool `tactical_advice(situation) -> {focus_target?, switch_loadout?, retreat?}`
- BT 周期性查询 advisory blackboard 字段
- 异步 / 可选 / 不阻塞战斗节奏

---

## 10. 风险与取舍

| 风险 | 应对 |
|---|---|
| Lua 性能：BT 每 tick 调多次 Lua | **BT leaf 全 GDScript**；Lua 仅在 cast / on_hit / aura tick |
| 弹道穿透 / 地形 / 高度差 bug | 用 Godot 内置 Area3D 物理，不自己写碰撞；P0 平地验证，P1 加楼梯 / 屋顶测 |
| 与 crafting reaction 的关系 | 施法 ≠ crafting 配方匹配，不强行套 reaction schema；但 **`affect.*` 接口和 fast-tick 边界结算复用** |
| 同步：未来联机 | 单机 + 同进程，不考虑 netcode；Godot 是权威（[memory: feedback_godot_is_authority](#)） |
| BT vs Utility AI | 已选 BT。代价是写一遍框架；收益是可视化好、调试好 |
| NPC 战斗中突然 think loop 触发 | `combat_lock` 必须可靠，否则 LLM 输出会过期 / 冲突 BT 决策 |
| 没有 mana 字符串混淆 | character.gd:38 已明确注释 "没有 mana —— 法术能量住在魔杖上"，本系统坐实此决策 |

---

## 11. Open questions

- **死亡机制最终形态**：MVP knockdown + 1 HP 起身够用，但 P3 之后是否要 "重伤需仪式复活" / "permadeath for NPC" / "记仇系统触发复仇"？涉及社交模拟，需要和经济 / 派系系统一起想
- **PvE vs PvP 阵营判定**：`source_id` / `target_id` 之外是否需要派系标签？村民打盗贼可以，村民被守卫误伤呢？走 group 系统（[memory: project_groups_access_model](#)）还是单独的 faction 字段？
- **弹道视觉资产**：本系统大量依赖好看的 spell visual；美术管线缺位时怎么 placeholder（粒子？trail？） 
- **音效**：cast / hit / dodge / shield-break 都要音效，缺位时的占位策略
- **多人战斗的 NPC AI 协作**：守卫们怎么不互相挡 / 围殴目标？P2 可能要加群体协调 blackboard
- **fast tick 触发源**：是 GameClock 算游戏时间加速过的，还是固定 real-time 4 Hz？战斗节奏受 [memory: project_game_time_scale](#) 影响吗？倾向 **real-time 4 Hz**，战斗不该被时间加速影响

---

## 修订记录

- 2026-05-29：v1 初稿。从三轮对话沉淀。覆盖到 P4 路径，但 P3-P4 仅占位
- 2026-05-29：§6 拆 §6.1/6.2/6.3；新增 §6.3 动画驱动施法时机（AnimationPlayer method 轨绑 `_on_spell_release`，cast_time_sec 仅作 UI / CD 元数据，真值在动画文件）
- 2026-05-29：新增 §6.4 受击反馈 / 击飞 / Ragdoll（Godot 4 能力档次、击飞四段式 canned + ragdoll 切换、P0-P2 纯 canned / P3 轻 ragdoll / P4 active ragdoll 分阶段落地、与 §6.3 interrupt 的关系）
- 2026-05-29：新增 §6.5 持久区域效果 / 环境状态咒（复用 MapGrid + RegionMap，给 MapRegion 加 surface_type / flammability；BurningRegion node；EventBus water_applied 总线解耦水源与火；持久化；NPC condition / BT 互动；焦土留给 P3+）
- 2026-05-29：§6.5 改走 mesh-attached `BurnableSurface` 组件方案，弃用 RegionMap 路径；写明"为什么不走 RegionMap"；复用 `data/materials/*.tres` 已有 flammable / ignite_temperature 字段；第三方 Synty 资源不动，wrapper scene 挂组件；ctx.hit_surface 走查询链；BurningRegion 加 attached_to 跟随物体 + on_burnt_scene 替换烧后视觉
