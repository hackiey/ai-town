# Player Stats

> Status: **drafting v1** — 玩家数值系统设计稿，尚无对应代码。
> 本文配套 [reaction-schema.md](./reaction-schema.md) 和 [100-item-experiment.md](./100-item-experiment.md)，定义玩家 stats、衍生量、自然衰减、行为消耗、食物 / buff 效果。
> 服务于"低魔 / 神秘"风格的中世纪 AI 驱动 sim：饱食 / 睡眠 / 体力是核心循环，魔法是稀有外挂。

---

## 1. Stats（5 个基础 + 2 个衍生）

| stat | 范围 | 初始 | 主要作用 |
|---|---|---|---|
| **hp** | 0-100 | 100 | 归零死亡 |
| **stamina** | 0-100 | 100 | 行为消耗、移动、力量；上限受 hunger / rest 影响 |
| **hunger**（饱食度） | 0-100 | 100 | 自然衰减；归零开始扣 hp |
| **rest**（精力） | 0-100 | 100 | 自然衰减；通过睡觉恢复 |
| movement_speed_factor（衍生） | 0.3-1.0 倍率 | 1.0 | 由 stamina 推导 |
| strength_factor（衍生） | 0.5-1.0 倍率 | 1.0 | 由 stamina 推导 |

**不要 mana**——魔法能量在魔杖里（魔杖能量系统由魔法批 schema 单独定）。

---

## 2. 自然衰减

按游戏时间走（当前默认 7×）。

| 量 | 速率 | 触发条件 | 注释 |
|---|---|---|---|
| hunger | -0.035 / 游戏分钟 | 醒着、睡觉都掉 | 100 → 0 共 2 游戏天 |
| rest | -0.035 / 游戏分钟 | **只在醒着时掉** | 100 → 0 共 2 游戏天清醒 |
| hp | **-0.07 / 游戏分钟** | hunger == 0 触发 | 100 → 0 共 1 游戏天饿死 |

---

## 3. 恢复

### Stamina（自然恢复，不依赖动作）

**Stamina 上限是动态的**：`stamina_cap = min(hunger, rest)`

- 满血（hunger=100, rest=100）→ stamina 上限 100
- 一天没吃（hunger≈50, rest=80）→ stamina 上限 **50**
- 通宵（hunger=80, rest=20）→ stamina 上限 **20**

**Stamina 恢复速度**：`stamina_regen = 1.0 × (hunger/100) × (rest/100)` per 游戏分钟

| 状态 | 上限 | 恢复速度 |
|---|---|---|
| 满血 | 100 | +1.0 /min |
| 饱 80 / 精力 100 | 80 | +0.8 /min |
| 饱 50 / 精力 100 | 50 | +0.5 /min |
| 饱 50 / 精力 50 | 50 | +0.25 /min |
| 饱 20 / 精力 20 | 20 | +0.04 /min |

### Hunger（吃东西）

吃食物按 Material.use_effects 加 hunger（详见 §6 食物表）。

### Rest（睡觉）

| 场所 | 恢复速度 | 8 游戏小时回满 |
|---|---|---|
| 床上 | **+0.21 / 游戏分钟** | 是（480 game min × 0.21 ≈ 100）|
| 野外 / 不舒服环境 | **+0.105 / 游戏分钟** | 否，需要 16 游戏小时 |

睡觉时 hunger 仍然 -0.035/min（睡着也消耗）。
玩家可以选醒来时间或被打扰唤醒（事件机制后定）。

---

## 4. Stamina 对衍生量的影响

### 移动速度

`movement_speed_factor = clamp(0.3 + 0.014 × stamina, 0.3, 1.0)`

| stamina | 倍率 | 体感 |
|---|---|---|
| 100 | 1.0 | 正常步行 |
| 50 | 1.0 | 仍然满速 |
| 30 | 0.72 | 明显变慢 |
| 0 | 0.30 | 蹒跚 |

### 力量（武器伤害 / 搬运 / 干活效率）

`strength_factor = clamp(0.5 + 0.005 × stamina, 0.5, 1.0)`

| stamina | 倍率 | 体感 |
|---|---|---|
| 100 | 1.0 | 满力 |
| 50 | 0.75 | 7 分力 |
| 0 | 0.50 | 半力（疲软）|

兜底 50% 是为了防止 stamina=0 完全躺尸。

---

## 5. 行为消耗 stamina

| 行为 | 消耗 |
|---|---|
| 战斗（一击）| -2 |
| 挖矿一次尝试 | -10 |
| 砍树一次 | -3 |
| 制造（reaction）| 各 reaction 自带 stamina_cost（见 reaction-schema.md §7.1）|
| **奔跑（未实现）**| 预留 -0.5 / 游戏分钟 |
| **施法**| 主消耗在魔杖能量上，stamina 消耗待魔法批定 |

## 5b. 工具 / 武器耐久消耗

**规则极简**：每次使用 → durability -1。

`max_durability` 按主材质分级：

