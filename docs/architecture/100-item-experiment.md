# 100 物品反应实验

> Status: **drafting** — 用具体 item 验证 [reaction-schema.md](./reaction-schema.md) 是否够用。
> 第一批 15 件制造反应（本文）。后续按 30 / 50 / 100 三批续写。
> **范围限定**：只考虑"制造"——把 inventory 已有材料转化 / 加工 / 组装。采集机制（砍树 / 挖矿 / 种植 / 收割）不属于本 schema。
> 发现的 schema 缺口在 §6 汇总，确认后回头改 reaction-schema.md。

## 0. Method

每件 item 一个 block：
- **反应**：相关的 reaction(s) 伪 .tres（材质 / 形状 / 部件用 base-items.md 命名）
- ⚠ **缺口**：reaction-schema 当前不支持的字段、模式、verb 策略

不写已经在 reaction-schema.md §11 MVP YAGNI 列表里的（catalyst、显式 priority 等）。

原料（wood / iron_ore / charcoal / wheat / fiber / water）当作 inventory 里天生有的物品，不走反应。

---

## 1. 原料

**不在本文 / 本 schema 范围**。砍树、挖矿、种植、收割都属于"采集机制"，是另一套系统。本文假设：

- `wood`, `iron_ore`, `charcoal`, `wheat`, `fiber`, `water` 等原料**天生就在 inventory 里**（玩家自采或从 NPC 商人买，不走 reaction 表）
- 它们作为 item 模板存在（`data/items/*.tres`），含 `shape_type` + `materials.body` + tags
- 其他反应可以引用它们作为 input

下面 §2 起的反应都是**纯制造**——把 inventory 里已有的材料组装、转化、加工成新物品。

---

## 2. 中间件（10 件）

### 2.1 iron_ingot（熔炼）

```gdscript
# data/reactions/smelt_iron.tres
verb = "smelt"
workstation = "forge"
trigger = "active"
duration_seconds = 60.0
stamina_cost = 5.0       # 大头是燃料和等待，不是体力
difficulty = 0.2

inputs = [
    {"shape_type": "ore_chunk", "materials.body": "iron_ore", "quality_weight": 0.8},
    {"materials.body": "charcoal", "quality_weight": 0.2},   # 燃料
]

outputs = [
    {
        # smelt verb material_strategy = "transform"
        # → 取 input[0].materials.body = iron_ore
        # → Materials.by_id("iron_ore").transforms["smelt"] = "iron"
        # → 输出 materials.body = "iron"
        "generate": {
            "shape_type": "ingot",
            "qty": 1,
        }
    },
    # 副产物：矿渣
    {
        "generate": {
            "shape_type": "slag_lump",
            "materials": {"body": "iron_slag"},
            "qty": 1,
        }
    },
]

failure_modes = [
    {"name": "火候不足", "weight": 0.7, "consume_parts": ["body"], "return_parts": [],
     "message": "炉温不够，矿没熔开"},
    {"name": "渣多", "weight": 0.3, "consume_parts": ["body"], "return_parts": [],
     "message": "全是渣，没出铁"},
]
```

⚠ **缺口 7**：transform verb 的 input 是单材质，但这条用了 2 个 input（矿 + 燃料）。`material_strategy = "transform"` 怎么知道"主材料是 input[0]"？需要 verb 上加 `transform_input_index: int = 0` 字段
⚠ **缺口 8**：副产物 `iron_slag` 也是涌现物品（无模板）。它的 shape_type / display_name / 用途从哪定？建议：副产物允许显式指定 materials（不走 transform 推导）
⚠ **缺口 9**：failure_modes 的 `consume_parts: ["body"]` 引用谁的 part？两个 input 都有 body。需要明确语法：`consume_parts: ["@input[0].body", "@input[1].body"]` 或 `consume_inputs: [0, 1]`

### 2.2 加热铁锭（modify）

```gdscript
# data/reactions/heat_iron_ingot.tres
verb = "heat"
workstation = "forge"
trigger = "active"
duration_seconds = 120.0
stamina_cost = 3.0
difficulty = 0.0

inputs = [
    {"shape_type": "ingot", "materials.body": "iron"},
    {"materials.body": "charcoal"},   # 燃料
]

outputs = [
    {
        "modify": "@input[0]",
        "set_properties": {"temperature": 1000},
        "add_tags": ["hot"],
    },
    # input[1] (charcoal) 默认消耗
]
```

✅ 完全在 schema 内（modify 模式）。

### 2.3 冷却（passive）

```gdscript
# data/reactions/passive_cool.tres
verb = "passive_cool"
trigger = "passive"
tick_interval = 1.0

inputs = [
    {"properties.temperature": ">25"},
]

outputs = [
    {
        "modify": "@input[0]",
        "delta_properties": {"temperature": -10},
    }
]
```

⚠ **缺口 10**：温度降到环境温度时停。`delta_properties: {"temperature": -10}` 会一直降到负值。需要 `clamp` 配置：
```gdscript
"delta_properties": {"temperature": -10},
"clamp_properties": {"temperature": [25, 9999]},  # 至少 25，最多 9999
```

⚠ **缺口 11**：when 这条 passive 在 forge 范围内不触发？schema §11 已经把"环境前提"放 YAGNI。这意味着烧红的铁块在 forge 里也会冷——不真实但 MVP 可接受

### 2.4 iron_blade（锻打）

```gdscript
# data/reactions/forge_blade.tres
verb = "hammer"
workstation = "anvil"
trigger = "active"
duration_seconds = 30.0
stamina_cost = 12.0
difficulty = 0.4

inputs = [
    {                                          # 烧红的铁锭
        "shape_type": "ingot",
        "materials.body": "iron",
        "properties.temperature": ">800",
        "quality_weight": 1.0,
    },
    {                                          # 手持锤
        "held": true,
        "tags_any": ["hammer"],
        "properties.weight": ">=2.0",
    },
]

outputs = [
    {
        "generate": {
            "shape_type": "flat_blade",
            "parts_map": {"body": "@input[0]"},   # 单部件物品
            "tags": ["sharp", "metal"],
            "properties": {"edge_sharpness": 50, "temperature": 600},  # 仍是热的
            "qty": 1,
        }
    }
]

failure_modes = [
    {"name": "打弯", "weight": 0.7,
     "consume_parts": ["@input[0]"], "return_parts": [],
     "message": "铁打弯了，废了"},
    {"name": "炸火", "weight": 0.3,
     "consume_parts": ["@input[0]"], "return_parts": [],
     "message": "温度过高崩裂"},
]
```

