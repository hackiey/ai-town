# Reaction schema

> Status: **drafting v4** — schema 设计稿，尚无对应代码。
> 本文是 [crafting-interaction.md](./crafting-interaction.md) 的下沉，把"反应表"从概念拆成可落地的 Resource 类、匹配语法、material_strategy、代价 / 失败模型。
> v2 修订：跑完 [100-item-experiment.md](./100-item-experiment.md) 第 1 批 19 件后回填 12 个 schema 改动。
> v3 修订：跑完第 2 批普通 15 件 + 维修系统后回填 7 个新缺口 + 容器模型 + 耐久度 / 破损系统。
> v4 修订：跑完第 2 批魔法 12 件后回填 4 个新缺口 + Material 字段开放 + 危险材料失败语义 + 魔杖独立 charges 系统（见修订记录）。
>
> **不变量**：反应是世界物理常数，**LLM 不能生成新反应**，只能选已有反应。
> **配套文档**：[player-stats.md](./player-stats.md)（玩家数值系统、buff schema、食物 / 药水效果 / 工具耐久消耗）。

## 1. Context

[crafting-interaction.md §2.1](./crafting-interaction.md#21-动词系统反应表的查询键不是物品) 把反应升维成 `(verb, actor_properties, target_properties..., env) → effect`，但没定义：

- 反应规则物理上长什么样、存在哪
- 物品的"属性束"具体由哪些字段构成
- 多条规则能匹配同一组输入时谁赢
- 输出物品的属性怎么从输入推导
- 失败、体力、时间这些"代价"维度

本文一次定完，作为后续 dispatcher 重写、物品实例化改造、NPC 制造行为的契约。

**核心理念**（不变）：

- 反应按**属性束**匹配，永远不按 item_id
- 物品有**显式部件**（多材质组合），verb 决定材质如何流过
- 失败、体力、时间是反应的**第一公民**，不是后挂上去的修饰
- 主动（玩家 / NPC 触发）和被动（环境 tick）共用一套 schema，只用 `trigger` 字段区分

---

## 2. 类型系统

四个新 Resource 类 + 一个 Item 改造。

### 2.1 Material

材质的物理属性 + 应用域属性表。每个材质一个 `.tres`，全局共享。

```gdscript
# data/materials/iron.tres
class_name Material
extends Resource

@export var id: String = "iron"
@export var display_name: String = "铁"
@export var category: String = "metal"     # metal / wood / fiber / stone / liquid / food / ...

# 物理常数
@export var hardness: int = 70
@export var density: float = 7.87           # g/cm³
@export var melting_point: int = 1538       # °C
@export var flammable: bool = false
@export var ignite_temperature: int = -1    # 不可燃为 -1

# 危险性（v4，影响 reaction 失败时的额外效果）
@export var hazards: PackedStringArray = []
# 例：sulfur.hazards = ["flammable", "explosive_when_heated"]
#     mercury.hazards = ["toxic_vapor"]
#     dragon_blood.hazards = ["corrosive"]

# 视觉
@export var tint: Color = Color(0.7, 0.7, 0.75, 1)
@export var visual_fallback: String = ""    # 资产缺失时回退到这个材质的 mesh / icon

# 转化（被某 verb 作用后变成什么材质）
@export var transforms: Dictionary = {}
# 例：{"smelt": "iron", "rust": "iron_oxide"}

# 合金（和某材质在 alloy verb 下生成新材质）
@export var alloys: Dictionary = {}
# 例：copper.alloys = {"tin": "bronze", "zinc": "brass"}

# 标签（作为材质特征参与匹配）
@export var tags: PackedStringArray = []
# 例：iron.tags = ["metal", "ferrous", "magnetic"]

# 应用域字段（v4 开放，不限于物理）
# Material 允许挂任何应用域字段，表达式可读
# 例：moonstone.wand_charges_capacity = 150
#     sage_powder.alchemy_potency = 0.7
#     poison_oil.coating_buff = "poisoned"
#     bread.use_effects = [...]（食物效果挂这里）
```

**autoload**：`Materials.by_id("iron") → Material`。启动时扫 `data/materials/*.tres`。

**字段开放原则（v4）**：Material 不限定字段集——除了上面列出的"标准物理"字段，可以根据应用域加任意字段。dispatcher 通过表达式（§4.5b）按 `@input[i].materials.body.<field>` 读取。这避免了为每个新概念（魔杖容量 / 涂层效果 / 食物营养）扩展核心 schema。

### 2.2 Verb

动作的元数据 + UI / 代价默认。**Verb 不再决定 strategy**——material / quality strategy 都搬到 Reaction（v2 修订）。

```gdscript
# data/verbs/shape.tres
class_name Verb
extends Resource

@export var id: String = "shape"
@export var display_name: String = "锻打"

# UI：副选项（§2.5）
# 用法：同样的输入 + 同样的 verb 但玩家想要不同输出时（如铁砧锻刀刃 vs 斧头）
# 空 dict = 此 verb 没有副选项，dispatcher 看输入自动匹配
@export var sub_options: Dictionary = {
    # "blade":     "直刃",
    # "axe_head":  "斧头",
    # "pick_head": "镐头",
    # "pot":       "铁锅",
}
```

`stamina_cost` / `duration_seconds` 不挂在 Verb 上——每条 reaction 自己声明（见 §2.3），由 `Crafting.resolve` 透传给 runner，`StaminaWallet` 在 commit 时扣体力。

**autoload**：`Verbs.by_id("shape") → Verb`。

**Workstation 和 Verb 的关系**：每个 workstation 配一组 verbs。简单工作站只 1 个 verb（forge=`fire`，anvil=`shape`，mill=`grind`），复杂工作站多个 verb（workbench=`carve` `combine` `mix`，stove=`bake` `fry` `stew`）。多 verb 工作站打开 ActionPanel 顶部需要选 verb。

### 2.3 Reaction

反应规则。每条反应一个 `.tres`。

```gdscript
# data/reactions/forge_blade.tres
class_name Reaction
extends Resource

@export var verb: String = "shape"
@export var workstation: String = "anvil"
@export var sub_option: String = "blade"     # verb 有 sub_options 时必填，否则空
@export var trigger: String = "active"       # active / passive

# 策略：从 Verb 搬过来。每条反应自己声明。
@export var material_strategy: String = "compose"   # compose / transform / alloy / mix / modify
@export var quality_strategy: String = "weighted_avg"  # weighted_avg / min / max / first

# 输入：每个 dict 是一个槽位的匹配条件（§4）
@export var inputs: Array = []

# 输出：array，可多产物（§5）
@export var outputs: Array = []

# 难度（§7.3）
@export var difficulty: float = 0.0          # 0..1，0=必成

# 代价 override（不写或 0 = 用 verb 默认）
@export var stamina_cost: float = 0.0
@export var duration_seconds: float = 0.0

# 失败模式（§7.3）
@export var failure_modes: Array = []

# transform / alloy 用：哪些 input 是被转化的（剩下的当辅料消耗）
# transform 默认 [0]，alloy 默认 [0, 1]
@export var primary_input_indices: PackedInt32Array = []
```

**autoload**：`Reactions` 按 (verb, workstation, sub_option) 索引。

```gdscript
Reactions.find_active(verb="shape", workstation="anvil", sub_option="blade") -> Array[Reaction]
Reactions.find_passive() -> Array[Reaction]   # 全表，dispatcher 自己定 tick 频率
```

### 2.4 Item 改造

物品的属性束改成"部件 → 材质"显式结构。

```gdscript
# data/items/iron_blade.tres（修改后）
class_name Item
extends Resource

@export var id: String = "iron_blade"
@export var display_name: String = "铁刃"
@export var kind: String = "part"

# 形状（驱动反应匹配 + 视觉主体）
@export var shape_type: String = "flat_blade"

# 材质组成（part_name → material_id）
# 原料 / 中间件也用 dict，约定 part_name = "body"
@export var materials: Dictionary = {
    "body": "iron",
}

# 标签
@export var tags: PackedStringArray = ["metal", "tool_part"]

# 其它正交属性（前缀命名，§4.1）
@export var properties: Dictionary = {
    "weight": 1.2,
    "edge_sharpness": 60,
}

# 视觉
@export var icon: Texture2D
@export var world_mesh: PackedScene
```

**注意**：原 `properties.material_id` 字段废弃，材质统一走 `materials` dict。`properties` 只放与材质无关的标量（重量、锐度、温度等）。

---

## 3. 物品实例化（无堆叠）

**关键改造**：物品从"模板"升级到"带状态的实例"。

### 3.1 为什么

[crafting-interaction.md §2.4](./crafting-interaction.md) 之前默认 inventory 存 `(item_id, qty)`，所有 iron_ingot 共享同一份属性。

但是 §11 加热 / 锻打的例子要求**每块铁有自己的温度**：你烧红了 1 块，另外 4 块还是凉的，这 5 块不能 stack。同样地，每把铲子有自己的耐久 / 锐度 / 划痕。

结论：**所有物品都按实例存，无 stacking**。

### 3.2 数据结构

```gdscript
# inventory 改造后
inventory: Array[Dictionary] = [
    {
        "item_id": "iron_ingot",
        "quality": 50,
        "properties": {},                      # 实例属性，覆盖模板默认
    },
    {
        "item_id": "iron_ingot",
        "quality": 50,
        "properties": {"temperature": 850},    # 这块烧红了
    },
    {
        "item_id": "iron_shovel",
        "quality": 65,
        "properties": {
            "durability": 87,                  # 这把还新
            "owner_named": "老李的铲",
        },
        "materials": {                         # 实例化时固化下来（涌现产物用）
            "head": "iron",
            "shaft": "wood",
            "binding": "hemp",
        },
    },
]
```

**实例 properties 覆盖模板**：取属性时先查 instance.properties，再 fallback 到模板。

### 3.3 影响范围

| 系统 | 改造点 |
|---|---|
| inventory 存储 | `(id, qty)` → instance Array |
| InventorySlot UI | 1 槽 = 1 实例；显示实例属性条（温度 / 耐久）|
| ActionSlot UI | drag data 从 `{from_slot, item_id}` → `{from_slot, instance_index}` |
| MultiplayerSynchronizer | 实例数组同步（数组成员变更触发） |
| Save / load | instance properties 序列化 |
| 容量 | 1 件占 1 格 → 需要更大背包，或后续 chest |

---

## 4. 匹配语法

dispatcher 拿到玩家执行 → 一组 input items → 找匹配的 Reaction。

### 4.1 路径访问

`inputs[i]` 是一个 dict，每个 key 是属性路径，value 是约束。

```gdscript
{
    "shape_type": "flat_blade",                  # item.shape_type
    "materials.body.hardness": ">=60",           # 取 item.materials["body"] 拿 material_id，
                                                  # 再 Materials.by_id 取 .hardness
    "properties.temperature": ">800",            # item.properties.get("temperature")
    "tags": ["metal"],                           # item.tags 包含
}
```

支持的路径段：
- `shape_type`
- `kind`
- `materials.<part>.<material_field>`：先 lookup material，再取字段
- `materials.<part>` 直接给 material_id：`{"materials.body": "iron"}`
- `properties.<key>`：含实例属性 override
- `tags`：特殊处理，见 §4.3

**简写**：dispatcher 看到不带前缀的路径会按优先级试 `properties.X` / `shape_type`（如果完全等于 `"shape_type"`）。**不推荐用**，schema 写出全路径更清晰。

### 4.2 操作符

约束值是 String 或裸值：

| 形式 | 含义 |
|---|---|
| `"flat_blade"`, `60`, `true` | 等值 |
| `">=60"` `">60"` `"<=60"` `"<60"` `"==60"` | 数值比较 |
| `"40..80"` | 区间（含两端）|
| Array | tags 用，§4.3 |

**实现**：dispatcher 看 value 是 String 且匹配 `^(>=|<=|>|<|==|\d+\.\.\d+)` → 走比较；否则等值。

### 4.3 tags / shape_type_any 匹配

tags 是 Array of String，匹配特殊：

```gdscript
{"tags": ["metal", "magnetic"]}              # 默认 all：item.tags 必须同时含两者
{"tags_any": ["sharp", "pointy"]}            # any：含任一即可
{"tags_none": ["fragile", "wet"]}            # none：都不能含（黑名单）
```

3 种 key 可以共存。

`shape_type_any` 同形式（v3 新增，修理包配方等用）：

```gdscript
{"shape_type_any": ["ingot", "leather_strap", "plank"]}   # shape_type 是其中之一即可
```

注意 `shape_type` 单数（等值匹配）和 `shape_type_any`（OR 匹配）不能共存。

`materials.body.category_any` 同模式（v4 新增，草药 reaction 等用）：

```gdscript
{"materials.body.category_any": ["common_herb", "medicinal_herb"]}   # 多 category 之一
```

通用规则：任何"等值匹配"的字段都可以加 `_any` 后缀走 OR 匹配。

### 4.4 多匹配优先级

多条 reaction 匹配同一组输入时，**约束多的赢**。

```gdscript
constraint_count(reaction) = sum(len(input_dict.keys()) for input_dict in reaction.inputs)
```

按 count 降序排，第一条匹配中的 reaction 用。

**不引入显式 priority 字段**——99% 情况下"约束多 = 更精确"够用。真有需要 override 的极端 case，YAGNI 到时再加。

### 4.4b 容器内匹配（`@inside_container_tags`）

v3 新增。passive 反应通过这个字段匹配"在某种容器里的实例"，而不是任何位置：

```gdscript
inputs = [
    {"materials.body": "milk",
     "@inside_container_tags": ["aging_vessel"]},   # 必须在打了 aging_vessel tag 的容器内
]
```

dispatcher 维护"实例 → 所在容器" 的反向索引。空背包 / 地上散落 / 普通麻袋的奶**不匹配**，丢进木桶 / 大缸（aging_vessel）后才匹配，触发 passive 发酵。

**容器存取语义**：把奶存进木桶 / 取出来都是 **inventory action**（不是 reaction），实现上是给 inventory entry 加 / 改 `container_id` 字段。容器本身也是一个实例，在 inventory 或场景里。

**多输入 passive 的成对匹配**（§8.2 详述）：多个 input 都带 `@inside_container_tags` 时，必须**同一个容器**才匹配。一个容器内成对消耗。

### 4.5 repeat 简写

同 input dict 适用多个槽位时，用 `repeat: N` 简写：

```gdscript
# 啰嗦写法
inputs = [
    {"shape_type": "fiber_bundle"},
    {"shape_type": "fiber_bundle"},
    {"shape_type": "fiber_bundle"},
]

# 简写
inputs = [
    {"shape_type": "fiber_bundle", "repeat": 3},
]
```

dispatcher 解析时展开成 N 个相同槽位。`repeat` 不算 constraint count（展开后才算）。

---

## 4.5b 表达式语法（输出字段公式）

`outputs[i].generate` 内**任何字段**的 value 都可以是**字符串表达式**——shape_type、qty、materials.body、properties.* 全都支持。运行时从 input 读取并计算。

**v3 修订**：明确表达式适用范围。之前 v2 只列 properties，现在统一所有 generate 字段，因为 batch 2 的 #1 butcher（qty 跟 carcass 走）和 #2 cooked_fish（shape_type 跟生食走）都需要在非 properties 字段用表达式。

### 支持的形式

| 形式 | 例子 | 说明 |
|---|---|---|
| 字面值 | `60`, `"hot"`, `true` | 直接用 |
| 取值 | `"@input[0].quality"` | 第 0 input 的品质 |
| 嵌套取值 | `"@input[0].properties.temperature"` | input 的某属性 |
| 材质字段 | `"@input[0].materials.body.hardness"` | 通过 Materials lookup |
| 算术 | `"@input[0].quality * 0.7"` | + - * / |
| 函数 | `"min(@input[0].quality, 80)"`, `"max(...)"`, `"clamp(x, lo, hi)"` | 三个内置函数 |

### 例子

```gdscript
# 锻打铁刃：温度继承（降 200 度），锐度跟铁锭品质挂钩
outputs = [{"generate": {
    "properties": {
        "temperature":     "@input[0].properties.temperature - 200",
        "edge_sharpness":  "clamp(@input[0].quality * 0.7, 10, 95)",
        "durability":      "@input[0].materials.body.hardness * 10",
    }
}}]
```

```gdscript
# v3 例：butcher livestock 的 qty 跟 carcass instance 走
outputs = [{"generate": {
    "shape_type": "meat_chunk",
    "materials.body": "@input[0].materials.body",     # 牛 carcass → 牛肉
    "qty": "@input[0].properties.meat_yield",          # 数量从 instance 读
}}]
```

```gdscript
# v3 例：fry_food 的 shape_type 跟生食走（生鱼烤完是 cooked_fish 形状，肉块烤完是 cooked_meat_chunk）
outputs = [{"generate": {
    "shape_type": "@input[0].shape_type",
}}]
```

### 实现

dispatcher 看 properties value：
- 是 String 且以 `@` 开头或含运算符 → 跑表达式 parser（递归下降，~80 行 GDScript）
- 否则当字面值

**沙箱**：表达式只能读 input 数据，不能调用任意函数。仅支持上述操作符 / 函数。

---

## 5. 输出策略

`outputs` 是 array，每个元素是一个产物条目。两种模式：

### 5.1 generate（新建实例）

```gdscript
outputs = [
    {
        "generate": {
            "shape_type": "flat_blade_on_shaft",   # 新物品的形状
            
            # compose 用：每部件取哪个 input 的材质
            "parts_map": {
                "head":    "@input[0]",
                "shaft":   "@input[1]",
                "binding": "@input[2]",
            },
            
            # 显式材质（mix 必须；compose / transform / alloy 可选 override）
            # "materials": {"body": "veg_stew"},
            
            "tags": ["tool", "dig"],
            "properties": {                         # 初始实例属性，支持表达式（§4.5b）
                "durability": "@input[0].materials.body.hardness * 10",
            },
            "qty": 1,                               # 生成几个独立实例
        }
    }
]
```

**materials 派生顺序**：
1. 反应里写了 `materials` → 直接用（mix 必须；其它 strategy 可 override 副产物等）
2. 没写 → 按 reaction.material_strategy 派生：
   - **compose**：parts_map → 每部件取对应 input.materials.body
   - **transform**：取 input[primary_input_indices[0]] 的材质，查 Materials.transforms[verb]
   - **alloy**：取 input[primary_input_indices] 两个的材质，查 Materials.alloys 表
   - **modify**：不会用 generate（用 §5.2）

**形状到 item_id 的解析**：由于无 .tres 预定义产物，运行时根据 (shape_type, materials) 组合生成 item id（如 `iron+wood+hemp+flat_blade_on_shaft` → 自动 id `auto_<hash>`）。display_name 取自 `Shapes.by_type(shape_type).display_name` + 主材质名拼接（"铁铲"），玩家可改名。

### 5.2 modify（原地改输入）

```gdscript
# data/reactions/heat_iron_ingot.tres
outputs = [
    {
        "modify": "@input[0]",                     # 改 input[0] 实例
        "set_properties": {
            "temperature": 1000,                   # 设到 1000（active 常用）
        },
        "delta_properties": {                      # 增量改（passive 常用）
            # "temperature": -10,                  # passive：单位是"每游戏分钟"
        },
        "add_tags": ["hot"],                       # 追加 tag
        "remove_tags": ["cold"],
    }
]
```

modify 不消耗输入、不生成新物品。常用于：
- 加热 / 冷却（温度变）
- 锐化 / 损坏（锐度 / 耐久变）
- 染色（tint 变）
- 被动 tick（生锈、腐烂、燃烧）

**delta_properties 的语义（v2）**：
- 数值是"**每游戏分钟**的变化率"，不是"每 tick"
- dispatcher 实际扫描间隔（tick_interval）独立配置，应用时按 elapsed_minutes × rate 算
- 好处：调 tick 频率不影响物理速率
- 例：`{"temperature": -40}` = 每游戏分钟降 40°C，1000°C 大约 25 游戏分钟降到 0 区间

**没有 clamp_properties 字段**：环境常量（如 ambient_temperature=25）由 dispatcher 全局管。temperature 这种属性 dispatcher 知道"下限是 ambient"，自动钳。如果未来加"冬天 ambient=5"，改 Environment 一处生效。

**反应里要表达"如果触发 modify 后属性达到某门槛 → 触发别的反应"**（如温度 < 100 → 移除 hot tag）→ 用另一条 passive reaction 单独写，不在本 modify 里复合。

### 5.3 多产物

outputs 是 array，可以多条。

```gdscript
# 熔铁矿：得铁锭 + 矿渣副产物
outputs = [
    {"generate": {"shape_type": "ingot", ...}},
    {"generate": {"shape_type": "slag",  ...}},
]
```

或同时 modify + generate：

```gdscript
# 锻打：消耗烧红的铁锭，得到斧头 + 烧红的铁锭被消耗（不显式 modify，是 generate 的隐含规则）
```

**消耗规则**：默认所有 input 在反应执行后消耗（从 inventory 移除）。如果有 `modify: "@input[i]"` 则该 input 不消耗（被原地改）。如果某 input 是 catalyst（不消耗也不改）—— **YAGNI，到 §11 模具 / 坩埚 case 出现再加 `consumed: false` 字段**。

---

## 6. Strategy（在 Reaction 上）

v2 修订：strategy 从 Verb 搬到 Reaction，因为同一 verb 可能对应多种 strategy（如 forge 的 fire verb：smelt = transform，heat = modify）。

### 6.1 material_strategy

决定输出物品的材质如何从输入推导。

| strategy | 行为 | 适用 |
|---|---|---|
| **compose** | parts_map 把每个 input 的 `materials.body` 装到对应部件 | 组装多部件物品（铁铲、斧）、雕刻单件（柄、板）|
| **transform** | 单输入（或主输入索引），输出 = `Materials.by_id(input.materials.body).transforms[verb]` | smelt, fry, bake, grind |
| **alloy** | 双输入（默认前两个），输出 = `Materials.by_id(a).alloys[b]` | 合金冶炼（铜+锡=青铜）|
| **mix** | 多输入，输出材质**反应里显式写**（不查材质表）| 烹饪、调和（番茄+水+盐=菜汤）|
| **modify** | 不生成新物品，原地改 input 的 properties / tags | 加热、冷却、锐化、生锈 |

**怎么选**：
- 输出是装配物（吃了能拆出零件）→ compose
- 单原料化学变化（矿→铁、生肉→熟肉）→ transform
- 物理金属合金，可查表 → alloy
- 配方组合成新东西（食物常见）→ mix
- 状态改变（不出新物品）→ modify

**transform / alloy 的多输入**：用 `primary_input_indices` 指定哪些 input 是被转化的，剩下的（如木炭、水）当辅料消耗。
- transform 默认 `[0]`
- alloy 默认 `[0, 1]`

**举例**：
- `compose` + 铁刃 + 木柄 + 麻绳 → 输出 materials = {head: iron, shaft: wood, binding: hemp}
- `transform` + 铁矿 + 木炭（primary=[0]）→ 输出 materials = {body: iron}（因为 iron_ore.transforms.smelt = "iron"）
- `alloy` + 铜 + 锡 + 木炭（primary=[0,1]）→ 输出 materials = {body: bronze}（copper.alloys.tin = "bronze"）
- `mix` + 番茄 ×2 + 水 → 输出 materials = `{"body": "veg_stew"}`（反应自己写）
- `modify` + 烧热的铁锭 → 改 input[0].properties.temperature

### 6.2 quality_strategy

决定输出 quality 怎么从 input qualities 算。

| strategy | 公式 |
|---|---|
| **weighted_avg** | `sum(qty[i] * weight[i]) / sum(weight[i])`，weight 来自 `inputs[i].quality_weight`（默认 1.0）|
| **min** | min(qty[i])，谁最差跟谁 |
| **max** | max(qty[i])，最好的决定（罕见，光环效应）|
| **first** | qty[0]，主输入决定 |

最后乘上玩家 mastery：

```gdscript
output_quality = clamp(
    base * player.mastery.get(verb_id, 0.6),
    0, 100
)
```

mastery 范围 [0.6, 1.5]，新手默认 0.6（次品起步），大师上限 1.5（能榨干材料潜力）。增长机制（每次 +X、按结果触发）后续 progression 系统定。

---

## 7. 代价系统

### 7.1 体力（stamina）

每次反应在 commit 时扣体力，由 `StaminaWallet.try_spend` 统一执行；体力不够 → reaction 不应用产物，材料返还。

```gdscript
# Crafting.resolve 把 reaction.stamina_cost 透传到 result
spend = StaminaWallet.try_spend(character, result.stamina_cost, "craft:" + reaction_id)
# spend.ok == false → outcome=failed, reason=stamina_depleted
```

cost 真值在 `data/mechanics/{crafting,crops,mining,well}.lua`——GDScript 不再持有任何数值常量。Mastery / 难度修正未来加在 lua 层。

### 7.2 时间（duration）

按"执行"后**进入 N 秒持续状态**：
- 显示进度条
- 玩家走出工作站范围 → 取消（不扣体力 / 材料）
- 进度走完 → dispatcher 真正执行 → 扣材料 + 扣体力 + 出产物

时间走**游戏时间**（GameClock，默认 7×），玩家用 `/timewarp` 能加速。

`duration_seconds` 字段也来自 reaction（lua），由 `Crafting.resolve` 透传到 runner。NPC 同样的 duration——schema 一致，不为 NPC 单独写"假装在工作"逻辑。

### 7.3 失败

**触发**：

```gdscript
fail_chance = clamp(reaction.difficulty - (player.mastery[verb_id] - 0.6), 0, 1)
```

- 难度 0.5 + 新手 mastery 0.6 → 50% 失败
- 难度 0.5 + 熟练 1.0 → 10%
- 难度 0.9 + 新手 0.6 → 90%
- 难度 0 → 永不失败

**失败时的损失**：按 `failure_modes` 加权随机选一个 mode 应用。

```gdscript
failure_modes = [
    {
        "name": "绑定失败",
        "weight": 0.6,
        "consume_inputs": [2],                 # input 索引 2（绳）消耗
        "return_inputs": [0, 1],               # input 0 1（刃、柄）退回
        "message": "绳子绑歪了，木柄滑出来",
    },
    {
        "name": "全废",
        "weight": 0.1,
        "consume_inputs": [0, 1, 2],
        "return_inputs": [],
        "message": "彻底搞砸了",
    },
    {
        "name": "夹生",                           # 半损例：可重试
        "weight": 0.0,
        "consume_inputs": [],
        "return_inputs": [0, 1, 2],
        "message": "没烤熟，可以再来一次",
    },
]
```

**v2 修订**：用 `consume_inputs` / `return_inputs`（PackedInt32Array，按 input 数组索引）替代旧的 `consume_parts` / `return_parts`（按 parts_map 的 key），因为有些反应（smelt 含 ore + charcoal）多个 input 都有 `body` 部件，按名字引用有歧义。

**约束**：consume_inputs 与 return_inputs 不重叠，且并集 = 所有 input 索引（每个 input 必须有归属）。

**默认 fallback**：`failure_modes` 为空时，失败 = 全消耗（最简单的兜底）。MVP 阶段所有反应可以先不写 failure_modes，后续按需细化。

**失败后**：
- mastery 微涨（失败也学到，机制后定）
- 推 notification 显示 mode.message

---

### 7.3b 失败行为受输入材料 hazards 影响（v4 新增）

`failure_modes` 仍是常规失败（消耗 / 退回 input + message）。但额外：dispatcher 在失败时检查所有 input materials 的 `hazards`，按 hazard 类型触发**额外效果**：

| hazard | 效果 |
|---|---|
| `flammable` | 工作站附近物品被点燃（modify add_tags ["burning"]）|
| `explosive_when_heated` | 范围爆炸：玩家受 hp 损失、附近物品 durability 损失 |
| `toxic_vapor` | 玩家加 `poisoned` debuff |
| `corrosive` | 工作站 durability -10，附近金属物品 durability -5 |

例：硫磺 + 草药粉做药水（玩家配方乱了），失败时除了消耗材料，还会引爆——硫磺 hazards = ["flammable", "explosive_when_heated"]。惰性原料（草药 / 水）失败 = 单纯材料损失。

**实现**：dispatcher 失败 handler 维护 hazard → effect 的 hardcoded 表（不在 reaction schema 内），按 union of input hazards 触发。

### 7.4 耐久度 + 破损（v3 新增）

工具 / 武器 / 防具的耐久消耗**不在 reaction schema 内**——是使用代码（攻击 / 砍树 / 挖矿等 handler）按使用次数 / 强度扣减。schema 这层只规定字段约定 + 维修 reaction 的形式。

**字段约定**（item.properties）：
- `durability: float`（当前耐久）
- `max_durability: float`（耐久上限，初始按主材质查 [player-stats.md §5b](./player-stats.md)：木 50 / 青铜 150 / 铁 200 等）

**消耗规则**（详见 player-stats.md §5b）：每次使用 -1 durability。

**破损状态**：使用代码检测到 `durability ≤ 0` → 给 instance 加 `broken` tag。物品**留在 inventory**，使用代码检查 broken tag 阻止使用（剑挥不动、锅烧不了）。

### 7.4b 魔杖 charges + depleted（v4 新增）

魔杖**不复用** durability/broken 系统，独立机制：

**字段约定**（item.properties）：
- `wand_charges: float`（当前能量）
- `max_wand_charges: float`（容量上限，从杖芯材质读：moonstone 150 / crystal 100 / meteor_iron 200）

**消耗**：每次施法 -1 wand_charges（具体施法系统定）。

**用尽状态**：使用代码检测到 `wand_charges ≤ 0` → 给 instance 加 `depleted` tag。

**关键差异（vs broken）**：
- `broken` 可重锻 / 修复
- `depleted` **不可修复**——魔杖用完即弃，玩家做新的

理由：魔杖是 HP 灵魂物品，杖芯种类的差异化（不同 capacity）需要数值落点；魔法物品天然不耐用是设定的一部分。

**维修 reaction**（属于 schema，全是 active modify）：

1. **重锻**（金属物品）：在 anvil 加 broken metal item + 同材质 ingot + 锤子 → modify 恢复 durability。每次 `max_durability -= 30`，三次后只能拆解（filter `max_durability: ">30"` 挡住）。失败由熟练度系统自然管。
2. **野外应急**：手持 repair_kit 修受损（非破损）物品，+15 耐久。修理包按材质分类，靠跨输入引用过滤（`shape_type: "repair_kit", "properties.target_category": "@input[0].materials.body.category"`）。
3. **修理包配方**：1 binding（绳/线/布）+ 1 主材料（ingot / leather_strap / plank）→ repair_kit，target_category 跟主材料走。一条 reaction 覆盖所有材质。

完整 reaction 例见 [100-item-experiment.md §5.11](./100-item-experiment.md)。

## 8. 主动 / 被动反应

`trigger` 字段区分：

> **实现现状（2026-06-07 已落地，与下文设计稿有出入）**：被动反应**第一批已实现**——晾晒（`dry_malt`：小麦→麦芽）和发酵（`ferment_beer`：水+麦芽→啤酒）。实际落地形态比本节的 `.tres` Resource + `delta_properties` / `duration_required` 设计稿**更轻**，要点：
>
> - **同表**：被动反应就写在 `data/mechanics/crafting.lua` 的 `reactions` 表里，`trigger="passive"`，与主动反应同表同 query 风格（不是独立 `.tres`）。skill 校验 / active 索引 / metadata 三个 load-time 循环都 `if r.trigger ~= "passive"` 跳过。
> - **每条自带 `tick_seconds`**（不是 dispatcher 统一频率）：酿酒 3600、晾晒 1800、将来魔咒可 30。这样慢反应不被高频扫、快反应也能秒级跳。
> - **每条自带 `on_tick(ctx)` lua 钩子**（自定义每 tick 逻辑）+ `strategy` + `match{vessel_tag,input,base_liquid}` + `auto_start`。当前唯一 strategy = `ramp_transform`：**开始即变身成 `output`、品质从 0 线性爬到 `ceiling`、到 `hours` 定格**（晾晒/发酵共用 `ramp_quality` helper）。
> - **唯一写者 = `src/autoload/passive_simulator.gd`**（server-only autoload）。`_process` 按每条反应各自的下次触发时间调度；到点扫 容器(`containers` 组)/背包(`npcs`/`players` 组)/地面(`ground_items` 组) 的 slot，对进行中的（按成品 `output` 区分）调 `run_tick` 推进 + 持久化，对 `auto_start` 反应给新匹配 slot 起头。**取代了 settle-on-access**（`LiquidOps.settle` 及所有访问点的 settle 调用已删，读路径只读 slot 当前值）。
> - **进行中状态复用既有 slot 字段** `transform_age` / `transform_settle_hour` / `ferment_ceiling`（无新增 DB 列）；进行中反应按当前成品 `output`（液体看 content、离散看 item_id）反查，不持久化 reaction id。`vessel_tag` 同时匹配宿主容器 `passive_tags`（晾晒架的 `drying`）和物品自身 tag（酿酒桶的 `brewing_vessel`）。
> - **发酵品质上限公式**（在 crafting.lua，单一真值）：`eff = clamp(0.6 + (熟练度 - 难度)/100, 0, 1)`；`ceiling = round(clamp(原料品质 × eff, 0, 100))`。晾晒无技能 ⇒ `ceiling = 输入品质`。
> - 起头：晾晒 `auto_start`（放进晾晒架即开始）；发酵由 `brew` 动作起头（`BrewHandlers.run_brew`，NPC + 玩家共用）。
> - 配套：`MechanicHost.query` 已支持把 Array/Dict 参数转成 lua table（之前只能传 primitive）。
>
> 下文 §8.1–§8.2b 仍是更宽的设计愿景（`modify`/`delta_properties` 连续型、`duration_required`、`@inside_container_tags`），**尚未实现**；新增被动反应目前按上面的 lua 形态写。

### 8.1 active

玩家或 NPC 在工作站按"执行"触发。dispatcher 主流程：

```
1. 玩家按 E 选 reaction（隐式：根据 input + workstation 自动找）
2. 检查：体力够 / mastery 够 / 工作站匹配 / inputs 匹配
3. 进入 duration 持续状态（进度条）
4. 完成 → roll fail_chance
5. 成功 → 应用 outputs；失败 → 应用 failure_mode
6. 扣体力（不退）
7. mastery += δ
```

### 8.2 passive

环境 tick 触发，没有发起方。`PassiveSimulator`（autoload）按内部 tick 扫表：

```
每 N 游戏分钟（默认 5）扫一次：
  对所有 trigger=passive 的 reaction:
    对世界里所有"在场"实体（inventory + ground items + 容器内物品）:
      if reaction.inputs 匹配:
        apply outputs（通常是 modify）
        - delta_properties 应用 = rate × elapsed_minutes
```

**Reaction 不写 tick_interval**——dispatcher 自己定扫描频率。反应只声明物理速率（`delta_properties` 单位是"每游戏分钟"，§5.2）。

例：

```gdscript
# data/reactions/passive_cool.tres
trigger = "passive"
material_strategy = "modify"
inputs = [{"properties.temperature": ">25"}]
outputs = [{
    "modify": "@input[0]",
    "delta_properties": {"temperature": -40},   # 每游戏分钟降 40°C
}]
# dispatcher 自动钳到 ambient（25），不用反应里写
```

```gdscript
# data/reactions/iron_rust.tres
trigger = "passive"
material_strategy = "modify"
inputs = [{"materials.body": "iron", "tags": ["wet"]}]
outputs = [{
    "modify": "@input[0]",
    "delta_properties": {"durability": -0.1},   # 每游戏分钟掉 0.1 耐久
    "add_tags": ["rusting"],
}]
```

### 8.2b 累计时间型 passive（v3 新增）

`delta_properties` 是"持续累加"型 passive（生锈、冷却、燃烧），适合"每分钟变一点"的物理量。

但 batch 2 的奶酪 / 啤酒 / 咸肉是另一种：**累计 N 游戏分钟后一次性变身**。需要新字段 `duration_required`：

```gdscript
# data/reactions/ferment_cheese.tres
trigger = "passive"
duration_required = 720.0     # 累计 720 游戏分钟（=12 游戏小时）
material_strategy = "transform"

inputs = [
    {"materials.body": "milk", "@inside_container_tags": ["aging_vessel"]},
]
outputs = [
    {"generate": {"shape_type": "@input[0].shape_type",
                  "materials.body": "sour_milk", "qty": 1}},
]
```

**dispatcher 维护"实例已停留多久"计时器**：
- 独立 dict，key = `(instance_id, reaction_id)`，value = 累计游戏分钟
- 不存到 instance.properties（避免污染数据 + 简化序列化）
- 实例的 inputs 仍匹配 → 计时器累加 elapsed_minutes
- 累计达到 duration_required → 触发 outputs，计时器清零
- 实例不再匹配（被取出容器、属性变了）→ **计时器清零**（不存进度，简化）

**多输入 passive 的成对匹配（v3 新增）**：

```gdscript
# 咸肉：raw_meat + salt 都在同一个 aging_vessel 里
inputs = [
    {"materials.body": "raw_meat", "@inside_container_tags": ["aging_vessel"]},
    {"materials.body": "salt",     "@inside_container_tags": ["aging_vessel"]},
]
```

匹配规则：
- 多个 input 都带 `@inside_container_tags` → 必须**同一个容器实例**才匹配
- 1 块肉配 1 份盐成对消耗
- 中途取走任意 input → 这对 (instance_id, reaction_id) 计时器清零
- 重新放回 → 计时器从 0 开始，**不存进度**（简化）

**MVP 范围**：先不实现 PassiveSimulator，schema 字段留好。先做 active，跑通 100 物品实验。

**性能注**：每 5 游戏分钟扫一遍所有"在场"物品（玩家+NPC背包优先，地上 / 容器后期）。预估 MVP 几十件物品 × 几条 passive reaction，无压力。规模上来后按"反应主属性"建索引（如 cool 反应只看含 temperature 的物品）。

---

## 9. 视觉表达层

涌现产物没有专属 .tres、没有专属图标 / mesh。运行时按 (shape_type, primary_material) 找资产。

### 9.1 资产目录

```
data/visual_assets/
  flat_blade_on_shaft/
    iron.png           # icon
    iron.glb           # 3D
    copper.png
    copper.glb
  axe_head_on_shaft/
    iron.png
    ...
```

### 9.2 fallback 链

查找 `(shape_type, material)` 的资产：

1. **精确匹配**：`flat_blade_on_shaft/iron.png` 存在 → 用
2. **材质 fallback**：用 `Materials.by_id(material).visual_fallback` 递归（钢 → 铁）
3. **形状父类**：shape_type 注册表里 `flat_blade_on_shaft.parent = "tool_head_on_shaft"`，用父形状的资产
4. **兜底**：色块（用 material.tint）+ Label3D 显形状名

### 9.3 主部件

复合物品哪个部件决定视觉主色？由 shape_type 自带 `primary_part` 配置：

```gdscript
# data/shapes/flat_blade_on_shaft.tres（shape 注册）
class_name Shape
extends Resource

@export var type: String = "flat_blade_on_shaft"
@export var display_name: String = "铲"
@export var parent: String = "tool_head_on_shaft"
@export var primary_part: String = "head"     # 视觉主色取 head 的材质
@export var secondary_parts: Array = ["shaft"]  # 副色 / 装饰
```

**autoload**：`Shapes.by_type("flat_blade_on_shaft") → Shape`。

### 9.4 命名

涌现产物的 display_name 自动拼接：

```gdscript
suggested_name = "%s%s" % [
    Materials.by_id(primary_material).display_name,
    Shapes.by_type(shape_type).display_name,
]
# 铁刃 + 木柄 + 麻绳 → "铁铲"
```

玩家可改名（存在 instance.properties.owner_named）。

---

## 10. 配套 autoload + 文件结构

```
data/
  materials/
    iron.tres        # hardness, melting_point, transforms, alloys, tint
    wood_oak.tres
    hemp.tres
    flour.tres
    bread.tres       # food: hunger_restore, stamina_restore, edible
    veg_stew.tres
    cooked_meat.tres
    ...
  verbs/
    fire.tres        # forge / kiln 用，无 sub_options
    shape.tres       # anvil 用，sub_options = blade/curved_blade/axe_head/pick_head/pot
    hammer.tres      # anvil 用，重锻 / 锻打（v3 区分，shape 是装配，hammer 是改属性 / 修复）
    grind.tres       # mill 用
    carve.tres       # workbench 用，sub_options = shaft/plank
    combine.tres     # workbench 用，无 sub_options（输入区分）
    mix.tres         # workbench 用
    bake.tres        # stove 用
    fry.tres         # stove 用
    stew.tres        # stove 用
    boil.tres        # stove 用（v3，区别于 stew，soup 用）
    # v3 新增（批 2）
    butcher.tres     # butcher_block 用
    churn.tres       # butter_churn 用
    spin.tres        # spinning_wheel 用
    weave.tres       # loom 用
    repair.tres      # 不需工作站
    # passive verbs（v3）
    cure.tres        # 腌肉
    ferment.tres     # 奶酪 / 啤酒
    germinate.tres   # 麦芽
    tan.tres         # 鞣皮
  shapes/
    ingot.tres
    flat_blade.tres
    flat_blade_on_shaft.tres
    pot.tres
    ...
  workstations/
    forge.tres            # verbs = ["fire"]
    anvil.tres            # verbs = ["shape", "hammer"]
    workbench.tres        # verbs = ["carve", "combine", "mix"]
    mill.tres             # verbs = ["grind"]
    stove.tres            # verbs = ["bake", "fry", "stew", "boil"]
    # v3 新增（批 2）
    kiln.tres             # verbs = ["fire"] （烧炭、烧砖）
    butcher_block.tres    # verbs = ["butcher"]
    butter_churn.tres     # verbs = ["churn"]
    spinning_wheel.tres   # verbs = ["spin"]
    loom.tres             # verbs = ["weave"]
    # 容器（无 verb，靠 aging_vessel tag 让 passive 反应识别）
    aging_barrel.tres     # tags = ["aging_vessel"]
    aging_vat.tres        # tags = ["aging_vessel"]
  items/                              # 模板，主要是原料 / 中间件
    iron_ore.tres
    iron_ingot.tres
    wood_log.tres
    wood_shaft.tres
    ...
  reactions/
    smelt_iron.tres
    heat_iron_ingot.tres
    passive_cool.tres
    forge_blade.tres / curved_blade / axe_head / pick_head / pot
    carve_shaft.tres / plank
    grind_flour.tres
    twist_rope.tres
    assemble_shovel.tres / axe / pick / knife / sickle
    bake_bread.tres
    fry_meat.tres
    stew_veg.tres
    alloy_bronze.tres
    ...
  visual_assets/                      # 见 §9.1
    <shape>/
      <material>.png
      <material>.glb

src/autoload/
  materials.gd                         # Materials.by_id / by_category
  verbs.gd                             # Verbs.by_id
  shapes.gd                            # Shapes.by_type
  workstations.gd                      # Workstations.by_id
  reactions.gd                         # Reactions.find_active / find_passive
  # items.gd 已存在，加 by_id 走新 schema
```

### 10.1 Material 上的食物 / 使用效果

食物 / 饮料 / 药水的"使用效果"挂在 Material 而非 reaction，结构由 [player-stats.md §7](./player-stats.md) 定义：

```gdscript
# data/materials/bread.tres
id = "bread"
category = "food"
edible = true
use_effects = [
    {"stat": "hunger", "delta": 30},     # 瞬时改 player stat
]

# data/materials/beer.tres
id = "beer"
drinkable = true
use_effects = [
    {"stat": "hunger", "delta": 5},
    {"buff": "drunk", "duration_minutes": 30},   # 持续 buff
]

# v4 新增：use_effects value 支持表达式（@self.quality 取实例品质）
# data/materials/healing_potion.tres
id = "healing_potion"
drinkable = true
use_effects = [
    {"buff": "regen", "duration_minutes": 10,
     "potency": "@self.quality / 100"},   # buff 强度按实例品质缩放
]
```

吃 / 用 handler 读 `Materials.by_id(item.materials.body).use_effects`，按 entry 类型应用：
- `{"stat": X, "delta": Y}` → player.X += Y
- `{"buff": id, "duration_minutes": N, "potency": expr}` → 加 Buff 实例到 player.active_buffs，强度按 potency 表达式缩放

**v4 修订**：表达式语法（§4.5b）扩展到 Material.use_effects 的 value 字段。`@self` 指当前被使用的物品实例（`@self.quality` / `@self.properties.X`）。

完整食物数值表 + buff schema 见 [player-stats.md §6-§7](./player-stats.md)。

**为什么放 Material**：
- 物理直觉——面包多顶饱是面包的属性，不是"做面包反应"的属性
- 形状不影响营养（一片面包 vs 一整条面包都按 bread 材质算 → qty 决定份数）
- 反应只产出物品，不管"用的时候发生啥"，职责清楚

---

## 11. MVP 范围

按 `docs/architecture/crafting-interaction.md` + 100 物品实验，按这个顺序落地：

### Phase 1：schema 骨架（2-3 天）
1. Material / Verb / Shape / Workstation / Reaction Resource 类定义
2. 5 个 autoload + 目录扫描
3. Item 改造（加 materials dict、shape_type）
4. 迁移现有 items + 写 ~10 个 material .tres + 9 个 verb .tres + 5 个 workstation .tres

### Phase 2：dispatcher 重写（3-4 天）
5. 匹配引擎（路径访问 + 操作符 + tags + repeat 展开）
6. **表达式 parser**（§4.5b）
7. compose / transform / mix / alloy 4 个 material_strategy 分支
8. weighted_avg 一个 quality_strategy
9. generate 输出模式（含 materials override）
10. 写第 1 批 19 件对应的 ~15 条 reaction .tres

### Phase 3：实例化改造（3-5 天，最重）
11. inventory 数据结构改 instance Array（无 stacking）
12. 同步 + 序列化
13. UI 改造（InventorySlot / ActionSlot 按实例）

### Phase 4：代价 + 持续动作（2 天）
14. duration 持续状态 + 进度条
15. stamina 字段 + 扣减
16. mastery 字段 + 默认 0.6

### Phase 5：失败 + modify（2 天）
17. difficulty + fail_chance
18. failure_modes 应用（按 input 索引）
19. modify 输出模式 + heat 反应端到端

### Phase 6：sub_options + 多 verb 工作站（1-2 天）
20. ActionPanel 在多 verb 工作站显示 verb 选择条
21. ActionPanel 在有 sub_options 的 verb 显示 sub_option 选择条

### Phase 7：被动反应（待跑过 100 物品后再启动）
22. PassiveSimulator（按 5 游戏分钟 tick + 索引）
23. 冷却 / 生锈 / 腐烂 第一批被动反应
24. dispatcher 的 ambient 钳位逻辑（temperature → 25）

### YAGNI 列表（schema 不实现）

- **catalyst**（不消耗的 input）—— v3 决定 yeast 也按份消耗，无催化语义；模具 / 坩埚 case 出现再加
- **显式 priority**（reaction 优先级 override）—— 约束多的赢够用
- **environment 输入**（季节 / 邻近实体）—— 魔法批的月光晶会逼回来
- **可选 input**（omelet 纯蛋 vs 加料）—— v3 决定多写一条 reaction 解决
- **passive 进度持久化**（中途取出能"暂停"）—— v3 决定不存进度，取出 = 计时清零
- **swap_part / 换零件维修**（broken_part_slot 追踪）—— v3 决定砍掉 #11a，只保留重锻 / 野外维修
- **玩家技能影响失败种类**（"新手专门绑歪绳子"）
- **emergent reaction**（LLM 现场生成 reaction）—— 反应是物理常数，**禁止**
- **Reaction.effect_script**（Lua 逃生口）—— 同上，禁止
- **混合材质规则**（rope 用 3 种纤维拧，输出材质怎么决定）—— 暂取第 0 槽

### v3 新加的 Phase

### Phase 7：容器型 passive（与 Phase 6 平行或之后）
22. 容器实例 + `container_id` 字段（inventory 的 store / take inventory action）
23. dispatcher 维护"实例 → 所在容器"反向索引
24. dispatcher 维护"实例计时器"（key=(instance_id, reaction_id)）
25. `@inside_container_tags` 匹配 + `duration_required` 触发
26. 多输入 passive 的同容器成对匹配
27. 第 2 批 6 条容器型 passive 反应（cheese / salt / tan / germinate / brew_ferment / sour_milk）

### Phase 8：耐久度 + 维修
28. item.properties 加 durability / max_durability
29. 使用代码（攻击 / 挖矿等 handler）扣耐久 + 加 broken tag
30. 重锻 reaction（active modify，按 max_durability 递减）
31. 修理包配方 + 野外维修 reaction

### Phase 9：v4 新增（Batch 2 魔法落地）
32. `materials.body.category_any` OR 匹配（同 shape_type_any 模式）
33. Material 加 `hazards` 字段 + dispatcher 失败 handler 的 hazard → effect 表
34. 表达式 parser 扩展到 Material.use_effects 字段（`@self` 指当前物品实例）
35. Material 字段开放原则：去掉"必须列出"约束，dispatcher 通过表达式按需读
36. 魔杖 charges 系统（wand_charges / max_wand_charges 字段约定 + depleted tag）
37. 第 2 批魔法 ~10 条 reaction（草药 / 药水 / 魔杖 / 信件 / 月光石）+ 配套新 buff（pepperup / warmth / regen / poisoned）

---

## 12. 100 物品实验（schema 验证）

**做法**：在动手实现前，先用 markdown 写 100 个具体物品的反应规则草稿，逐条核对 schema 是否覆盖。

输出物到 [`docs/architecture/100-item-experiment.md`](./100-item-experiment.md)，包含：

- 列表：100 个物品（覆盖 base-items.md + 涌现组合 + 烹饪 + 加工）
- 每件：写出对应 reaction(s) 的伪 .tres
- 标记：哪些字段 schema 没覆盖、哪些操作符不够用、哪些 verb 策略缺
- 修订：发现缺口 → 回头改本文

**目标**：跑完 100 件后，schema 不再有大改动，可以放心落地代码。

**进度**：
- ✅ 第 1 批 19 件（v2 已落 12 个缺口）
- ✅ 第 2 批普通 15 件 + 维修系统（v3 已落 7 个缺口 + 5 个设计决策）
- ✅ 第 2 批魔法 12 件（v4 已落 4 个缺口 + 7 个设计决策；砍 3 件：魔杖充能、大锅、巧克力蛙）
- ⏳ 第 3 批 50 件

**MVP 已确认的 verb 集**：fire, shape, hammer, grind, carve, combine, mix, bake, fry, stew, boil, butcher, churn, spin, weave, repair, cure, ferment, germinate, tan, brew, soak, moon_charge

**第 3 批可能新增**：polish, stitch, sculpt, enchant, engrave, chisel, distill

**遵循的 design rule**：制造链层数 ≤ 3（金属类 ≤ 4），见 [memory: project_crafting_max_layers]。

**燃料统一**（已落地，2026-05-25）：唯一燃料是 `charcoal`（木 → 炭循环），原 `coal` substance/item 已删除；炭窑通过 `kiln_burn` 把 wood log 烧成 charcoal x4。

---

## 13. Open questions

- **mastery 增长机制**：每次 +X？按结果分级（次品 +0.001 / 优 +0.005 / 极品 +0.02）？需要 cap 防止刷？归 progression 设计
- **NPC mastery**：NPC 也有 per-verb mastery 还是统一职业系数？(铁匠 = shape 1.3 + fire 1.4 + sharpen 1.5)
- **跨实例属性继承（自动）**：表达式（§4.5b）解决了"显式继承"——但要不要"默认所有实例属性继承"？目前要每条反应在 generate.properties 里手动写公式
- **被动 tick 的性能**：5 游戏分钟扫一次全表是 OK，但 100 物品 × 50 reaction 后要按"反应主属性"建索引（如 cool 反应只看含 temperature 的物品）
- **保存格式**：实例 properties 的 dict 怎么稳定序列化？key/value 类型受限吗？
- **跨工作站接力**：玩家把烧红的铁从 forge 拿到 anvil 这条流程——背包里也要走 passive cooling，否则物理不一致（已倾向"是的，背包内也算在场"）
- **环境常量管理**：dispatcher 知道 `temperature → ambient=25` 的 hardcode 表，怎么扩展（季节、邻近热源）？暂时全 hardcode，未来可能搞 Environment autoload
- **同 input 不同材质合成**：rope 用 3 种纤维，输出 body 取第 0 槽——什么时候需要"加权混合"或"取最差"规则？
- **多匹配 UI**：sub_option 解决了"同输入想做不同东西"，但如果两条反应都满足同一组输入 + 同一 sub_option（罕见），UI 怎么处理？目前靠 constraint_count 自动选，要不要让玩家见到选项？

---

## 修订记录

- 2026-05-08 (v4)：第 2 批魔法 12 件实验后回填 4 个缺口 + 7 个设计决策：
  1. `inputs[i].materials.body.category_any` **新增**（与 shape_type_any 同 OR 模式；通用规则：任何等值字段都能加 `_any` 后缀）
  2. `Material.hazards: PackedStringArray` **新增**（标记易燃 / 易爆 / 毒 / 腐蚀；§7.3b 失败语义）
  3. **§4.5b 表达式扩展到 Material.use_effects**（`@self.quality` 等，§10.1 例子更新）
  4. **Material 字段开放原则** 写入 §2.1（不再要求字段集枚举，dispatcher 通过表达式按需读，例：wand_charges_capacity / coating_buff / alchemy_potency）
  5. **§7.3b 失败行为受输入 hazards 影响** 新增（dispatcher 失败 handler 维护 hazard → effect 表）
  6. **§7.4b 魔杖 charges + depleted** 新增（独立于 durability/broken；杖芯材质决定容量；不可修复，用完即弃）
  7. **环境前提走容器 tag** 设计决策（moon_drying / drying_rack / aging_vessel；YAGNI 真正的环境匹配字段）
  8. **写入 / 存取 / 阅读 = inventory action** 设计决策（writable / readable / aging_vessel tag 标记物品能力）
  9. **工作台不制造** 设计决策（schema §10 文件结构里 workstation .tres 标注为预放）
  10. **§11 加 Phase 9**（v4 实现项）
  11. **新 verb 加入清单**：brew / soak / moon_charge（cast 砍掉，因 cauldron 不制造 + 巧克力蛙砍掉，无 use case 暂留 placeholder）
  12. YAGNI 列表更新：catalyst（input consumed:false）确认 YAGNI（巧克力蛙砍后无 use case）；optional inputs / 可选 input 仍 YAGNI
- 2026-05-07 (v3)：第 2 批普通 15 件 + 维修系统实验后回填 7 个缺口 + 5 个设计决策：
  1. `inputs[i].@inside_container_tags` **新增**（passive 反应通过容器 tag 匹配实例）
  2. `inputs[i].shape_type_any` **新增**（与 tags_any 平行的 OR 匹配）
  3. **§4.5b 表达式适用范围扩展**：明确 generate 内任何字段（shape_type / qty / materials / properties）都允许 @input 表达式（不再只限 properties）
  4. `Reaction.duration_required: float` **新增**（passive 累计时间型变身，区别于 delta_properties 速率）
  5. **多输入 passive 同容器成对匹配规则** 写入 §8.2b
  6. **dispatcher 实例计时器** 设计（key=(instance_id, reaction_id)，独立 dict，不存 instance.properties）写入 §8.2b
  7. **§7.4 耐久度 + 破损 + 维修系统** 新增（durability/max_durability 字段约定 + broken tag + 重锻 / 修理包 reaction）
  8. **容器存取语义** 写入 §4.4b（store / take 是 inventory action 不是 reaction，inventory entry 加 container_id）
  9. **aging_vessel tag** 统一所有时间型 passive 容器（木桶 / 大缸 / 腌缸通用）
  10. **重锻递减上限**：每次 max_durability -30，三次报废
  11. **修理包按材质 category 跨输入引用** 模式确立
  12. **燃料统一 charcoal**（已落地 2026-05-25）：删除 `coal` substance/item，charcoal 由 `kiln_burn` 反应在炭窑从 wood 烧出
  附加：§11 加 Phase 7（容器型 passive）+ Phase 8（耐久 / 维修）；YAGNI 列表更新（catalyst / 可选 input / passive 进度持久化 / swap_part 全确认 YAGNI）；§10 文件结构补 v3 verb / workstation
- 2026-05-07 (v2)：第 1 批 19 件实验后回填 12 个改动：
  1. `Verb.material_strategy` / `Verb.quality_strategy` **删除**（搬到 Reaction）
  2. `Reaction.material_strategy` / `Reaction.quality_strategy` **新增**
  3. `Verb.sub_options: Dictionary` **新增**（同输入不同意图的歧义解决）
  4. `Reaction.sub_option: String` **新增**
  5. `Reaction.primary_input_indices: PackedInt32Array` **新增**（transform / alloy 多输入主料标记）
  6. `failure_modes.consume_parts` / `return_parts` 改为 `consume_inputs` / `return_inputs`（按 input 索引）
  7. `inputs[i].repeat: int` **新增**（同 input 多槽简写）
  8. **新增 §4.5b 表达式语法**（@input + 算术 + min/max/clamp）
  9. `generate.materials` 显式 override 明确说支持（mix 必须）
  10. `Reaction.tick_interval` **删除**（dispatcher 自己管，反应只声明物理速率）
  11. `delta_properties` 单位改为"每游戏分钟"
  12. `clamp_properties` **不引入**（环境常量由 dispatcher 全局管）
  附加：增加"workstation 与 verb 关系"一节、§10.1 食物属性挂 Material、§11 加 Phase 6 sub_options UI、YAGNI 列表显式禁止 LLM 生成 reaction
- 2026-05-07 (v1)：初版。基于和用户的 13 个决策点 + 加热 / 锻打例子收敛。
