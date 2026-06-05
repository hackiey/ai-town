# Combat system

> Status: **drafting v1** — 设计稿，尚无对应代码。本文是哈利波特式魔杖咒语对战的完整 schema、运行时分层和实施路径。
>
> **配套文档**：
> - [reaction-schema.md §7.4b](./reaction-schema.md) — wand_charges 概念首次落地（v4 修订）
> - [entity-model.md §2.2](./entity-model.md#22-角色资源模型) — mana 从角色属性迁到魔杖
> - [player-stats.md](./player-stats.md) — hp / stamina 数值系统、buff / status schema
> - [runtime-layers.md §2.2](./runtime-layers.md#22-战斗-cadence) — 战斗 cadence、worker 与 godot 分层
> - [scripting-layer.md](./scripting-layer.md) — Lua VM + ScriptExecutor 公共契约
> - [two-track-agent-session.md](./two-track-agent-session.md) — LLM runtime；战斗中如何切出 / 切回
>
> **不变量**：
> - 战斗每帧 / 每 tick **永远不进 LLM**，只有 godot + lua 跑（[memory: feedback_godot_is_authority](#)）
> - 咒语分两层：**Spell delivery lua**（投递：瞄准 / 弹道 / channel）+ **Reaction**（物理后果 / 难度 / 学派，复用 [reaction-schema.md](./reaction-schema.md) 的声明式 `.tres`，无脚本）。发明新咒主要写 delivery lua + 选触发哪些 reaction，**永不发明新物理**（[memory: project_reactions_are_physics]）
> - 难度 / 学派 / 威力公式全在 **Reaction + Wand**，不在 Spell；Lua 拿引擎算好的标量，不碰公式
> - **角色没有 mana**——施法消耗魔杖储能（wand_charges）；体力住角色，被 dodge / sprint / 受击消耗，不被施法消耗
> - 魔杖储能不自回，只能仪式 / 材料补；用尽 → `depleted` 不可修

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
| **Fast tick** | 4 Hz（250ms） | `GameClock.fast_tick`（待实现） | BT 评估、buff/status 倒计时、命中事件结算、HP / charges 写入 |
| **Hour tick** | 现有 | `GameClock.slow_tick` | 仪式 cooldown、wand 长期衰减（如设计） |
| **LLM async** | 异步 | brain worker | **战斗中暂停**。战前选 loadout / 决定参战；战后 perception → memory；长期研究新咒 |

**为什么弹道和结算分两层**：
- 弹道必须 60 Hz 才不丢命中
- 但 BT 每帧 evaluate 太贵且会 jitter；fast tick 是 NPC 决策的天然边界
- 命中那一刻只往队列推 `hit_event`，下个 fast tick 边界统一 apply —— 沿用 [reaction-schema.md](./reaction-schema.md) 的"边界结算"原则，避免一发弹道在两个 tick 间反复改 HP

> Fast tick 框架在 [simulation-layer.md §2.1](./simulation-layer.md) 已设计但 Godot runtime 尚未实现；本系统是 fast tick 的第一个消费者，需要补落地。

---

## 3. 资源 + 威力模型

战斗数值全部从三种资源 + 一条威力公式派生。**角色没有 mana**——施法消耗的是魔杖储能。

### 3.1 三种资源

| 资源 | 归属 | 上限 | 消耗 | 恢复 |
|---|---|---|---|---|
| **HP** | `Character.hp` | 100（`max_hp` 可改） | 受击（reaction modify） | 仪式 / 药水 / 医生；**不自回** |
| **Stamina** | `Character.stamina` | 动态 cap（受 hunger/rest 压低，[player-stats.md §3](./player-stats.md)） | dodge(-25) / sprint(drain) / 被击退(-10) | 慢速自回（已有） |
| **Wand energy** | wand 实例 `wand_charges` | wand 实例 `max_wand_charges`（**独立字段，不由 power 派生**；杖芯材质写入） | instant 扣固定量 / channel 按 `drain_per_sec` | 仪式 / 魔法石 / 药水；**不自回**，用尽 → `depleted` 不可修 |

复用 [reaction-schema.md §7.4b](./reaction-schema.md) 已落地的 `wand_charges` / `max_wand_charges` / `depleted`。

### 3.2 威力四因子

施法威力不是单一数值，由四个正交因子相乘。**引擎在调 Lua 前算好塞进 `ctx`，Lua 不碰公式**：

```
spell_power = base_power                              # ① reaction 字段：咒的天生强度
            × mastery[spell]                          # ② 角色熟练度（= 现有 per-verb mastery）
            × wand.power                              # ③ 魔杖威力倍率
            × wand.affinity.get(reaction.school, 1.0) # ④ 杖 × 学派契合
```

| 因子 | 来源 | 出处 |
|---|---|---|
| `base_power` | Reaction `.tres` | 新增字段（类比已有 `base_difficulty`） |
| `mastery[spell]` | 角色 per-verb mastery [0.6, 1.5] | 复用 [reaction-schema §6.2](./reaction-schema.md) |
| `wand.power` | 魔杖实例属性 | §4.2 |
| `wand.affinity[school]` | 魔杖实例属性 × `reaction.school` | §4.2 + 新增 `reaction.school` |

**每个咒 = 一个 verb**：`mastery["wingardium"]` 就是漂浮咒熟练度，直接复用 crafting 的 per-verb mastery，不另起 skill 表。

### 3.3 难度 / 失败 — 全归 Reaction

难度**不在 Spell 上**，在 Reaction（[reaction-schema §2.3 §7.3](./reaction-schema.md) 已有 `difficulty: float` 0..1）：

```
fail_chance = clamp(reaction.difficulty − (mastery[spell] − 0.6), 0, 1)
```

**"浮人比浮物难"不写额外字段**——用现有"多条 reaction + 约束多的赢"（[reaction-schema §4.4](./reaction-schema.md)）：

```gdscript
# levitate_object.tres    verb=wingardium  difficulty=0.15  inputs=[{"tags_none":["creature"]}]
# levitate_creature.tres  verb=wingardium  difficulty=0.55  inputs=[{"tags":["creature"]}]
```

同一 verb，dispatcher 按目标 tags 自动选难的那条。零新机制。

### 3.4 "法力高强" = 派生量 arcane_power

法力高不高不存字段，从已学咒的熟练度按难度加权派生：

```
m_norm(s)       = clamp((mastery[s] − 0.6) / 0.9, 0, 1)          # 归一到 0..1
arcane_power(c) = Σ_known( m_norm(s) × R(s).difficulty )
                  / ( Σ_known R(s).difficulty + baseline )        # 0..1；baseline 防"只会一简单咒就高"
```

- 只会 lumos / stupefy 的一年级生 → arcane_power 低
- 会十几个高难咒且都练熟 → arcane_power 接近 1

**用途仅这两处（威力不走它）**：
- **学习门槛**：`can_learn(spell) iff arcane_power ≥ R(spell).difficulty × 0.5`。学生 arcane_power 0.07 想学 avada（difficulty 1.0，门槛 0.5）→ 学不会，禁咒书翻不开
- **新咒下限**：刚学会的咒 mastery 起步 0.6，但高 arcane_power 角色有效 mastery 抬一点（天才上手快）

**"学生施不出杀人"双重保证**：① 学不会高难致死咒；② 即便施出，mastery 低 → spell_power 低 → 达不到 reaction 的 `lethal_threshold`。

### 3.5 派生量落地 + 关键决策

按 [memory: feedback_derived_state_persist_single_writer]：
- **真值**：`mastery[spell]`（per-verb，存 DB）+ wand 实例字段
- **派生**：`arcane_power` / `spell_power` 由 Godot 单一 getter 算，cast 时塞 ctx；backend 不抄公式，从 perception manifest 拿算好的值

1. **施法不吃 stamina**（魔力在杖，体力是身体），两轴独立："打不过就跑"和"魔力没了"是不同战术决策
2. **HP = 0 → Knockdown**（倒地 N 秒 1HP 起身，倒地无敌防连杀），MVP 无 permadeath
3. **cast_time = de facto CD**；念咒被打断不扣 energy（§6.3 动画零状态机兜底）

---

## 4. 类型系统

三层职责：**Spell = 投递层**（怎么瞄 / 怎么飞 / 怎么命中），**Reaction = 物理层**（命中后发生什么 + 难度 + 学派，复用 reaction-schema），**Wand = 装备层**。effect 永不写在 Spell。

### 4.1 Spell（投递层）

```gdscript
# data/spells/wingardium.tres
class_name Spell
extends Resource

@export var id: StringName = &"wingardium"            # 同时是 verb id
@export var display_name_key: String = "spell.wingardium.name"   # i18n catalog

# 投递方式
@export var target_type: String = "channel_control"   # §4.3
@export var target_filter: PackedStringArray = ["item", "character"]   # 能作用于谁
@export var cast_time_sec: float = 0.4                 # 念咒 / CD（instant）；channel 是起手时间

# 命中后触发哪个 verb 的 reaction（空 = 用 id 自身）
@export var effect_verb: String = ""

# 能量（P0 手写；P1+ 由成本计算器从 reaction 聚合，见 §5.5）
@export var charge_cost: int = 0                       # instant 用
@export var drain_per_sec: float = 0.0                # channel 用

# 视觉 / 听觉
@export var projectile_visual: PackedScene
@export var sound_cast: AudioStream
@export var icon: Texture2D
```

**Spell 上没有 difficulty / school / base_power**——全在 reaction（§4.4）。Spell 只描述"魔法怎么送达"。

> Display name 走 i18n catalog（[memory: project_prompt_i18n_catalog](#)）：`data/i18n/<locale>/spells.json`。

### 4.2 Wand（装备层）

`Item` 子类。

```gdscript
# src/combat/wand.gd
class_name Wand
extends Item

@export var power: float = 1.0                # 威力倍率（因子③）
@export var affinity: Dictionary = {}         # {school: 倍率}，缺省 1.0（因子④）
@export var spell_slots: int = 4

# Item.properties 携带的实例字段（随 inventory 持久化）：
#   "wand_charges": float     — 当前储能
#   "max_wand_charges": float — 容量上限（独立，杖芯材质写入，不由 power 派生）
#   "loadout": Array          — 长度 spell_slots 的 spell_id 数组；"" = 空槽
```

例：

```
冬青木凤凰羽杖  power=1.2  affinity={charm:1.3, dark:0.6}    # 擅魅惑、克黑魔法
紫杉木夜骐尾杖  power=1.3  affinity={dark:1.4, charm:0.7}
橡木通用杖      power=1.0  affinity={}                       # 全 1.0
```

**power（威力）与 max_wand_charges（储能）解耦**：好杖可以威力高但储能一般，或反之，给装备深度留空间。loadout 走 `properties`（运行时玩家改，随实例持久化）；power / affinity 走 `@export`（杖的固有品质，模板定）。

### 4.3 target_type + delivery kind（两条正交轴）

**target_type**（Spell 字段，决定输入 / UI / 瞄准）：

| target_type | 输入 | 例 |
|---|---|---|
| `self` | 无瞄准 | 铁甲咒、福灵剂 |
| `aimed_point` | 准星射线命中的 3D 点 | 烈焰熊熊 |
| `aimed_entity` | 必须命中实体 | 恢复如初、摄神取念 |
| `aimed_directional` | 只给方向 | 弹道类、幻影移形 |
| `channel_action` | 长按 + 过程（打字 / 进度条） | 摄神取念、阿拉霍洞开 |
| `channel_control` | 长按 + 每帧操控目标 | 漂浮咒、飞来咒 |

**delivery kind**（`on_cast` 返回值，决定运行时怎么生成）+ 各自的**运行时后端**：

| kind | 含义 | 必要参数 | 后端 |
|---|---|---|---|
| `projectile` | 飞行弹道（Area3D） | speed, ttl_sec, visual; 可选 pierce / gravity / homing | SpellProjectile（§4.5） |
| `hitscan` | 立即射线判定 | max_range, cone_deg | 引擎射线 |
| `area` | 世界某点的区域场（火/雾/水洼） | center, radius, ttl_sec | **EffectVolume**（§6.5 BurningRegion 是其原型，泛化）|
| `self_attach` | 挂实体/骨头上、caster 拥有（lumos 挂杖尖、protego 挂 self） | anchor_bone, params, sustain, mana_per_tick | **ActiveEffect**（[entity-model §2.4](./entity-model.md)，lumos 是其"待建第一个光球法术"）|
| `channel` | 持续控制链 | target_filter, max_range, drain_per_sec | channel 管理器 + §5.1 三段契约 |

两轴正交：aimed_directional + projectile（昏迷咒）、aimed_point + area（烈焰熊熊）、self + self_attach（lumos）、channel_control + channel（漂浮咒）。

**两种持久后端别混**：
- **ActiveEffect**：锚在实体/骨头，caster 拥有，引擎在 caster 死亡/离线/进反魔法区时统一清理（光、盾）。声明式——`on_cast` 返回 `self_attach`，引擎照返回值建，**lua 不手动 spawn**
- **EffectVolume**：世界坐标的区域场，有 ttl + 重叠检测（火、气）。可 imperative 生成（`affect.spawn_volume`，§5.3）或由扰动级联（`emit_heat` → 点燃，§6.5）。`area` 的 ttl 有**两义**，同 kind 不拆：**瞬时爆发**（ttl≈0，灌一下扰动就消失，后果交给级联点燃的 BurningRegion，如 incendio_maxima）vs **持续场**（ttl 长 / until_dispel，area 本身就是那个 EffectVolume，如毒云）

> 注意 `Substance`（[entity-model §3](./entity-model.md) 的 wood/stone/metal/flesh… 基础材质）**不是**这里的场效应——光/雾/气走 ActiveEffect / EffectVolume，不要和基础材质混名。

### 4.4 Reaction 的战斗扩展（复用 schema + 一个新字段）

战斗 reaction **完全复用** [reaction-schema.md](./reaction-schema.md)，唯一新增 `school` 给 wand affinity 当 key。目标实例从"物品"扩展到 "Character"——`modify` 的 `delta_properties` / `add_tags` 同样作用于角色的 hp / statuses。

```gdscript
# data/reactions/stupefy_creature.tres
verb = "stupefy"            # = spell.id（或 spell.effect_verb）
trigger = "active"
school = "combat"           # ← 唯一新增字段，wand.affinity[school] 取它
difficulty = 0.2
base_power = 1.0            # ← 新增，威力因子①
inputs = [{"tags": ["creature"]}]                    # 匹配 Character
material_strategy = "modify"
outputs = [{
    "modify": "@target",
    "delta_properties": {"hp": "-8 - 12 * @power"},  # @power = 引擎注入的 spell_power
    "add_tags": ["stunned"],
}]
# stunned 持续时长走 status schema（§4.6）
```

> `@power` 是新表达式变量（[reaction-schema §4.5b](./reaction-schema.md) 的扩展），引擎按四因子算好后注入，reaction 公式可读。

reaction 本身仍是**纯声明数据，无 Lua**（[reaction-schema §11](./reaction-schema.md) 禁 `effect_script`）。"咒语的物理" = reaction 的 modify / difficulty / school，不是一段脚本。

### 4.5 SpellProjectile（运行时节点）

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
var spell_power: float            # 生成时定格 attacker 四因子威力；盾 / 抗性 / 减伤命中时读（§6.6）
var on_hit_callback: Callable     # = SpellCaster.handle_hit
```

> `spell_power` 进 projectile 是通用基础设施——不只 protego，将来魔法抗性护甲、减伤 buff 都要在命中时知道"这发多强"。

`_physics_process` 推进位置 + 倒计时 ttl；`area_entered` / `body_entered` 触发 `on_hit_callback`。

### 4.6 战斗 Statuses

status 由 reaction 的 `modify add_tags` 产生，复用 `Character.active_statuses`（[player-stats.md §7](./player-stats.md)），不新建表：

| Type | 来源咒 | 效果 |
|---|---|---|
| `stunned` | 昏迷咒 | 无法移动 / 施法 / dodge，N 秒 |
| `bound` | 束缚咒 | 无法移动 / 施法，但**有意识能说话** |
| `silenced` | 沉默咒 | 不能施法但能动 |
| `disarmed` | 缴械咒 | 强制 unequip wand 到地上 |
| `shielded` | 盔甲护身 / protego | 命中前消弹（HitResolver 检测）；**带数值** `block_power`（施法时定格的 spell_power），见 §6.6 |
| `burning` | 火咒 | 每 tick 减 HP |
| `bleeding` | 神风无影 | 每 tick 减 HP（DoT） |
| `regen` | 持续恢复 | 每 tick 加 HP（HoT） |
| `levitated` | 漂浮咒 | 受 channel 控制，悬空 |
| `deafened` | 闭耳塞听 | 听不到声音（影响 perception） |
| `lucky` | 福灵剂（**药剂非咒**，走 item use_effects） | **带数值** `luck`；引擎里**每个随机 roll 统一过 luck 修正**（reaction 成败 / 制作品质 / 命中闪避 / 掉落），`effective_chance = base ± luck` |
| `hexed` | 黑魔法 | 减 stamina cap / 命中率 debuff |

> 不新建表，复用 `active_statuses` 数组；落库走现有 `Character.upsert_snapshot()`。`on_tick` 类（burning/bleeding/regen）需要 status 支持每 fast tick 回调（§5.1）。

### 4.7 咒语目录 — 第二批（填表咒，零新原语）

前 5–6 个原型（昏迷 / lumos / 烈焰熊熊 / 漂浮 / 盔甲护身 / 摄神取念）逼出了全部 schema 与投递层 API；其余咒**绝大多数 = 新建一条 reaction（effect / 学派 / 难度填表）+ 给目标加一条 status**，不碰投递层、不加 lua 原语。下表是验证而非扩展——**全部命中 §4.1–4.6 + §5.3 已有契约**：

| 咒 | target_type / delivery | reaction 做什么 | status |
|---|---|---|---|
| 恢复如初（heal） | `aimed_entity`（含 self）/ projectile | `heal` → modify hp **+**（一次性） | — |
| 点燃（ignite） | `aimed_directional` / projectile | `on_hit` → `emit_heat(hit_pos, 600, 0.3)` 小半径（§6.5 烈焰熊熊弱化版） | `burning`（级联自带） |
| 束缚咒（bind） | `aimed_directional` / projectile | `bind` → add_tags | `bound`（已列：禁动能说话） |
| 持续恢复（HoT） | `aimed_entity` / projectile | `regenerate` → add_tags | `regen`（on_tick +hp） |
| 神风无影（bleed） | `aimed_directional` / projectile | `lacerate` → add_tags | `bleeding`（on_tick −hp） |
| 飞来咒（accio） | `channel_control`，target_filter `{"item"}` | `pull_to(item, caster_hand)` → 到手 release（§5.3 已有 `pull_to`） | — |
| 幻影移形（blink） | `aimed_directional` / self | `teleport(caster, raycast 第一障碍前)`（§5.3 已有 `teleport`） | — |
| 铁甲咒（armor buff） | `self` / self_attach | `iron_armor` self → add_tags 带 `block_power` | `shielded`（已列，§6.6 减伤通道） |

**深挖过的几个特例**（不在上表，各逼出一个小点，见 §5.6 / 修订记录）：
- **闭耳塞听**（deafen）：`react.apply("deafen")` 加 `deafened` —— "聋怎么影响听觉"是 perception 层下游事，不进战斗 schema
- **阿拉霍洞开**（alohomora 开锁）：`channel_action`，**不建 Lockable 实体**，成功 = reaction 把 caster 授权进容器的 access 作用域（复用 [project_groups_access_model]）；reaction effect 首次输出「访问授权」，与 memory 同属「effect 不走物理、合法例外」
- **福灵剂**（luck，**药剂非咒**）：item use_effects 挂 `lucky`（带数值 `luck`），引擎每个随机 roll 统一过 luck 修正
- **驱逐咒**：用户暂移除

---

## 5. Lua 契约

**两层分明**：
- **Spell delivery lua**（每咒一个 `.lua`）：只管投递——瞄准、弹道、channel 操控，命中那一刻**触发 reaction**。发明新咒主要写这层。
- **Reaction**（声明式 `.tres`，无 lua）：命中后的物理后果 + 难度 + 学派。effect 在这里，不在 lua。

桥梁是 `react.apply(verb, target, ctx)`——delivery lua 把"做什么"委托给 reaction 系统。

### 5.1 契约函数

| 函数 | 何时调 | 适用 target_type |
|---|---|---|
| `on_cast(ctx)` | 施法峰值帧（§6.3） | 全部；返回 delivery kind |
| `on_hit(ctx, target)` | 弹道 / hitscan 命中 | projectile / hitscan |
| `on_area_tick(ctx)` | area 每 fast tick | area |
| `on_channel_start(ctx, target)` | channel 建立 | channel_* |
| `on_channel_tick(ctx, target)` | channel 每帧（喂 aim） | channel_control |
| `on_channel_end(ctx, target, reason)` | 松手 / 超距 / 没蓝 / 打断 | channel_* |
| `on_sustain_end(ctx, reason)` | self_attach 结束（toggle / 没蓝 / 死亡 / 反魔法区） | self_attach |

另：status 的 `on_tick`（burning / bleeding / regen）由 status schema 提供，每 fast tick 回调，不在 spell lua 里。

三个范例（projectile / channel / self_attach 各一）：

```lua
-- data/spells/stupefy.lua  （aimed_directional + projectile）
function on_cast(ctx)
  -- ctx: { caster_id, aim_origin, aim_dir, now_game, ... }
  return { kind = "projectile", speed = 22.0, ttl_sec = 2.0, visual = "stunner_bolt" }
end

function on_hit(ctx, target)
  if not target then return end                          -- 撞墙（target_filter 已拦）
  local r = react.apply("stupefy", target.id, ctx)       -- 伤害 + stunned 走 reaction
  if r.ok then                                            -- 难度/学派/威力/失败引擎已结算
    affect.apply_impulse(target.id, {dir = ctx.travel_dir, magnitude = 8 + 6 * r.power})
  end
end
```

```lua
-- data/spells/wingardium.lua  （channel_control + channel）
function on_cast(ctx)
  return { kind = "channel", target_filter = {"item","character"}, max_range = 12.0, drain_per_sec = 3 }
end

function on_channel_start(ctx, target)
  local r = react.apply("wingardium", target.id, ctx)    -- 选 object/creature 变体，gate 能不能抓
  if not r.ok then return "release" end                  -- 难度太高没抓住 → 放手
  ctx.lift = r.power                                      -- reaction 算出的 power 决定能浮多重多快
end

function on_channel_tick(ctx, target)
  affect.lift_toward(target.id, {to_point = ctx.aim_point, max_speed = 4.0 + 4.0 * ctx.lift})
end

function on_channel_end(ctx, target, reason)
  affect.release_hold(target.id)                         -- 解控，物理接管下落；reason 可分支
end
```

```lua
-- data/spells/lumos.lua  （self + self_attach；toggle 维持态，零 effect/零目标）
function on_cast(ctx)
  if ctx.is_active then return { kind = "toggle_off" } end   -- 已亮 → 这次按熄灭
  return {
    kind        = "self_attach",          -- 引擎照此建 ActiveEffect（entity-model §2.4）
    effect_type = "light",
    anchor_bone = "wand_tip",             -- 挂杖尖，随移动（BoneAttachment3D，§6.3）
    mana_per_tick = 0.2,                  -- 缓慢耗杖能；耗尽强制熄
    sustain     = "until_toggle",         -- 维持到再按 / 没蓝 / 死亡 / 反魔法区
    params      = { intensity = 0.7 + 0.6 * ctx.mastery_ratio,   -- 越熟越亮、照得越远
                    radius    = 4.0 + 4.0 * ctx.mastery_ratio }, -- radius 喂 perception（被更远看到）
  }
end
-- 无 on_hit / on_channel_tick：引擎自管 drain + 挂点跟随。on_sustain_end 可留空（lumos 无善后）
```

> lumos 验证了"**投递层独立于 effect 层**"自洽：一个咒可以零目标、零 `react.apply`、零 status——只有投递。它就是 [entity-model §3](./entity-model.md) 未实现清单里"待第一个光球法术"驱动的 ActiveEffect。

### 5.2 `react.apply` — 触发 reaction（effect 主路径）

```lua
local r = react.apply("stupefy", target.id, ctx)
-- 引擎：按 verb + 目标 tags 选 reaction → 算 spell_power（四因子）→ roll fail_chance
--      → 成功则应用 modify（hp / statuses）→ 返回结果
-- r = { ok = true/false, power = 0..N, fail_reason = "" }
```

- **难度 / 学派 / 威力 / 失败全在引擎侧算**（用 reaction.difficulty/school/base_power + wand + mastery），lua 只拿结果
- 失败（fail_chance 命中）→ `r.ok = false`，lua 自行决定后续（如 channel 松手、播放 fizzle）

### 5.3 投递层物理 API（kinematic 扰动）

reaction 的 modify 表达不了的"运动学扰动"走这些——直接操控物理，**不写连锁**（[memory: feedback_prefer_simpler_designs]，惯性/生理连锁不模拟）：

```
affect.apply_impulse(id, {dir, magnitude})                       -- 一次性冲量（击飞，接 §6.4 ragdoll）
affect.lift_toward(id, {to_point, max_speed, overcome_gravity})  -- 受控悬浮（漂浮咒）
affect.release_hold(id)                                          -- 解除悬浮，物理接管下落
affect.pull_to(id, point, max_speed)                            -- 牵引（飞来咒）
affect.teleport(id, to_point)                                   -- 瞬移（幻影移形，撞墙停）
affect.emit_heat(point, temp, radius)                           -- 局部升温 → 触发环境 reaction（§6.5）
affect.emit_cold(point, temp, radius)                           -- 局部降温 → 结冰 / 灭火
affect.spawn_volume(point, kind, {amount, ttl, radius})         -- 世界某点生成区域场（雾/水/睡眠气）→ EffectVolume
affect.attach_effect(anchor_id, kind, {anchor_bone, params, mana_per_tick})  -- 挂实体上的持久效果 → ActiveEffect
```

> `spawn_volume`（原 `spawn_substance`，**改名避开** [entity-model §3](./entity-model.md) 的 `Substance` 基础材质）建 EffectVolume（§6.5 BurningRegion 家族）；`attach_effect` 建 ActiveEffect（锚实体/骨头，caster 拥有，§4.3）。lumos / protego 这种声明式挂载用 `on_cast` 返回 `self_attach` 即可，不必手动调 `attach_effect`；imperative 场景（如 channel 中途追加挂载）才直接调。

**两条进 reaction 的路**：
1. **直接**：`react.apply(verb, target)` —— targeted 效果（stun / heal / lift 门槛）
2. **间接**：`emit_heat` / `spawn_volume` —— 扰动世界，**现有环境 reaction 自动级联**（草着火、水结冰、睡眠气把人转 stunned）。incendio 走这条（§6.5）

两条最终都落在 reaction = 物理（[memory: project_reactions_are_physics]）。delivery lua 自己**永不写 hp/status**，那是 reaction 的事。

**`emit_heat` 级联的三条铁律**（AOE 元素咒——火/冰/电/毒——统一遵守）：
- **lua 不查场景**：incendio 只 `emit_heat(中心, 900, 半径)`，**不查里面有什么、不判可燃、不点火**。引擎扫半径内物体，逐个对照材质 `ignition_point` 各自响应（草烧 / 木慢燃 / 石升温 / 水蒸发 / 铁变烫）。新增任何可燃物，老咒自动能与之交互，不改一字
- **人和草一视同仁**：`flesh` 也是有 `ignition_point` 的材质，被烤到就触发"灼烧"reaction（modify hp + burning），**和草着火同一条级联**——lua 不区分"生物要 react.apply / 草要烧"。所有 AOE 元素咒都不在 lua 里单独找人
- **触发 lazy-materialize**：大片草地不预存温度（[entity-model §2.1](./entity-model.md)），`emit_heat` 落点才把那片地形实例化成温度实例再判定。incendio 是这个既定机制的第一个真实消费者

> 实现沿用 [scripting-layer.md](./scripting-layer.md) 的 `script_api.gd:inject` 模式：`affect.*` / `react.apply` 不直接改世界，往 `collected_effects` 推声明，下个 fast tick 边界由 `HitResolver` 统一 apply（[reaction-schema](./reaction-schema.md) 的边界结算原则）。

### 5.4 查询 API（只读）

```
query.distance(a, b)             query.find_nearest(point, filter)
query.get_tags(id)               query.mastery(caster_id, spell_id)
query.aim_point(caster_id)       query.has_status(id, type)        -- 福灵剂读 lucky 等
```

### 5.5 成本计算（P1+）

自创咒不能手填 `charge_cost`。计算器从 lua 用到的 API + `react.apply` 命中的 reaction 成本聚合：

```
charge_cost = Σ api_weight(T1 API × 参数强度) + Σ reaction_cost(react.apply 的 reaction)
```

极端参数走**软限**（cost 指数爆炸，"想 -99999？cost 1000，没人用得出"）+ 兜底硬限（防内存炸）。P0 手写咒先填 `charge_cost`；P1 接计算器后改为派生。这是"玩家自创咒自我平衡"的关键——可以创任何咒，但算出来未必用得起 / 学得会（§3.4 学习门槛）。

### 5.6 心智咒：调 DM Agent（`mind.*` / `notify.perceive`）

摄神取念（legilimens）是 5 个原型里唯一碰 LLM 的咒。它**不是**即时战斗咒——是个慢 `channel_action`，期间玩家打字、后端跑 agent、被害者活着反抗。它的 effect（改 memory）**不走 reaction**（记忆内容没法用物理表达），而是**调 DM Agent 的 `update_memory`**（§8.3）。

```lua
-- data/spells/legilimens.lua  （channel_action：侵入心智 → DM Agent 的 update_memory）
function on_cast(ctx)
  return { kind = "channel", sub_kind = "action", target_filter = {"character"},
           max_range = 8.0, drain_per_sec = 2.0 }
end

function on_channel_start(ctx, target)
  local r = react.apply("legilimens", target.id, ctx)   -- gate：对方 occlumency 走 difficulty
  if not r.ok then return "release" end                  -- 大脑封闭术挡住 → 侵入失败

  -- 让 backend 用 DM Agent 开一个"仅 update_memory"的编辑会话，玩家打字喂指令
  mind.open_edit(target.id, {
    caster_id    = ctx.caster_id,
    allow_tools  = {"update_memory"},        -- ★ 严格 scope：DM 此刻只有这一个工具
    prompt_source = "player_typing",
  })

  -- 被害者"察觉"延迟：熟练度越高静默越久（3s 生疏 .. 10s 精通，真实时间）
  notify.perceive(target.id, "mind_intrusion", { by = ctx.caster_id },
                  { delay_real_sec = 3.0 + 7.0 * ctx.mastery_ratio })
end

function on_channel_tick(ctx, target)
  if not mind.edit_pending(target.id) then return "release" end   -- DM 已 update_memory → 结束
end

function on_channel_end(ctx, target, reason)
  mind.close_edit(target.id, reason)
  -- update_memory 是原子写：reason="completed"=已写入；其它=DM 还没调工具，什么都没留（无需回滚）
end
```

**新 API 两类**：

```
mind.open_edit(target_id, {caster_id, allow_tools, prompt_source})   -- backend 起 scoped DM 会话
mind.edit_pending(target_id) -> bool                                 -- DM 是否还没调完工具
mind.close_edit(target_id, reason)                                   -- 提交（DM 已写）/ 取消

notify.perceive(target_id, kind, data, {delay_real_sec})            -- 咒主动产生感知事件（喂被害者 thinking）
```

- **`mind.*` 跨进程**（Godot → backend），但分工不破 [memory: feedback_godot_is_authority]：Godot 管"能否侵入 / 连接维持 / 何时断"（react.apply + channel 生命周期），backend 管"memory 内容怎么改"（本就是 backend 领域）
- **`notify.perceive` 的 `delay_real_sec`** 复用 [memory: feedback_perception_filter_at_source]：在事件产生处（on_channel_start）按 intrusion_power 决定延迟多久才推给被害者，实现"熟练度越高对方反应越慢"
- **原子写**：update_memory 一次性，无半写态。被害者在静默窗口内打断 → DM 还没调工具 → 记忆毫发无损，这就是反抗的价值

> 心智咒族（imperio 夺魂 / obliviate 遗忘）将来都走这条：调 DM Agent + 不同 scoped tool。

---

## 6. 运行时模块

### 6.1 模块清单

| 模块 | 位置 | 责任 |
|---|---|---|
| `CastController` | `src/characters/parts/cast_controller.gd` | Character 子节点。接受 input（数字键 1-N）/ 外部命令 / LLM tool；查 loadout；播 cast 动画；动画 method-track 触发瞬间调 `SpellCaster.cast` 并扣 charges（见 §6.3）|
| `SpellCaster` | `src/combat/spell_caster.gd` | 工具类。调 `ScriptExecutor.execute(spell.lua_source, "on_cast", ctx)` → 拿 `collected_effects` → 路由（projectile → ProjectileService / aura → StatusService / instant → HitResolver）|
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
- 站在火里的生物受持续伤害 + 贴 `burning` status
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
| `flesh`（已存在） | 通过角色 status 处理，不挂 BurnableSurface |  |  |

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

#### 咒语 Lua 走 emit_heat（不手动判可燃）

按 §5.3 的"间接进 reaction"路径，incendio 的 delivery lua **不自己判断可燃、不自己 spawn 火**——只在命中点升温，由引擎查附近 `BurnableSurface` 决定点燃谁：

```lua
-- data/spells/incendio.lua  （aimed_directional + projectile）
function on_hit(ctx, target)
  if target then react.apply("incendio", target.id, ctx) end   -- 命中生物：烧伤 + burning，走 reaction
  affect.emit_heat(ctx.hit_pos, 800, 2.5)                       -- 命中点升温 → 引擎查 BurnableSurface → 点燃
end
```

**点火判定从 lua 移到引擎的 heat→ignite handler**：`emit_heat` 落点后，引擎扫半径内的 `BurnableSurface`，凡 `material.ignite_temperature ≤ 升温` 的就 spawn `BurningRegion`（用该 surface 的 `radius_hint` / `burn_duration_mult` / `on_burnt_scene`）。BurnableSurface 这层只回答"这个 mesh 是不是燃料、烧多久、烧完啥样"，是 mesh 级燃料表；要不要烧由温度物理决定。这样自创"低温咒"`emit_cold` 能复用同一套 surface 去灭火 / 结冰，无需新逻辑。

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
            body.add_status("burning", 3.0)
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

`burning` status 已经在 §4.4 buff/status 表里。BT 添一个 leaf：

```
Sequence: CheckStatus("burning") → MoveAwayFrom(nearest_burning_region) → CheckWaterNearby → SeekWater
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

- 咒语命中触发 BurningRegion spawn：走 §5 Lua → `affect.emit_heat` → 引擎 heat→ignite handler 查 BurnableSurface
- BurningRegion 给 Character 贴 `burning` status：走 §4.6 status 体系
- 着火 NPC 受击：与 §6.4 受击反馈互不冲突，status 是持续 debuff，hit reaction 是瞬时动画

### 6.6 盾 / 减伤结算（HitResolver 前置）

**问题**：protego（盔甲护身）要拦截飞来的弹道，还要按双方威力判定能不能被穿破——这是 5 个原型咒里唯一的"咒 vs 咒"。

protego 本身**很被动**：`on_cast` 返回 `self_attach` 建一个 `shield` ActiveEffect（和 lumos 同后端，§4.3），记下 `block_power = 施法时的 spell_power`。真正的拦截不在 protego 里，在 **HitResolver 跑命中前的前置检查**。

#### 减法穿透模型

弹道命中 defender，HitResolver 在执行 `on_hit` / `react.apply` 前先结算减伤：

```
attack_power = projectile.spell_power               # 弹道生成时定格（§4.5）

effective_block = max(blocks) + 0.5 * (Σ其余 blocks)  # 多源叠加递减（防全堆满无敌）

leftover = attack_power − effective_block
  leftover ≤ 0  → 完全挡下：弹道消失 + 盾闪特效；盾按 attack_power 损耗；on_hit 不执行
  leftover > 0  → 盾碎（移除 ActiveEffect + 碎裂特效）；咒以剩余威力 leftover 穿透，
                  on_hit / react.apply 拿到打折的 spell_power = leftover
```

对方略强 → 只漏一点；强很多 → 大部分穿透。连续、双方数值参与、天然兼容多源减伤。系数（0.5 递减、损耗量）落地调参。

#### 减伤来源统一通道

你提的"铁甲钢甲能抗咒""铁甲咒 buff"和 protego **走同一判定点**，只是 `block_power` 来源不同：

| 来源 | block_power 怎么来 | 触发 | 耗能 |
|---|---|---|---|
| protego（主动盾） | 施法时的 spell_power | 举盾期间 | mana_per_tick |
| 铁甲 / 钢甲（被动装备） | 装备材质 `armor_value`（铁 > 皮） | 一直在 | 无 |
| 铁甲咒（buff，#18） | `shielded` status 的 `block_power` | buff 期间 | 一次性 |

HitResolver 命中前汇总所有减伤来源 → `effective_block` → 比 attack_power。"穿板甲 + 举盾"叠起来更难破，符合直觉。

#### 威胁分类 × 抵抗机制（盾不是万能）

盾**只挡定向投射物**，其他威胁各有各的抵抗，不全堆给盾——给咒库留差异化空间：

| 威胁 delivery | 抵抗机制 |
|---|---|
| `projectile` / `hitscan` | §6.6 减伤通道（盾 / 甲 / buff） |
| `area`（AOE 环境，incendio 的 emit_heat 级联） | **盾不挡**；要挡靠"防火罩"类专门咒 / 材质抗性 |
| `channel`（漂浮 / 束缚等控制） | 走 `react.apply` 的 reaction `difficulty` vs 目标抗性（§3.3），不混进盾 |

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

### 8.3 DM Agent — 心智咒的后端（战中唯一合法的 LLM 调用）

§8.1 说"战斗不进 LLM"，**心智咒（摄神取念）是受控的例外**——它不是即时战斗咒，是慢 channel，双方都在等，所以不破坏战斗节奏。它的 LLM 调用走一个独立角色：

**DM Agent**（规划中，比战斗系统更广）= 特权世界编辑器。服务器管理员发一段文本，DM 去改世界：给 A 加面包（`modify_inventory`）、给 B 加记忆（`update_memory`）。**使用者永远是 DM**，玩家 / NPC 不直接持有这些工具。

摄神取念 = 玩家在游戏内、受技能门槛限制地，**触发 DM Agent 的 `update_memory`**，但：

| 约束 | 实现 |
|---|---|
| **工具严格 scope** | `mind.open_edit` 的 `allow_tools=["update_memory"]`——此刻 DM **只有这一个工具**可用，玩家不能借摄神取念加面包 |
| **能否调用由 Godot gate** | `react.apply("legilimens")` 的 difficulty（对方 occlumency）决定连接建不建立 |
| **内容由玩家打字** | `prompt_source="player_typing"`，DM Agent 按玩家指令改 target memory |
| **原子写** | DM 调一次 `update_memory` 即完成，无半写态（§5.6） |

**为什么不破 [memory: feedback_godot_is_authority]**：Godot 管"魔法物理"（能否侵入 / 连接维持 / 何时断），DM/backend 管"心智内容"（memory 本就是 backend 领域）。分工不重叠。

> 心智咒族（imperio 夺魂 → DM 的 `force_action` / obliviate 遗忘 → DM 的 `update_memory` 删除模式）将来都走"调 DM Agent + 不同 scoped tool"。DM Agent 的完整设计是独立文档（待建），本节只锁定战斗侧的接入契约。

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
| 与 crafting reaction 的关系 | **统一**：咒语 effect = reaction（difficulty/school/modify 复用 [reaction-schema](./reaction-schema.md)），目标实例从物品扩到 Character。施法投递层（弹道/channel）是战斗专属，effect 层不分家。风险点：reaction dispatcher 要能匹配 Character 实例（tags=creature）而不只是物品 |
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
- ~~**⚠️ Wand schema 三处不一致**~~ **已收敛（2026-06-05）**：[entity-model §2.2](./entity-model.md#22-角色资源模型) 已回写，删掉 stale 的 `spell_energy_regen_per_sec`（自回）+ `channel_efficiency`（抽 stamina），统一命名 `wand_charges` / `max_wand_charges` + `power` + `affinity` + `depleted`（不可修），三文档同源（entity-model §2.2 / [reaction-schema §7.4b](./reaction-schema.md) / 本文 §4.2）
- **Substance vs Material 概念重叠**：[entity-model §3](./entity-model.md) 的 `Substance`（8 种基础材质）与 [reaction-schema §2.1](./reaction-schema.md) 的 `Material`（iron/grass…）职责重叠，是跨域历史债。不影响战斗设计，但 `emit_heat` → 点燃判定最终读哪套材质字段要在落地前定

---

## 修订记录

- 2026-05-29：v1 初稿。从三轮对话沉淀。覆盖到 P4 路径，但 P3-P4 仅占位
- 2026-05-29：§6 拆 §6.1/6.2/6.3；新增 §6.3 动画驱动施法时机（AnimationPlayer method 轨绑 `_on_spell_release`，cast_time_sec 仅作 UI / CD 元数据，真值在动画文件）
- 2026-05-29：新增 §6.4 受击反馈 / 击飞 / Ragdoll（Godot 4 能力档次、击飞四段式 canned + ragdoll 切换、P0-P2 纯 canned / P3 轻 ragdoll / P4 active ragdoll 分阶段落地、与 §6.3 interrupt 的关系）
- 2026-05-29：新增 §6.5 持久区域效果 / 环境状态咒（复用 MapGrid + RegionMap，给 MapRegion 加 surface_type / flammability；BurningRegion node；EventBus water_applied 总线解耦水源与火；持久化；NPC status / BT 互动；焦土留给 P3+）
- 2026-05-29：§6.5 改走 mesh-attached `BurnableSurface` 组件方案，弃用 RegionMap 路径；写明"为什么不走 RegionMap"；复用 `data/materials/*.tres` 已有 flammable / ignite_temperature 字段；第三方 Synty 资源不动，wrapper scene 挂组件；ctx.hit_surface 走查询链；BurningRegion 加 attached_to 跟随物体 + on_burnt_scene 替换烧后视觉
- 2026-06-05：**咒语系统 co-design 第一轮收敛**，重写 §3/§4/§5（pivot：Spell 从"自带物理"降级为纯投递层，effect / 难度 / 学派全下沉到 Reaction）：
  1. **三层职责**确立：Spell = 投递层（target_type + delivery kind + channel 三段契约），Reaction = 物理层（复用 reaction-schema），Wand = 装备层
  2. **角色无 mana**，施法耗魔杖储能；§3 重写为"三资源 + 威力四因子（base_power × mastery × wand.power × wand.affinity[school]）"
  3. **难度归 Reaction**（复用已有 `difficulty`）；"浮人比浮物难"用"多 reaction + 约束多的赢"表达，弃用之前的 `tag_difficulty` 表设计
  4. **法力高强 = 派生量 arcane_power**（按已学咒 mastery × difficulty 加权），仅用于学习门槛 + 新咒下限；"学生施不出杀人"双重保证
  5. **Reaction 新增 2 字段**：`school`（wand affinity 的 key）+ `base_power`（威力因子①）；目标实例扩到 Character（modify 作用于 hp/statuses）；新表达式变量 `@power`
  6. **Wand schema**：`power`（威力倍率）/ `affinity{school}` / 独立 `max_wand_charges`（与 power 解耦）
  7. **Lua 两层 + react.apply 桥梁**：delivery lua 永不写 hp/status；`react.apply` 委托 reaction，引擎算难度/学派/威力/失败回 `{ok, power}`；新增 channel 三段契约（on_channel_start/tick/end）
  8. **投递层物理 API**（kinematic 扰动，不写连锁）：apply_impulse / lift_toward / release_hold / pull_to / teleport / emit_heat / emit_cold / spawn_substance
  9. **两条进 reaction 的路**：直接（react.apply）+ 间接（emit_heat/spawn_substance 扰动世界，环境 reaction 级联）；§6.5 incendio 改走 emit_heat，点火判定从 lua 移到引擎 heat→ignite handler
  10. **玩家自创咒**：成本计算器从 lua API + reaction 成本聚合算 charge_cost（软限 + 兜底硬限），自我平衡（能创任何咒但未必学得会 / 用得起）
  11. §10 风险表"与 crafting reaction 关系"由"不强行套"改为"统一"
- 2026-06-05：**lumos co-design**（§4.3 / §5.1 / §5.3 更新）：
  1. **delivery kind → 运行时后端映射**写入 §4.3：projectile=SpellProjectile / area=**EffectVolume**（BurningRegion 泛化）/ self_attach=**ActiveEffect**（[entity-model §2.4](./entity-model.md)）/ channel=三段契约
  2. **lumos = entity-model 待建的"第一个光球法术"**：光是 ActiveEffect（锚 wand_tip + mana_per_tick 扣能 + radius 喂 perception），不是 status、不是 Substance
  3. **API 改名** `spawn_substance` → `spawn_volume`（避开 entity-model `Substance` 基础材质撞名）；新增 `attach_effect`（imperative 建 ActiveEffect）
  4. **新增契约函数 `on_sustain_end(ctx, reason)`**（self_attach 维持态结束）
  5. **新增 lumos lua 范例**（self_attach、零目标零 effect），坐实"投递层独立于 effect 层"自洽
  6. §11 记两条隐患：**Wand schema 三处不一致**（entity-model stale，需回写）+ **Substance/Material 概念重叠**（跨域历史债）
- 2026-06-05：**烈焰熊熊 co-design**（§4.3 / §5.3 更新，零新 API——验证前两轮 schema 已够表达区域火）：
  1. **`emit_heat` 级联三铁律**写入 §5.3：lua 不查场景（只灌热，引擎按材质各自响应）/ 人草一视同仁（flesh 也是有 ignition_point 的材质，走同一级联，AOE 元素咒都不在 lua 单独找人）/ 触发 lazy-materialize（[entity-model §2.1](./entity-model.md) 的第一个真实消费者）
  2. **`area` 的 ttl 双义**写入 §4.3：瞬时爆发（ttl≈0，后果交级联，incendio）vs 持续场（ttl 长，area 即 EffectVolume，毒云）——同 kind 不拆
  3. 兑现"创造性载体在反应表"：incendio 3 行 lua 能与所有现存 + 未来可燃物交互，不改一字
- 2026-06-05：**盔甲护身 co-design**（§4.5 / §4.6 + 新增 §6.6）——5 个原型里唯一"咒 vs 咒"：
  1. **SpellProjectile 加 `spell_power` 字段**（生成时定格，盾/抗性/减伤命中时读），通用基础设施
  2. **§6.6 减法穿透模型**：`leftover = attack_power − effective_block`；≤0 全挡盾损耗，>0 盾碎 + 咒以剩余威力穿透。比硬阈值更贴"双方数值做计算"
  3. **多源减伤叠加递减**：`effective_block = max + 0.5×Σ其余`（防全堆满无敌）
  4. **减伤统一通道**：protego / 板甲 armor_value / 铁甲咒 buff 走同一 HitResolver 前置点，只是 block_power 来源不同；`shielded` status 带数值 `block_power`
  5. **威胁分类 × 抵抗**：盾只挡 projectile/hitscan；AOE 环境靠专门抗性、控制走 reaction difficulty——盾不是万能，给咒库留差异化
- 2026-06-05：**摄神取念 co-design**（新增 §5.6 + §8.3），收敛完 5 个原型咒：
  1. **channel_action vs channel_control 坐实分叉**：`sub_kind` 字段分流；action 的 tick 不喂 aim，只 poll 外部过程（DM 会话）状态
  2. **新 API 两类**：`mind.open_edit / edit_pending / close_edit`（跨进程起 scoped DM 会话）+ `notify.perceive(…, {delay_real_sec})`（咒主动产生延迟感知事件）
  3. **DM Agent 角色**（§8.3，规划中，比战斗更广）：特权世界编辑器，admin 文本驱动，工具 update_memory / modify_inventory…；摄神取念 = 玩家受技能门槛触发 DM 的 update_memory，**严格 scope 此刻只给这一个工具**
  4. **effect 不走 reaction 的合法例外**：memory 内容没法物理表达 → 调 DM Agent；不破 godot-authority（Godot 管能否侵入/连接，backend 管 memory 内容）
  5. **静默窗口** = intrusion_power → 真实 3s（生疏）..10s（精通）NPC 静默后才 thinking 反应（复用 perception-filter-at-source 的 delay）
  6. **update_memory 原子写**：无半写态，打断 = DM 还没调工具 = 记忆无损，无需回滚——这是被害者反抗的价值
- 2026-06-05：**第二批咒收口**（验证 schema 不扩展，删一个、确认元模式）：
  - **驱逐咒删除**（用户暂时移除）：连带清掉 §4.3 / §4.6 / 修订记录里的 ward 例子；底层 EffectVolume「持续场」概念保留（毒云等仍用）
  - **元结论**：剩余咒**绝大多数 = 新建一条 reaction（effect/学派/难度填表）+ 给目标加 status**，不碰投递层 / 不加 lua 原语。创造性载体在反应表，不在 API（兑现前文设计）
  - **闭耳塞听**（deafen）= `aimed_directional + projectile`，`on_hit` → `react.apply("deafen")` 加 `deafened` status（§4.6 已列）。"聋怎么影响听觉"是 **perception 层下游事**（[feedback_visibility_by_perception] / [feedback_perception_filter_at_source]：感知装配处剔除声音类事件），**不进战斗 schema** —— 战斗侧的契约只到"加 debuff"为止
  - **阿拉霍洞开**（alohomora 开锁）= `channel_action`，target_filter `{"container"}`。**不建 Lockable 实体**：「锁住」= 角色不在容器的 access 作用域内（复用 [project_groups_access_model] 已有闸门）；成功 → reaction 的 modify **把 caster 授权进该容器**，之后正常 put_take / view_container
    - **分熟练度** 零额外代码：锁强度是容器身上的 tag/aspect（非新实体），unlock reaction 按约束数匹配 + fail_chance（[reaction-schema §7.3/§4.4]）让生疏者开不了高级锁——与漂浮咒浮人/浮物同构
    - **新点：reaction effect 首次输出「访问授权」**（以往是 hp / status / delta_properties）。这是 §5.6「effect 不走物理、合法例外」的**第二例**——access 改权限不改物理，与 memory 同类，落 Godot/backend 内容侧（[feedback_godot_is_authority] / [feedback_backend_not_game_db_owner]），不走 react 物理通道
  - **福灵剂**（luck，**药剂非咒**）= item `use_effects` 挂 `lucky` status，**不进咒语投递层**。选定**方案 B 通用 luck 修正**：status 带数值 `luck`，约定**引擎里每个随机 roll 都先过 luck 这一关**（`effective_chance = base ± luck`，覆盖 reaction 成败 / 制作品质 / 命中闪避 / 掉落）。福灵剂自身零逻辑，幸运的"威力"由所有随机判定点统一读取——同"减伤统一通道""感知统一过滤"的一标志多处消费架构
- 2026-06-05：**第二批填表咒落档**（新增 §4.7 咒语目录）+ **全仓 `condition`→`status` 重命名**：
  1. **§4.7 八个填表咒**（恢复如初 / 点燃 / 束缚 / 持续恢复 / 神风无影 / 飞来 / 幻影移形 / 铁甲咒）全部命中 §4.1–4.6 + §5.3 已有契约，零新原语——验证而非扩展 schema，坐实"创造性载体在反应表不在 API"
  2. **术语 `condition`→`status`**：全链路改（16 GD + 2 tscn 同步路径 + 场景节点 + DB 列 activeStatuses[不迁移] + 3 backend ts + 2 lua 动词 affect.add_status + i18n key + 8 doc）。豁免：debug-agent.ts 的 SQL `conditions` 数组、skills.json 行文、crafting-interaction §2.2 的反应谓词 `(substance, condition)`——这三处 condition 是别的意思。Godot 侧需在有引擎环境 F5 验证 + 首启洗库