⚠ **缺口 12**：generate 时给新物品的 properties 写死 `temperature: 600`——但应该从 `@input[0].temperature` 继承（甚至 -100 表示锻打过程降温）。需要支持 `properties: {"temperature": "@input[0].temperature - 100"}` 表达式

### 2.5-2.6 iron_axe_head / iron_pick_head

跟 2.4 同结构，只是 `outputs.generate.shape_type` 不同（`axe_head` / `pick_head`）。

⚠ **缺口 13**：3 条 reaction 几乎一样，只差 shape_type。需要"模具"概念吗？
- 方案 A：3 条独立 .tres（当前 schema 支持）
- 方案 B：模具作为 input，shape_type 从模具读

我倾向 A——schema 简单，3 条 .tres 写起来也不贵。base-items.md 的"mold 是 dropdown"可以转译为"3 条 reaction，UI 让玩家选哪条触发"。

### 2.7 wood_shaft（雕刻）

```gdscript
# data/reactions/carve_shaft.tres
verb = "carve"
workstation = "workbench"
trigger = "active"
duration_seconds = 15.0
stamina_cost = 4.0
difficulty = 0.2

inputs = [
    {"shape_type": "log", "materials.body.category": "wood"},
    {"held": true, "tags_any": ["knife"], "properties.edge_sharpness": ">=30"},
]

outputs = [
    {
        "generate": {
            "shape_type": "shaft",
            "parts_map": {"body": "@input[0]"},
            "tags": ["wood_part"],
            "qty": 2,                          # 一根 log 出 2 根 shaft
        }
    }
]
```

⚠ **缺口 14**：同 2.5（多形状靠多 reaction，OK）

### 2.8 wood_plank

跟 2.7 同，只差 shape_type = `plank`。

### 2.9 flour（磨）

```gdscript
# data/reactions/grind_wheat.tres
verb = "grind"
workstation = "mill"
trigger = "active"
duration_seconds = 20.0
stamina_cost = 1.0   # 磨坊省力
difficulty = 0.0

inputs = [
    {"shape_type": "grain_bundle", "materials.body": "wheat"},
]

outputs = [
    {
        # grind verb material_strategy = "transform"
        # wheat.transforms["grind"] = "flour"
        "generate": {
            "shape_type": "powder",
            "qty": 3,                          # 1 束麦 → 3 份面粉
        }
    }
]
```

✅ schema 内，但同 2.1 缺口 7（transform 单 input 简单 case，能跑）

### 2.10 rope（拧麻绳）

```gdscript
# data/reactions/twist_rope.tres
verb = "combine"
workstation = "workbench"
trigger = "active"
duration_seconds = 5.0
stamina_cost = 3.0
difficulty = 0.1

inputs = [
    {"shape_type": "fiber_bundle", "materials.body.category": "fiber", "quality_weight": 1.0},
    {"shape_type": "fiber_bundle", "materials.body.category": "fiber", "quality_weight": 1.0},
    {"shape_type": "fiber_bundle", "materials.body.category": "fiber", "quality_weight": 1.0},
]

outputs = [
    {
        "generate": {
            "shape_type": "cord",
            "parts_map": {
                "body": "@input[0]",            # 3 根都是同种纤维，取第一根的材质
            },
            "tags": ["binding", "flexible"],
            "qty": 1,
        }
    }
]
```

⚠ **缺口 15**：3 个 input 是同种东西。匹配引擎要支持"同一条 input 描述匹配多个槽位"还是"必须写 3 条相同的 input dict"？schema 当前是后者（每个 input dict 一个槽）。OK 但啰嗦。可以加 `repeat: 3` 简写：
```gdscript
inputs = [
    {"shape_type": "fiber_bundle", "...": "...", "repeat": 3}
]
```

⚠ **缺口 16**：3 根纤维如果种类不同（hemp + flax + cotton）怎么决定输出 body？目前 parts_map 写死 `@input[0]`，意味着"绳的材质 = 第一根纤维的"。听起来不对，更合理是"按数量加权"或"取主要的"。这是 verb-strategy 的边缘 case，先不管，记一下

### 2.11 dough（面团）

```gdscript
# data/reactions/mix_dough.tres
verb = "combine"
workstation = "workbench"
trigger = "active"
duration_seconds = 10.0
stamina_cost = 4.0
difficulty = 0.1

inputs = [
    {"shape_type": "powder", "materials.body": "flour", "quality_weight": 0.7},
    {"shape_type": "liquid", "materials.body": "water", "quality_weight": 0.3},
]

outputs = [
    {
        "generate": {
            "shape_type": "dough_lump",
            # 面团是新物质——既不是 flour 也不是 water
            "parts_map": {"body": "@new_material('dough')"},   # ⚠ 缺口
            "tags": ["food_intermediate"],
            "qty": 1,
        }
    }
]
```

⚠ **缺口 17（大）**：combine verb 的 material_strategy 是 compose（按 parts_map 把每个输入装成部件）。但面团**不是组装**——它是新材质。强行写 `parts_map: {flour: ..., water: ...}` 不对：吃面团时应该看到的是"面团"这个新材质，不是"含水的面粉"。

需要新 strategy：**`merge` / `mix`** —— 多输入合成一个新材质（但不是 alloy 那种"两金属冶炼"，而是"面粉 + 水 = 面团"这种食材合成）。

可能 schema 加：
```gdscript
# data/verbs/combine.tres
material_strategy = "compose"   # 默认装配

# 但允许 reaction override：
# data/reactions/mix_dough.tres
material_strategy_override = "mix"
mix_result_material = "dough"   # 显式指定输出材质
```

或者 dough 这种应该走专门的 verb（`mix`）？分两个 verb：`combine`（装配，材质组成）+ `mix`（混合，材质合成）。倾向后者，更清楚。

---

## 3. 成品（5 件）

### 3.1 iron_shovel