| 主材质 | max_durability | 说明 |
|---|---|---|
| wood | 50 | 木剑 / 木锤 / 木棒，廉价 |
| bone | 80 | 骨刃 / 骨锥，原始猎人级 |
| stone | 80 | 石斧 / 燧石，原始 |
| bronze | 150 | 中世纪早期主流 |
| iron | 200 | 中世纪标准 |
| silver | 200 | 数值同铁，魔法属性强（魔法批用）|
| steel | 250 | 后期 / 大师级（暂留）|

**实现细节**：
- 物品创建时 `durability = max_durability` = `Materials.by_id(item.materials.body).max_durability`（material 上加新字段）
- 使用 handler 每次 -1 durability
- durability ≤ 0 → 加 broken tag（详见 [reaction-schema.md §7.4](./reaction-schema.md#74-耐久度--破损v3-新增)）

**未来扩展**（YAGNI）：
- 不同动作不同损耗（砍石头 -3、砍木 -1）
- 工具种类影响（knife vs sword 不同基础值）
- 品质 quality 影响 max_durability（极品剑 +20%）

---

## 6. 食物效果表

挂在 Material 上（reaction-schema.md §10.1）：

```gdscript
# data/materials/bread.tres
edible = true
use_effects = [
    {"stat": "hunger", "delta": 30},
]
```

| 食物 | hunger | instant stamina | buff |
|---|---|---|---|
| bread（基础粮）| 30 | 0 | — |
| cooked_meat（家常）| 40 | 5 | — |
| cooked_fish | 30 | 5 | — |
| veg_soup（清汤）| 20 | 0 | — |
| veg_stew（浓炖）| 40 | 0 | well_fed 30min |
| omelet（豪华早餐）| 35 | 10 | well_fed 30min |
| cheese | 25 | 5 | — |
| butter（辅料）| 10 | 0 | — |
| sour_milk | 15 | 0 | — |
| salted_meat（保鲜）| 35 | 5 | — |
| beer | 5 | 5 | drunk 30min |

**逻辑**：吃饭主要垫 hunger，让接下来 stamina 回得快；少数高蛋白食物给小量 instant stamina 当应急。

---

## 7. Buff / Debuff schema

```gdscript
# data/buffs/well_fed.tres
class_name Buff
extends Resource

@export var id: String = "well_fed"
@export var display_name: String = "饱足"
@export var icon: Texture2D
@export var description: String = "刚吃过大餐，体力恢复加快"

# 修饰器（应用在玩家衍生量上）
@export var modifiers: Array = [
    # {"stat": "stamina_regen", "factor": 1.5},
]

@export var stacks: bool = false   # 重复获得是叠加还是刷新
@export var duration_minutes_default: float = 30.0
```

```gdscript
# Material.use_effects 里挂 buff：
use_effects = [
    {"stat": "hunger", "delta": 40},
    {"buff": "well_fed", "duration_minutes": 30},
]
```

### 已定的 buffs

| buff | modifiers | 来源 |
|---|---|---|
| well_fed | stamina_regen ×1.5 | 大餐（stew, omelet）|
| drunk | movement_speed ×0.7、attack_accuracy -20、social_npc +好感 | beer |
| regen | hp +5 / 游戏分钟 | 治疗药水（魔法批）|
| poisoned | hp -3 / 游戏分钟 | 毒刃、坏食物 |

---

## 8. 关键场景验证

**场景 1：一天没吃饭，晚上**
- hunger ≈ 100 - 0.035 × 1440 = 50
- rest ≈ 50（如果一直没睡）或 80（中途休息过）
- stamina_cap = 50
- 砍树（-3 stamina）：能砍 ~16 次后接近耗尽，回血慢，效率低
- ✅ 符合"饿了就没劲"

**场景 2：通宵打怪**
- hunger 80（中途吃过）、rest 20（一直醒着 22 游戏小时）
- stamina_cap = 20
- 战斗一击 -2 → 能打 10 次，回血几乎为零
- 走路 30%-50% 速度
- ✅ 符合"困了就废"

**场景 3：饿死**
- hunger = 0 → hp -0.07/min
- 100 hp → ~24 游戏小时
- 真实约 3.4 小时（按 7× 计算），玩家有充足时间反应
- ✅ 符合用户"至少一天才饿死"的要求

---

## 9. Open Questions

- **buff 叠加规则**：multiple "well_fed" 同时获得是刷新时间还是叠加 modifier？默认刷新，可在 buff.tres 里 override？
- **rest 减半的"野外"具体怎么判定**：靠地点 tag（"shelter"）？靠是否有 bedroll？暂留模糊，UI 实现时定。
- **打扰睡眠**：NPC / 怪物来访时唤醒？
- **疾病系统**：rest 持续低 / hunger 持续低 → 生病？后续 progression 设计
- **强壮 / 虚弱永久状态**：长期养身体 vs 长期透支会不会改变 base 数值？YAGNI？
- **NPC 是否走同一套**：NPC 也吃饭睡觉？schema 一样？需要在 two-track-agent-session.md / NPC 行为侧确认

---

## 修订记录

- 2026-05-08 (v1)：初版。5 stats（hp / stamina / hunger / rest / 衍生 movement+strength），动态 stamina_cap = min(hunger, rest)，吃饭睡觉恢复，buff schema 配套，食物效果表。删除 mana（魔法走魔杖能量，待魔法批定）。
