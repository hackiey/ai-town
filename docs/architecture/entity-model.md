# Entity model

> Status: **partial** — Substance + Character schema 已 landed；Wand / Item / active_statuses tick / active_effects 未做。

世界里"东西"的统一数据模型。所有物理对象、角色、物品都基于这一层。

## 1. Context

游戏的核心循环（[design-doc §5](../design-doc.md)）依赖玩家创造的剑/法术能跟世界发生 emergent 物理交互——发热、点燃、导电、击碎等。这要求所有物体共享一套底层物理属性（Noita-inspired），而不是每个物体类型自己一套不兼容的字段。

角色（NPC + 玩家）在物理层之上加生命/体力/装备/状态条件，但都是同一套规则——design-doc §7 的"NPC 是一等公民"。

## 2. Design

### 2.1 物理属性（所有物体共享）

```
PhysicalProperties {
  // 几何 / 质量
  mass: float, volume: float,

  // 热学
  temperature: float, thermal_capacity: float, thermal_conductivity: float,
  ignition_point: float | null, burning: bool, burn_rate: float,

  // 状态相变
  melting_point: float | null, boiling_point: float | null,
  state: "solid" | "liquid" | "gas",

  // 力学
  hardness: float,        // 0-1，防穿刺/钝击
  brittleness: float,     // 0-1，易碎度

  // 电
  electrical_conductivity: float,

  // 标签（决定反应规则）
  substance: "wood" | "stone" | "metal" | "flesh" | "water" | "cloth" | ...,
  moisture: float,
}
```

**两个关键决策**：

- **Substance-derived defaults**：`substance: wood` 自动给 ignition_point=300、hardness=0.3、conductivity=低；具体物体只显式存"和默认不同"的字段。Substance 资源不可变共享（.tres），override 字段在 owner 实例上
- **Lazy materialization**：草地瓦片不预先存温度，被火球烤过才在世界里实例化。10000 tile × per-tick 物理会爆炸；只跟踪"被扰动的物体"

### 2.2 角色资源模型

```
Character extends PhysicalProperties {
  substance: "flesh", ignition_point: 250,

  hp, max_hp,
  stamina, max_stamina, stamina_regen_per_sec,
  active_statuses: [...],

  alive, faction, inventory_id,
  equipped: { right_hand?, left_hand?, body?, head? },
}
```

**关键决策：角色没有 mana**。法术能量住在魔杖上：

```
Wand extends Item, PhysicalProperties {
  substance: "wood" | "crystal" | "bone" | ...,

  power,                                   // 威力倍率（spell_power 因子③）
  affinity: { fire?: 0.8, mind?: 1.5 },    // 学派契合，按 reaction.school 取值（因子④）

  // 储能（实例字段，随 inventory 持久化）
  wand_charges, max_wand_charges,          // 独立，不由 power 派生；杖芯材质写入
}
```

**施法资源链**（[combat-system.md §3](./combat-system.md#3-资源--威力模型) 定稿）：

```
玩家施法 (instant cost=20 / channel drain_per_sec)
  → 检查右手有 wand
  → wand.wand_charges >= cost？
      yes → 扣 wand_charges
      no  → fail("not_enough_charge")          // 不抽 stamina，施法不吃体力
```

**三条与早期设计的纠正**（2026-06-05 回写，对齐用户拍板 + [reaction-schema §7.4b](./reaction-schema.md)）：

- **不自回**：删掉 `spell_energy_regen_per_sec`。储能只靠仪式 / 魔法石 / 药水补
- **施法不吃 stamina**：删掉 `channel_efficiency` 和"缺能从 stamina 抽"的资源链。魔力（杖）和体力（身体）两轴独立
- **不复用 durability，用 depleted**：魔杖不走 `durability`/`broken`，独立机制 `wand_charges ≤ 0 → depleted` tag，**不可修复，用完即弃**（[reaction-schema §7.4b](./reaction-schema.md)）

> 命名统一为 `wand_charges` / `max_wand_charges`（原 `spell_energy`/`spell_energy_max` 废弃），三文档同源：本节 + [reaction-schema §7.4b](./reaction-schema.md) + [combat-system §4.2](./combat-system.md#42-wand装备层)。

> 与 [design-doc §3](../design-doc.md) 的偏差：原 design-doc 把 mana 列为第 2 层资源（角色属性）。当前设计把 mana 概念**没消失**但**载体从角色迁到了魔杖**。需要回写 design-doc。

### 2.3 Active statuses：状态条件 vs 数字 buff/debuff

`active_statuses` 是 Smallville-style **文本/标签流**，不是传统 RPG 的数字 buff/debuff。

每条：`{ type: String, started_at: float, duration_sec: float, source_id: String }`，`duration_sec < 0` 表示永久。

理由：LLM 反思要"想"的是"我昨晚被守卫强迫说了真话"，不是"我有 -20 charisma 30 秒"。

条件可以**对游戏机制有数字效果**（被冻僵 = 移动速度 0），但**对 NPC 认知是文本**。两套表达，同源。

### 2.4 持久挂载效果（active effects）

详见 [scripting-layer.md §2.3](./scripting-layer.md#23-持久挂载效果active-effects)。本层只暂列接口：

```
ActiveEffect {
  handle, owner_caster, source_item_id,
  type, params, anchor_id, anchor_bone,
  started_at, mana_per_tick,
}
```

引擎统一在 caster 死亡 / 离线 / 进反魔法区时清理其所有 active_effects。

## 3. Implementation

**已 landed**：

| 路径 | 内容 |
|---|---|
| `src/sim/substance.gd` | `Substance` Resource 类，10 个物理字段 |
| `src/sim/substances.gd` | `Substances.by_id("flesh")` 静态查表 |
| `src/sim/substances/{wood,stone,metal,flesh,water,cloth,glass,crystal}.tres` | 8 种基础材质 |
| `src/characters/character.gd` | `Character extends CharacterBody3D`：物理 + hp/stamina/statuses/equipped |
| `src/characters/npcs/npc.gd` | `NPC extends Character`，自动继承所有字段 |

**字段策略**：
- runtime 状态用 `var`（每实例独立，不放 Resource——`.tres` 跨实例共享）
- 编辑器配置用 `@export`
- override 字段策略：每出现一次"想偏离 substance 默认"的需求才加一个 override 字段（YAGNI）。当前只放 `ignition_point_override` 一个证明模式可行
- `equipped` 当前是 `Dictionary` slot_name → item_id (String)；Item 类还没建，等 inventory session 接

**未实现**：
- Wand class（待 spell 系统起来）
- Item base class（另一个 session 在做）
- active_statuses 过期 tick
- 持久 active_effects（待第一个光球类法术）
- body_temperature 自我维持
- Inventory storage / 装备生效逻辑

## 4. Open questions

- **Strict / degenerate / mixed 魔杖**：没杖能不能施法？倾向 strict
- **Stamina 耗尽行为**：只是不能行动 vs 昏倒 vs 扣 hp？倾向 "exhausted" status + 强制冷却
- **Body temperature 是否做**：倾向 MVP 不做，只做"被点燃"
- **学派切分**：8-12 个学派的具体名字与覆盖范围（影响 `Wand.affinity` key 和 `Reaction.school`，见 [combat-system §4.4](./combat-system.md#44-reaction-的战斗扩展复用-schema--一个新字段)）
- **死亡掉落规则**（[design-doc §6 / §11](../design-doc.md)）：影响 `equipped` 在死亡时的处理