```gdscript
# data/reactions/assemble_shovel.tres
verb = "combine"
workstation = "workbench"
trigger = "active"
duration_seconds = 8.0
stamina_cost = 6.0
difficulty = 0.3

inputs = [
    {"shape_type": "flat_blade", "materials.body.category": "metal", "quality_weight": 0.6},
    {"shape_type": "shaft",      "materials.body.category": "wood",  "quality_weight": 0.3},
    {"shape_type": "cord",       "tags": ["binding"],                "quality_weight": 0.1},
]

outputs = [
    {
        "generate": {
            "shape_type": "flat_blade_on_shaft",
            "parts_map": {
                "head":    "@input[0]",
                "shaft":   "@input[1]",
                "binding": "@input[2]",
            },
            "tags": ["tool", "dig"],
            "properties": {"durability": 100},
            "qty": 1,
        }
    }
]

failure_modes = [
    {"name": "绳松", "weight": 0.6, "consume_parts": ["binding"], "return_parts": ["head", "shaft"],
     "message": "绳子绑歪了，木柄滑出来"},
    {"name": "刃裂", "weight": 0.3, "consume_parts": ["head"], "return_parts": ["shaft", "binding"],
     "message": "铁刃装配时崩了角"},
    {"name": "全废", "weight": 0.1, "consume_parts": ["head", "shaft", "binding"], "return_parts": [],
     "message": "整把都散架了"},
]
```

✅ 这是 schema 的"happy path"完整 case，所有字段都用上了。

### 3.2-3.3 iron_axe / iron_pick

跟 3.1 同结构，只差：
- inputs[0].shape_type → `axe_head` / `pick_head`
- outputs.generate.shape_type → `axe_head_on_shaft` / `pick_head_on_shaft`
- outputs.generate.tags → `["tool", "chop"]` / `["tool", "mine"]`

⚠ **缺口 18**：tags 是按 reaction 写死的，但其实 tags 应该跟 shape 走（`axe_head_on_shaft.tags = ["tool", "chop"]` 在 Shape 注册里）。schema §9.3 Shape 定义里加 `default_tags: PackedStringArray`，generate 时自动并入

### 3.4 iron_knife（小铁刃，无 binding）

```gdscript
# data/reactions/assemble_knife.tres
verb = "combine"
workstation = "workbench"
duration_seconds = 5.0
stamina_cost = 4.0
difficulty = 0.25

inputs = [
    {"shape_type": "flat_blade", "materials.body.category": "metal", "quality_weight": 0.7},
    {"shape_type": "shaft",      "materials.body.category": "wood",  "quality_weight": 0.3,
     "properties.length": "<=0.4"},   # 短柄
]

outputs = [
    {
        "generate": {
            "shape_type": "knife",
            "parts_map": {"head": "@input[0]", "shaft": "@input[1]"},
            "tags": ["tool", "weapon", "cut"],
            "properties": {"durability": 80, "edge_sharpness": "@input[0].properties.edge_sharpness"},
            "qty": 1,
        }
    }
]
```

⚠ **缺口 19**：iron_knife 和 base-items.md 里的 sickle 输入相同（铁刃 + 木柄），靠 `length <= 0.4` 区分？听起来不靠谱。base-items.md 当时建议加 mold 参数。我现在的提案是：
- 短柄 / 长柄 是 wood_shaft 的 properties.length，玩家雕刻时选
- knife / sickle 反应靠 shaft 长度 + reaction.constraint_count 自动选最匹配的（约束多的赢）

但实际玩家可能有"我就想用这根长柄做 knife"——这种 case 应该 UI 上让玩家选 reaction，不是 dispatcher 自动决定。schema 不变，但**UI 层需要支持"多匹配时让玩家选"**。

⚠ **缺口 20**：`"@input[0].properties.edge_sharpness"` —— 输出物属性从输入实例读。这是个表达式，schema §5.1 没细说支持的表达式语法。需要列出：
- `@input[i]` —— 取整个 input
- `@input[i].materials.<part>` —— 取材质
- `@input[i].properties.<key>` —— 取属性
- 算术？`@input[0].weight + @input[1].weight`（同 2.4 缺口 12）

### 3.5 bread

```gdscript
# data/reactions/bake_bread.tres
verb = "bake"
workstation = "stove"
trigger = "active"
duration_seconds = 90.0
stamina_cost = 2.0
difficulty = 0.2

inputs = [
    {"shape_type": "dough_lump", "materials.body": "dough"},
]

outputs = [
    {
        # bake verb material_strategy = "transform"
        # dough.transforms["bake"] = "bread"
        "generate": {
            "shape_type": "loaf",
            "tags": ["food", "edible"],
            "properties": {
                "hunger_restore": 30,
                "stamina_restore": 5,
            },
            "qty": 1,
        }
    }
]

failure_modes = [
    {"name": "烤焦", "weight": 0.8, "consume_parts": ["@input[0]"], "return_parts": [],
     "message": "烤糊了"},
    {"name": "夹生", "weight": 0.2, "consume_parts": [], "return_parts": ["@input[0]"],
     "message": "没烤熟，可以再来一次"},
]
```

⚠ **缺口 21**：失败时退回 `@input[0]`（半成品）—— "夹生"模式不消耗，可以重试。这种"失败但材料完好"的 mode 已经在 schema 内（`consume_parts: []` + `return_parts: ["@input[0]"]`），✅
⚠ **缺口 22**：`hunger_restore` 这种"使用效果属性"是 properties 字段。但"使用效果"逻辑（吃了 hunger +30）写在哪？item.gd 的 use 行为？还是另一套 effect schema？这是另一个 layer，超出 reaction-schema 范围，但要在 docs 里有标注

---

## 4. 验证矩阵

第 1 批 15 件覆盖了哪些 schema 字段：

| schema 特性 | 用到的 item |
|---|---|
| compose strategy | shovel/axe/pick/knife (3.1-3.4)|
| transform strategy | iron_ingot (2.1), flour (2.9), bread (3.5) |
| modify strategy | heat ingot (2.2), passive cool (2.3) |
| alloy strategy | （无，第 2 批补 bronze）|
| mix strategy | dough (2.11) ⚠ 暴露需求 |
| weighted_avg quality | shovel (3.1) etc |
| 多产物 | smelt (2.1，铁 + 矿渣)|
| 失败模式 | smelt, blade, shovel, knife, bread |
| passive trigger | cool (2.3) |
| 数值约束 | temperature > 800, sharpness >= 30 |
| tags 匹配 | rope (binding), shovel (binding) |
| qty > 1 输出 | shaft (2), flour (3) |
| 实例属性继承 | knife (sharpness from blade) |

**没用到的（待第 2 批 / 第 3 批）**：

- alloy strategy（bronze, brass）
- mix strategy（dough 已暴露需求；soup, mortar）
- environment input（季节、邻近实体）
- catalyst（mold, crucible）—— 已在 YAGNI，但第 3 批专门压测

---

## 5. 第 2 批普通完成（15 件 + 维修系统）

> Status: **drafting** — 与用户一对一过完 1-15。本节标的缺口编号沿用第 1 批（24 起），合并到 §6。

### 5.1 raw_meat（butcher livestock_carcass）

```gdscript
verb = "butcher"
workstation = "butcher_block"
trigger = "active"
duration_seconds = 60.0
stamina_cost = 15.0
inputs = [
    {"shape_type": "carcass", "materials.body.category": "livestock"},
    {"held": true, "tags_any": ["knife", "cleaver"], "properties.edge_sharpness": ">=20"},
]
outputs = [
    {"generate": {"shape_type": "meat_chunk", "materials.body": "@input[0].materials.body",
                  "tags": ["food_raw", "meat"], "qty": "@input[0].properties.meat_yield"}},
    {"generate": {"shape_type": "raw_hide", "materials.body": "@input[0].materials.body",
                  "qty": "@input[0].properties.hide_yield"}},
    {"generate": {"shape_type": "bone", "materials.body": "bone",
                  "qty": "@input[0].properties.bone_yield"}},
]
```

牛 carcass instance 自带 `{meat_yield: 6, hide_yield: 1, bone_yield: 4}`，鸡 `{meat_yield: 1, hide_yield: 0, bone_yield: 1}`。一条 reaction 覆盖所有 livestock。

⚠ **缺口 23**：`qty` 字段允许表达式（之前 §4.5b 只列 properties）。统一规则：generate 内任何字段都允许 @input 表达式
⚠ **小行为**：qty=0 时 dispatcher 跳过该 generate 条目（鸡没皮）

### 5.2 cooked_fish（fry）

✅ **不用新写 reaction**——复用 batch 1 `fry_food`，输入改 `tags_any: ["food_raw"]`，输出 `shape_type: "@input[0].shape_type"`。新 Material `raw_fish` 加 `transforms.fry = cooked_fish`。

⚠ **缺口 24**：generate.shape_type 也支持 @input 表达式（同上统一规则）

### 5.3 omelet（fry，多输入 mix）

```gdscript
verb = "fry"
workstation = "stove"
material_strategy = "mix"
mix_result_material = "omelet"
inputs = [
    {"materials.body": "egg", "repeat": 2},
    {"tags_any": ["vegetable", "meat", "cheese"], "repeat": 1},     # 至少 1 辅料
]
```

不引入"可选 input"概念；纯蛋煎蛋走 §5.2 fry_food。

### 5.4 veg_soup（boil at stove，新 verb）

```gdscript
verb = "boil"
workstation = "stove"
duration_seconds = 30.0
material_strategy = "mix"
mix_result_material = "veg_soup"
inputs = [
    {"tags_any": ["vegetable"], "repeat": 2},
    {"materials.body": "water"},
]
```

跟 batch 1 #19 veg_stew 区分：soup = 蔬菜 + 水（短煮）；stew = 蔬菜 + 肉/骨（长炖）。两条独立 reaction。

### 5.5 cheese（passive，容器模式）

**关键设计决策**：木桶 / 大缸 = 容器（打 `aging_vessel` tag），存入 / 取出是 **inventory action**（不是 reaction）。passive 反应自动检测容器内的实例，按时间推进。

奶 → 酸奶 → 奶酪两阶段（分两条 passive transform）：

```gdscript
# stage 1: 12 游戏小时
verb = "ferment"
trigger = "passive"
duration_required = 720.0
material_strategy = "transform"
inputs = [{"materials.body": "milk", "@inside_container_tags": ["aging_vessel"]}]
outputs = [{"generate": {"shape_type": "@input[0].shape_type",
                          "materials.body": "sour_milk", "qty": 1}}]
```

stage 2 同结构，sour_milk → cheese，再 12 小时。中途取出 = 当前阶段的东西（酸奶本身就是有用食物）。

⚠ **缺口 27**：input 支持 `@inside_container_tags` 匹配
⚠ **缺口 28**：passive reaction 加 `duration_required` 字段（累计 N 游戏分钟后触发）
⚠ **缺口 30**：dispatcher 维护"input 实例已在容器停留多久"的计时器（不存到 instance properties）

### 5.6 butter（churn milk）

```gdscript
verb = "churn"
workstation = "butter_churn"
duration_seconds = 90.0
stamina_cost = 12.0
material_strategy = "transform"
inputs = [{"materials.body": "milk"}]
outputs = [{"generate": {"shape_type": "butter_block", "qty": 1}}]
```

milk.transforms.churn = "butter"。简化为奶 → 黄油（不经奶油），无 buttermilk 副产物。

### 5.7 salted_meat（passive 容器，多输入）

```gdscript
verb = "cure"
trigger = "passive"
duration_required = 4320.0    # 3 游戏天
material_strategy = "transform"
inputs = [
    {"materials.body": "raw_meat", "@inside_container_tags": ["aging_vessel"]},
    {"materials.body": "salt",     "@inside_container_tags": ["aging_vessel"]},
]
outputs = [{"generate": {"shape_type": "meat_chunk", "materials.body": "salted_meat", "qty": 1}}]
```

⚠ **缺口 29**：多输入 passive 的成对匹配 + 中途取走的行为约定：
- 必须**同一容器**才匹配
- 1 块肉配 1 份盐成对消耗
- 中途取走任意 input → 反应停止计时（不再匹配）
- 重新放回 → **从头开始**（不存进度，简化）

### 5.8 啤酒链（4 层，破例）

#### 5.8a germinate（passive）
```gdscript
trigger = "passive"
duration_required = 1440.0    # 24 游戏小时
inputs = [{"materials.body": "wheat", "@inside_container_tags": ["aging_vessel"]}]
outputs = [{"generate": {"shape_type": "@input[0].shape_type", "materials.body": "malt", "qty": 1}}]
```

#### 5.8b mash（active boil）
```gdscript
verb = "boil"
workstation = "stove"
material_strategy = "mix"
mix_result_material = "wort"
inputs = [
    {"materials.body": "malt"}, {"materials.body": "water"}, {"materials.body": "hops"},
]
```

#### 5.8c ferment（passive）
```gdscript
verb = "ferment"
trigger = "passive"
duration_required = 4320.0    # 3 游戏天
material_strategy = "transform"
inputs = [
    {"materials.body": "wort",  "@inside_container_tags": ["aging_vessel"]},
    {"materials.body": "yeast", "@inside_container_tags": ["aging_vessel"]},
]
outputs = [{"generate": {"shape_type": "liquid_pot", "materials.body": "beer", "qty": 1}}]
```

新原料 hops（草药）/ yeast（炼金）两者也将是魔法批草药 / 药水的关键成分。yeast 按份消耗（不做催化剂语义）。

### 5.9-5.10 bronze_blade / bronze_axe_head

✅ **不用新写 reaction**——把 batch 1 `forge_blade` / `forge_axe_head` 的 `materials.body: "iron"` 改成 `materials.body.category: "metal"`。青铜锭烧红打 → bronze_blade，未来银锭烧红打 → silver_blade，全部覆盖。

### 5.11 破损 + 维修系统

**核心规则（不是 reaction，是使用代码）**：耐久 0 → 加 `broken` tag，物品留在 inventory，使用代码检查 `broken` 阻止使用。

#### 5.11a 重锻（reforge，金属物品）

```gdscript
verb = "hammer"
workstation = "anvil"
duration_seconds = 60.0
stamina_cost = 15.0
difficulty = 0.4
material_strategy = "modify"
inputs = [
    {"tags_any": ["broken"], "materials.body.category": "metal",
     "properties.max_durability": ">30"},
    {"held": true, "tags_any": ["hammer"]},
    {"shape_type": "ingot", "materials.body": "@input[0].materials.body"},
]
outputs = [{
    "modify": "@input[0]",
    "delta_properties": {"max_durability": -30},
    "set_properties": {"durability": "@input[0].properties.max_durability - 30"},
    "remove_tags": ["broken"],
}]
```

每次重锻 max -30，三次后只能拆解。失败由熟练度系统自动管。

#### 5.11b 野外应急 + 修理包

修理反应（一条覆盖所有材质）：

```gdscript
verb = "repair"
workstation = ""              # 不需要工作站
duration_seconds = 10.0
stamina_cost = 3.0
material_strategy = "modify"
inputs = [
    {"tags_any": ["weapon", "tool", "armor"], "tags_none": ["broken"]},
    {"shape_type": "repair_kit",
     "properties.target_category": "@input[0].materials.body.category"},
]
outputs = [{"modify": "@input[0]", "delta_properties": {"durability": 15}}]
```

修理包配方（一条覆盖所有种类）：

```gdscript
verb = "combine"
workstation = "workbench"
inputs = [
    {"tags_any": ["binding"]},
    {"shape_type_any": ["ingot", "leather_strap", "plank"]},
]
outputs = [{"generate": {"shape_type": "repair_kit",
            "properties": {"target_category": "@input[1].materials.body.category"},
            "qty": 1}}]
```

⚠ **缺口 35**：input 加 `shape_type_any` 过滤（之前只有 `tags_any`）

### 5.12 tanned_leather（passive 容器）

```gdscript
verb = "tan"
trigger = "passive"
duration_required = 4320.0    # 3 游戏天
material_strategy = "transform"
inputs = [
    {"shape_type": "raw_hide", "@inside_container_tags": ["aging_vessel"]},
    {"materials.body": "tannin", "@inside_container_tags": ["aging_vessel"]},
]
outputs = [{"generate": {"shape_type": "leather",
                          "materials.body": "@input[0].materials.body", "qty": 1}}]
```

新材料 tannin = 橡树皮粉（grind oak_bark），自然铺垫"伐木 → 剥皮 → 磨粉"小链。

### 5.13 thread（spin at spinning_wheel，新工作站）

```gdscript
verb = "spin"
workstation = "spinning_wheel"
duration_seconds = 30.0
material_strategy = "transform"
inputs = [{"shape_type": "fiber_bundle", "materials.body.category": "fiber"}]
outputs = [{"generate": {"shape_type": "thread_spool",
                          "materials.body": "@input[0].materials.body", "qty": 3}}]
```

### 5.14 cloth（weave at loom，新工作站）

```gdscript
verb = "weave"
workstation = "loom"
duration_seconds = 60.0
inputs = [{"shape_type": "thread_spool", "materials.body.category": "fiber", "repeat": 4}]
outputs = [{"generate": {"shape_type": "cloth_bolt",
                          "materials.body": "@input[0].materials.body", "qty": 1}}]
```

### 5.15 charcoal（fire at kiln）— **核心燃料**

```gdscript
verb = "fire"
workstation = "kiln"
duration_seconds = 120.0
stamina_cost = 5.0
material_strategy = "transform"
inputs = [{"shape_type": "log", "materials.body.category": "wood"}]
outputs = [{"generate": {"shape_type": "charcoal_chunk", "materials.body": "charcoal", "qty": 3}}]
```

**重要决策**（已落地 2026-05-25）：放弃 `coal` 作为原料，**charcoal 是世界唯一的燃料**。Batch 1 所有原 `materials.body: "coal"` 改为 `"charcoal"`，`coal` substance/item 已删，炭窑 `kiln_burn` 反应已添加（log → charcoal x4）。理由：早期中世纪铁匠用木炭不用煤；木 → 炭循环让玩家有动机种树；简化材料表。

---

## 6. 第 2 批普通设计决策（要回填到 schema v3）

1. **木桶 = 容器模式**：存入 / 取出 = inventory action（不是 reaction），passive 反应通过 `@inside_container_tags` 自动匹配容器内实例
2. **统一 aging_vessel tag**：木桶 / 大缸通用，处理所有时间型 passive（奶酪、咸肉、鞣皮、啤酒、发芽）
3. **耐久度 + 破损系统**：耐久 0 → 加 `broken` tag，留 inventory，可重锻 / 修
4. **重锻递减上限**：每次 max_durability -30，三次后报废
5. **修理包按材质分**：金属包修金属、皮革包修皮革，一条 reaction + category 匹配 + 跨输入引用
6. **燃料统一为 charcoal**（已落地 2026-05-25）：删 `coal` substance/item，batch 1 retroactive 改完

---

## 7. 第 2 批魔法完成（12 件 + 3 砍）

> Status: **drafting** — HP 风（低魔 / 神秘）。原计划 15 件，过程中重塑成 12 件。
> 缺口编号沿用全文（36 起），合并到 §8。

### 7.1 干燥草药（passive dry）

3 种草药 category（common / medicinal / moonlight），普通草药用 `drying_rack` tag，月光草用 `moon_drying` tag。容器模式延伸——环境前提（"月光下"）通过容器选择体现，不引入环境匹配字段。

```gdscript
inputs = [{"materials.body.category_any": ["common_herb", "medicinal_herb"],
           "@inside_container_tags": ["drying_rack"]}]
duration_required = 1440.0    # 1 游戏天
# 月光草另一条 reaction，3 游戏天 + moon_drying tag
```

⚠ **缺口 36**：input 加 `materials.body.category_any` 平行 OR 匹配（同 §5.11c 的 `shape_type_any`）。

### 7.2 草药粉（grind at mortar）

复用 batch 1 grind verb，新工作站 mortar（研钵，预放）。任意 dried_herb category → 同名 powder material，1 → 2。

### 7.3 治疗药水（brew at alchemy_table）

新 verb `brew`，mix strategy，输出 healing_potion Material。

```gdscript
mix_result_material = "healing_potion"
inputs = [
    {"materials.body.category": "medicinal_herb_powder", "repeat": 2, "quality_weight": 1.0},
    {"materials.body": "water", "quality_weight": 0.0},
]
```

healing_potion Material：
```gdscript
use_effects = [
    {"buff": "regen", "duration_minutes": 10,
     "potency": "@self.quality / 100"},   # ⚠ 缺口 38
]
```

⚠ **缺口 37**：Material 加 `hazards` 字段（易燃 / 易爆 / 毒）。Reaction 失败时检查 input materials 的 hazards → 按 hazard 触发对应效果（点燃 / 爆炸 / 毒云 / 腐蚀）。例：硫磺 hazards=["flammable","explosive_when_heated"]，brew 失败 → 炸炉。
⚠ **缺口 38**：use_effects 字段 value 支持表达式（`@self.quality` 取实例品质，乘 buff 强度 / 持续时间）。

### 7.4 强化药水（passive moon）

```gdscript
verb = "moon_charge"
trigger = "passive"
duration_required = 4320.0        # 3 游戏天
material_strategy = "transform"
inputs = [{"shape_type": "potion_vial", "@inside_container_tags": ["moon_drying"]}]
# transform 派生：input.materials.body.transforms["moon_charge"]
# healing_potion → healing_potion_enhanced
```

一条 reaction 处理任何药水的月光强化，每种药水自己声明强化版（transforms map）。新加药水种类自动支持。

### 7.5 魔杖木坯（carve sub_option）

复用 batch 1 carve verb，sub_option=wand_blank。任意木材都能做（不再分 magic_wood category），quality_weight 从 wood log 品质继承。

```gdscript
outputs = [{"generate": {
    "shape_type": "wand_blank",
    "materials.body": "@input[0].materials.body",
    "properties": {
        "flexibility": "@input[0].quality / 100",
        "length_cm": 30,
    },
}}]
```

魔杖木材的"亲和性 / 抗性 / 流派"等定性属性留给**未来魔杖系统**专门设计，不在反应表里。

### 7.6 魔杖（combine compose）

```gdscript
verb = "combine"
material_strategy = "compose"
inputs = [
    {"shape_type": "wand_blank"},
    {"tags_any": ["wand_core"]},          # 矿物杖芯 tag
]
outputs = [{"generate": {
    "shape_type": "wand",
    "parts_map": {"shaft": "@input[0]", "core": "@input[1]"},
    "tags": ["wand", "magic_item"],
    "properties": {
        "max_wand_charges": "@input[1].materials.body.wand_charges_capacity",   # ⚠ 缺口 39
        "wand_charges":     "@input[1].materials.body.wand_charges_capacity",
        "flexibility":      "@input[0].properties.flexibility",
    },
}}]
```

**杖芯 Material 数值表**（独立的 wand_charges_capacity 字段，决定魔杖容量）：
| 杖芯 | wand_charges_capacity |
|---|---|
| crystal | 100 |
| moonstone | 150 |
| meteor_iron | 200 |

**用完即弃**：施法 -1 wand_charges，到 0 由使用代码加 `depleted` tag。区别于 broken：不能重锻 / 不能修，只能丢弃做新的。

⚠ **缺口 39**：Material 允许携带"应用域字段"（不只物理常数）。例：杖芯加 wand_charges_capacity / 涂层药水加 coating_buff / 易燃材料加 ignite_temp。表达式可读。schema §2.1 改成"Material 字段开放"。

### 7.7 提神药水（brew Pepperup）

跟 #18 治疗药水同结构，输出 pepperup_potion，效果是临时 buff：
```gdscript
# pepperup buff
stamina_regen: ×2.0
ignore_rest_cap: true     # buff 期间 stamina 上限不受 rest 限制
duration: 30 game min
```

不直接给 rest，buff 过后欠的觉还是要还。模拟"咖啡因"——能撑一阵子，最终还是要睡。

### 7.8 树皮纸（passive soak）

```gdscript
verb = "soak"
trigger = "passive"
duration_required = 1440.0     # 1 游戏天
inputs = [
    {"materials.body": "tree_bark", "@inside_container_tags": ["aging_vessel"]},
    {"materials.body": "water", "@inside_container_tags": ["aging_vessel"]},
]
outputs = [{"generate": {"shape_type": "paper_sheet", "materials.body": "bark_paper", "qty": 3}}]
```

新 verb `soak`（区别于鞣皮 tan，更通用）。

### 7.9 咆哮信（combine imbue）

```gdscript
verb = "combine"
workstation = "alchemy_table"
material_strategy = "compose"
inputs = [
    {"shape_type": "paper_sheet", "materials.body": "bark_paper"},
    {"materials.body": "berry_ink"},
    {"materials.body": "mandrake_powder"},     # 曼德拉草粉（HP 经典，被拔会尖叫）
]
outputs = [{"generate": {
    "shape_type": "blank_howler",
    "tags": ["letter", "magic_item", "writable"],
}}]
```

**写入机制（不是反应，是 inventory action）**：任何带 `writable` tag 的物品 → 右键菜单"写入" → UI 弹文本框 → 写完转化为带 message_text 的实例。同一个 UI 流程处理普通信件 / 咆哮信 / 卷轴。

### 7.10 月光石（passive moon）

```gdscript
verb = "moon_charge"
trigger = "passive"
duration_required = 10080.0    # 7 游戏天（稀有材料，慢）
inputs = [{"materials.body": "quartz", "@inside_container_tags": ["moon_drying"]}]
# transform 派生：quartz.transforms["moon_charge"] = "moonstone"
```

### 7.11 莓果墨水（mix）

```gdscript
verb = "mix"
mix_result_material = "berry_ink"
inputs = [
    {"materials.body.category": "berry", "repeat": 2},
    {"materials.body": "charcoal_powder"},   # 烟灰，grind charcoal 得（自动支持）
    {"materials.body": "water"},
]
outputs = [{"generate": {"shape_type": "ink_bottle", "qty": 3}}]
```

### 7.12 黄油啤酒（mix at stove）

```gdscript
verb = "mix"
workstation = "stove"
mix_result_material = "butterbeer"
inputs = [
    {"materials.body": "beer",   "quality_weight": 0.5},
    {"materials.body": "butter", "quality_weight": 0.3},
    {"materials.body": "sugar",  "quality_weight": 0.2},
]
```

butterbeer 效果：hunger +15，复用 well_fed buff 60 分钟，新加 warmth buff 30 分钟（modifiers 暂留空，等天气系统）。

### 砍掉的 3 件

- **#22 魔杖充能**：用完即弃机制不需要充能反应
- **#23 大锅**：workstation 类物品全部预放，不制造（项目设计决策）
- **#30 巧克力蛙**：用户决定放弃

---

## 8. 第 2 批魔法设计决策（要回填到 schema v4）

1. **环境前提走容器**——月光 / 阴干 / 风干等环境条件通过专用容器 tag（moon_drying / drying_rack）解决，不引入"@environment.moon_phase"字段。物理上仍 YAGNI。
2. **wand_charges 独立字段**——魔杖不复用 durability，独立 charges 系统给杖芯种类数值意义；用完即弃 = 加 depleted tag（区别 broken，不可修）
3. **写入 / 存取 / 阅读全是 inventory action**——writable / readable / store / take tag 标记物品能力，UI 在右键菜单展示对应动作，不走反应表
4. **失败剧烈程度由 input material hazards 决定**——`failure_modes` 仍可写常规失败，但材料的 hazards 字段是失败时的"额外损害"来源（火药材料失败会炸，惰性材料失败只损失材料）
5. **Material 字段开放**——不限于"物理常数"，可挂任何应用域字段（wand_charges_capacity / coating_buff / hazards / 未来魔杖亲和性等）
6. **工作台不制造**（再强调）——cauldron / scribe_desk / forge / anvil 全是预放设施
7. **新 buff 只列字段**——pepperup / warmth / courage 等新 buff 的 modifiers 在用例还没到的字段（如天气系统）先留空，落到 [player-stats.md §7](./player-stats.md)

---

## 9. 第 3 批预告（50 件）

- 装备：皮甲（leather + thread + 缝合）
- 装饰建材：石砖、地毯、家具
- NPC 视角：商人收购 / 加工链
- 更多药水：变形药 / 解毒 / 隐身（HP 经典）
- 魔法宠物 / 神奇生物（如果加入动物资产）

---

## 10. 第 1 批 + 第 2 批 schema 缺口汇总

按优先级排（缺口编号沿用 §2-§5 的标注）。

### 第 1 批（v2 已落地）

#### 必须解决（block schema 落地）

| # | 缺口 | 解决方案 |
|---|------|---------|
| 7 | transform strategy 的多输入主材料 | Verb 加字段 `transform_input_index: int = 0`；reaction 也允许 override（解决 smelt 用"矿+燃料"两输入，谁是被转化的）|
| 9 | failure_modes 引用 input 的语法 | 改用 `consume_inputs: PackedInt32Array = [0]`（按 input 索引）；旧的 `consume_parts: ["binding"]` 仅在 generate 物品的 parts_map 名下有意义 |
| 12, 20 | 表达式：generate.properties 从 @input 读 / 算术 | 列清楚支持的表达式：`@input[i].path`（取值）+ 基础算术（+, -, *, /, min, max）|
| 17 | combine 不能合成新材质（dough）| 加 `mix` strategy（输出固定材质，由 reaction 指定）。`combine` 保持纯 compose |

#### 应该解决（影响表达力）

| # | 缺口 | 解决方案 |
|---|------|---------|
| 8 | 副产物允许显式 materials | generate 的 materials 字段改成可选——空时按 verb strategy 派生，写了就用 |
| 10 | passive 的 clamp_properties | 加字段，简单实现 |
| 13, 14 | 多形状 reaction 的"模具"统一 | 不做模板化，多写 .tres 即可，UI 让玩家选 |
| 15 | repeat 简写（同 input 多槽）| 锦上添花，不阻塞 |
| 18 | Shape 的 default_tags | Shape Resource 加字段，generate 时自动并入 |
| 19 | 多匹配时玩家选 vs 自动 | UI 层处理，schema 不变 |

#### 可以延后（YAGNI 强化）

| # | 缺口 | 注释 |
|---|------|------|
| 11 | passive 受环境抑制（forge 范围内不冷却）| §11 已 YAGNI |
| 16 | 多输入混合材质决定输出 body | rope 三股不同纤维的 case，先不管 |
| 22 | 食用 effect schema | 另一个 layer |

### 第 2 批普通（v3 已落地）

#### 必须解决

| # | 缺口 | 解决方案 |
|---|------|---------|
| 23 | qty 字段允许表达式 | 统一规则：generate 内**任何字段**（shape_type / qty / properties / materials）都允许 @input 表达式（统一 §4.5b 适用范围）|
| 24 | shape_type 字段允许表达式 | 同 23（合并） |
| 27 | input 加 `@inside_container_tags` 匹配 | 匹配引擎扩展，dispatcher 维护"实例 → 所在容器"的反向索引 |
| 28 | passive 加 `duration_required: float` | 累计游戏分钟阈值后触发输出（区别于 modify 的 delta_properties 速率）|
| 29 | 多输入 passive 的成对匹配规则 | 必须同容器；中途取走 → 计时清零；不存进度 |
| 30 | dispatcher 维护"实例已停留多久"计时器 | 不存到 instance properties，独立 dict（key=(instance_id, reaction_id)）|
| 35 | input 加 `shape_type_any` 过滤 | 与 `tags_any` 同形式的 OR 匹配 |

### 第 2 批魔法（待 v4 落地）

#### 必须解决

| # | 缺口 | 解决方案 |
|---|------|---------|
| 36 | input 加 `materials.body.category_any` 平行 OR 匹配 | 与 `shape_type_any` 同形式（草药 reaction：common / medicinal 同一条 reaction 处理）|
| 37 | Material 加 `hazards: PackedStringArray` | 标记易燃 / 易爆 / 毒等危险性。dispatcher 在 reaction 失败时检查 input materials 的 hazards → 触发对应额外效果（点燃 / 爆炸 / 毒云 / 腐蚀）。reaction 自己的 failure_modes 仍生效，hazards 是叠加的"材料后果"|
| 38 | use_effects value 支持表达式 | `@self.quality` 取实例品质，乘 buff 强度 / 持续时间。Material.use_effects 的 dict 字段也走表达式 parser（§4.5b 范围扩展到 Material）|
| 39 | Material 字段开放（"应用域字段"）| schema §2.1 明示：Material 不限于物理常数，可挂任何应用域字段（wand_charges_capacity / coating_buff / hazards / 未来魔杖亲和性等）。表达式可读 |

#### 设计决策（不是 schema 字段）

| 项 | 决策 |
|---|------|
| 环境前提 | 通过专用容器 tag（moon_drying / drying_rack / aging_vessel）解决，YAGNI 真正的环境匹配字段 |
| 魔杖 charges | 独立 wand_charges 字段（不复用 durability），用完加 depleted tag（不可修，区别 broken）|
| 写入 / 存取 / 阅读 | inventory action，writable / readable / aging_vessel tag 标记物品能力 |
| 工作台 | 全部预放，不制造（项目设计决策）|

#### 可以延后

| # | 缺口 | 注释 |
|---|------|------|
| 40 | Material 上的魔杖专用字段 | 与 #39 合并 / 或留给魔杖系统单独设计时定 |
| 41 | catalyst（input consumed:false）| 巧克力蛙砍了，无其他 use case，YAGNI 强化 |

#### 应该解决（设计决策，不是 schema 字段）

| 项 | 决策 |
|---|------|
| 容器存取语义 | inventory action（不是 reaction）。物品在容器内 = inventory entry 加 `container_id` 字段 |
| aging_vessel tag | 木桶 / 大缸 / 腌缸通用打 tag，passive 反应统一靠这个 tag 匹配 |
| 耐久度 + broken | item.properties 增加 durability / max_durability；归零后由使用代码加 broken tag（不是 reaction）|
| 修理包语义 | 一条 reaction + category 跨输入引用，无 schema 改动 |
| 燃料统一 charcoal | Material 表删 `coal`，§2.1 smelt_iron 等 retroactive 改成 charcoal（2026-05-25 已落地） |

#### 可以延后

| # | 缺口 | 注释 |
|---|------|------|
| 25 | 可选 input（omelet 纯蛋 vs 加料）| 改成多写一条 reaction 解决 |
| 26 | passive 二步合并（增加 progress + 阈值变身）| 当前 2 步法已 OK，未来需要再合并 |
| 31 | 催化剂语义（yeast 不消耗）| 决定按份消耗，YAGNI |
| 32-34 | 换零件维修相关（broken_part_slot / swap_part / tags_all）| #11a 砍掉，相关缺口同时砍 |

---

## 11. 状态

- [x] 第 1 批 19 件（一对一过完，剔除采集机制 + 增补 alloy / cook / mix / pot）
- [x] 修订 reaction-schema.md → **v2 已落定**（12 个 schema 改动）
- [x] 第 2 批普通 15 件 + 维修系统
- [x] 修订 reaction-schema.md → **v3 已落定**（7 个缺口 + 5 个设计决策）
- [x] 玩家数值系统 → [player-stats.md v1](./player-stats.md)（5 stats、动态 stamina_cap、食物表、buff schema、工具耐久消耗规则）
- [x] 第 2 批魔法 12 件（草药 / 药水 / 魔杖 / 信件 / 月光石 / 黄油啤酒，砍了 3 件）
- [ ] 修订 reaction-schema.md → v4（落第 2 批魔法 4 个缺口 + 7 个设计决策）
- [ ] 第 3 批 50 件
- [ ] 终稿 schema → 开始 implementation phase 1

## 修订记录

- 2026-05-07 (a)：初版第 1 批 20 件 + 22 个缺口标注
- 2026-05-07 (b)：剔除采集机制 5 件 → 15 件；缺口收敛到 13
- 2026-05-07 (c)：与用户一对一过完 1-20 号，最终确认 19 件（去掉 dough 中间步骤）；schema 改动落到 reaction-schema.md v2
- 2026-05-07 (d)：第 2 批普通 15 件一对一过完。新增：容器型 passive（木桶 = aging_vessel）、耐久 / 破损 / 重锻 / 修理包系统、啤酒 4 层链（破例）、燃料统一 charcoal。新增缺口编号 23-30、35（共 7 个，待 schema v3）；32-34 因 #11a 换零件维修被砍而失效
- 2026-05-08 (e)：第 2 批魔法 12 件一对一过完。HP 风（低魔 / 神秘）替代原 Witcher 风草稿。完成：草药 dry / 草药粉 / 治疗药水 / 强化药水 / 魔杖木坯 / 魔杖 / 提神药水 / 树皮纸 / 咆哮信 / 月光石 / 莓果墨水 / 黄油啤酒。砍：#22 魔杖充能（用完即弃）、#23 大锅（workstation 不制造规则）、#30 巧克力蛙。新增缺口 36-39（4 个，待 schema v4）；新规则确立：环境前提走容器 tag、wand_charges 独立、Material 字段开放、写入是 inventory action、失败行为受材料 hazards 影响
