# Crafting & interaction layer

> Status: **implemented**。本文描述玩家/NPC 怎么触发反应、工作台 staging 怎么投料与取回，是 [simulation-layer.md §2.2 反应规则三层](./simulation-layer.md#22-反应规则三层emergence--配方) 的输入侧补完。数值/配方清单见 [game-mechanics.md §7-8](./game-mechanics.md)，反应表格式见 [reaction-schema.md](./reaction-schema.md)。

## 1. Context

物理引擎只有 substance + reaction 表，没有 recipe gating（[simulation-layer.md §2.2-2.3](./simulation-layer.md#22-反应规则三层emergence--配方)）。本层回答"玩家怎么触发反应"：不做 3D 精确交互（瞄准/对位），也不做配方选择菜单，而是**工作站 + 万能 ActionPanel + 动词按钮**。NPC 跳过 UI，直接走 action → **同一张反应表**，保证产出一致。

## 2. Design

### 2.1 动词系统：反应表的查询键不是物品

"制造"拆成一组**动词**（`src/sim/verbs/verb.gd` + `data/i18n/<locale>/verbs.json`），每个动词是反应表的一个查询入口，可带 **sub_option**（同一动词的具体产物分支）。当前动词：

| 动词 | sub_options | 动词 | sub_options |
|---|---|---|---|
| `chop` 砍木 | — | `carve` 雕刻 | plank / shaft |
| `shape` 锻造 | blade / axe_head / pick_head | `combine` 组装 | knife / axe / pick / shovel / sickle / rope |
| `hammer` 锤击 | — | `grind` 研磨 | — |
| `mix` 混合 | — | `bake` 烘烤 | — |
| `boil` 熬煮 | — | `fire` 烧制 | — |
| `dig` 采矿 | — | `dry` 晾晒 | save_seed |
| `mint` 铸币 | — | | |

被动反应（晾晒/发酵）的 verb 隐式 = passive。本层把反应升维成 `(verb, sub_option, 输入属性束, 工作站, 熟练度) → effect`。

**关键不变量**：反应表按属性束（`shape_type` / `materials` / `tags`）匹配，**永远不按 item_id**。"挥任意硬扁刃工具到任意软土" 是一条规则，覆盖铁铲/铜铲/木板的笛卡尔积。

### 2.2 工作站 + 万能 ActionPanel

- **工作站** = 世界里的 `WorkstationNode`（`src/sim/workstations/`）。鼠标悬停 + `E` 由 `InteractionController`（`src/ui/hud/interaction_controller.gd`）路由：普通工作台 → `ActionPanel`；容器（仓库/货架）→ `ContainerPanel`；水井（无限液体源）→ 取水面板。三者互斥。
- **Workstation 资源**（`data/workstations/*.tres`，`src/sim/workstations/workstation.gd`）：`workstation_id` / `display_name` / `verbs`（动词列表）/ `slot_count`（输入槽数）。
- **万能 ActionPanel**（`src/ui/action_panel/action_panel.gd`，所有工作站共用）：N 个 staging 槽（= `slot_count`）+ 从 `verbs` 生成的动词按钮（有 sub_option 的展开成多个按钮）+ 进度条。点动词按钮 = `request_craft`。

```
┌─ 工作台 ────────────────────────────┐
│  [槽1] [槽2] [槽3] [槽4] [槽5]      │   ← 从背包拖物品来此（staging）
│  组装: [刀][斧][镐][铲][镰][绳]    │   ← 动词按钮（sub_option 展开）
│  雕刻: [木板][木杆]                 │
└─────────────────────────────────────┘
```

**关键不变量**：槽位**不限定 item_id**，能不能产出由反应表判定。这是它和 Minecraft 配方格的本质差别——只暴露动词，结果靠引擎涌现。工作站清单与槽数见 [game-mechanics.md §8](./game-mechanics.md)。

### 2.3 dispatcher：反应表匹配

点动词按钮 → `Crafting.resolve(verb, ws_id, sub_option, inputs, proficiency, work_impair)`（`src/sim/crafting/crafting.gd` → `data/mechanics/crafting.lua` 的 `on_resolve` hook）。匹配顺序：

1. **反应表精确属性匹配** → 预设 effect（设计师写的 lua 规则）
2. **反应表"族"匹配** → 通用 effect（"任意硬刃 + 任意软材 + 任意绑定" → 复合工具，属性继承自零件）
3. 都不中 → `no_match`，弹失败文案

返回 `{outcome(match/failure/no_match), 输出, consumed_input_indices, duration, message...}`。

**LLM 只读不写**：LLM 能为 NPC 翻译意图 / 选反应，但**永远不生成新反应**，也没有"LLM 现场判 + 回写反应表"那条路径（反应是设计师手写的世界物理，见 [reaction-schema.md](./reaction-schema.md) 与记忆 `reactions_are_physics`）。

### 2.4 Item 两层结构：属性束 + 视觉

物理匹配读 item 的**涌现身份**（`shape_type` / `materials` / `tags`），**不读 item_id**；UI/世界渲染读视觉层（`icon` / `tint` / `world_mesh`，空 icon 退化哈希色块）。两层互不读。

item 状态分三层（详见 [reaction-schema.md](./reaction-schema.md) / [game-mechanics.md §6](./game-mechanics.md)）：

| 层 | 内容 | 存哪 |
|---|---|---|
| 模板 | id / kind / stackable / weight / 静态 `properties`（如容器容量）/ lua 行为源 | `src/sim/items/item.gd` `.tres` |
| 反应涌现身份 | shape_type / materials / tags | inventory 槽位 |
| 可变 aspect | 容器量(`container_amount`/`content`) / 鲜度 / 耐久 / 效果 | inventory 槽位（typed 平铺列，**不用 customProperties bag**）|

### 2.5 工作站清单

按动词分、不按物品分；所有工作站共享同一套 ActionPanel，只是动词标签和槽数不同。加新工作站 = 新 `.tres` + 一个 `WorkstationNode`。完整清单（工作台/熔炉/铁砧/灶台/磨坊/盐锅/矿井…）、槽数、配方表见 [game-mechanics.md §8](./game-mechanics.md)。归属：铁砧/熔炉/磨坊/灶是镇上 NPC 公共设施，工作台默认在玩家家里。

### 2.6 Staging：投料、取回与原路退回

工作台投料是**服务端权威的物理搬运**：Player 持权威 `staged_items`（`STAGED_SLOT_COUNT` 槽），经 MultiplayerSynchronizer 推回 owner client；client 只显示 + 提交意图（`request_stage_to_workstation` / `request_unstage_*` / `request_clear_staging`）。

**统一交互约定**（背包 ↔ 工作台 ↔ 仓库 共用一套**分离面板** `src/ui/split/split_panel.gd`，单位随类型变：液体=升、离散=份数，粉末=克留接口）：

- **拖拽 = 全量**（拖整堆 / 倒满桶的全部液体）；**右键 = 开分离面板选量**（液体还要选目标容器）。
- 一个 staging 槽 = 一个反应输入实例。液体在槽里以"液体单位"存在（`1` 单位 = `1` 升）：拖/倒桶时**从原桶扣量**（写平铺列 `container_amount`，桶留背包），合成一个 fluid_pouch 占槽。

**原路退回**（关面板 / 取回 / 制造中途取消 → `_return_staged_slot`）：每个 staging 槽记住背包**原槽地址**（`origin_slot`，液体另记 `pour_content`），统一退回——

- **液体** → 精确倒回**原桶**（防止稀释不同品质的酒）；右键液体槽也可经分离面板倒到**指定容器**（`request_unstage_liquid_to_container`）。
- **离散** → 回**原槽**；原槽放不下（被占/不可堆叠）→ 找其它可堆叠槽 → 兜底空槽。
- 放不下 / 原桶失效 → `push_error` 并把物品留在工作台，**绝不丢、绝不乱倒**（fail-loud）。

**制造结算**：点动词 → 收集非空 staging 槽为 `inputs` → `Crafting.resolve` → `duration<=0` 立即 commit，否则起进度条（按**游戏秒**计时，随时间倍率加速）到期 commit。Commit 按 `consumed_input_indices` 扣对应槽（每次 −1），输出入背包，未消耗的 staged 物关面板时原路退回。熟练度影响品质/成功率，醉酒/生病经 `work_impair` 临时压低有效熟练度；批量同料投入有品质惩罚（曲线见 [game-mechanics.md §8.4-8.6](./game-mechanics.md)）。

> Recipe 快捷调用（"已知配方"自动填槽）**未实现**：当前入口就是动词按钮 + 手动投料。即便后续加，也只是 UI 自动化，反应表始终是唯一路径，不引入 gating。

### 2.7 经济闭环：资源节点是唯一来源

跟 [simulation-layer.md §1](./simulation-layer.md#1-context) 的"NPC 必须真劳作"呼应：**世界里 item 的源头永远是资源节点 + 实际劳动**，NPC 商人不是凭空生成库存的自动售货机。每件 [base-items.md](./base-items.md) 层 A 原料都满足：① 世界里有资源节点（tree / iron_vein / wheat_field …）；② 有对应职业 NPC 去采（樵夫/矿工/农夫…）；③ NPC 把采集物拉回市集售卖、库存有限。加工件同理（铁匠卖 iron_blade 是自己买矿做的）。

**玩家三种供给路径**：自己采（时间+工具）/ 市集买（钱，受 NPC 产能与营业时间）/ 自己加工（时间+工作站+上游材料）。经济节奏由资源节点参数 + NPC 数量决定。数值见 [economy-numeric-design.md](../economy-numeric-design.md) 与 [game-mechanics.md](./game-mechanics.md)。

### 2.8 NPC 走同一引擎、不经 UI

NPC 用 `WorkstationActionRunner`（`src/sim/workstations/workstation_action_runner.gd`）：从自己背包**自动解析输入**（`_resolve_inventory_input_unit`：离散走 remove op、液体走 pour op `_apply_inventory_input_op`，与玩家 staging 同样写平铺列扣桶），再调**同一个 `Crafting.resolve`** → 同一张反应表。无 staging UI、无原路退回概念（即时解析即时消耗）。玩家与 NPC 产出一致是设计硬约束（[design-doc §3](../design-doc.md)）。

## 3. End-to-end 数据流（组装铁铲）

| 步骤 | 玩家操作 | 触发 | 反应表查询 |
|---|---|---|---|
| 切木杆 | 工作台拖入木材 → 点 `carve · 木杆` | carve(shaft) | `carve + wood + sub=shaft` → wood_shaft |
| 锻扁刃 | 熔炉熔铁锭、铁砧 `shape · 扁刃` | shape(blade) | `shape + iron + sub=blade` → iron_blade |
| 组装 | 工作台拖入 iron_blade + wood_shaft + rope → 点 `combine · 铲` | combine(shovel) | `combine + 扁刃 + 长杆 + 绑定` → iron_shovel |

全程没有 recipe 表作 gating，每步都是 `(verb, sub_option, 属性束) → 反应表 → 产出`。NPC 走同一组动词、查同一张反应表，产出一致。具体输入清单/时长/产物见 [game-mechanics.md §8.7](./game-mechanics.md)。

## 4. 关键文件

| 关注点 | 文件 |
|---|---|
| 反应数据（真值）| `data/mechanics/crafting.lua` |
| dispatcher 入口 | `src/sim/crafting/crafting.gd` |
| 动词 / 工作站资源 | `src/sim/verbs/verb.gd`、`src/sim/workstations/workstation.gd`、`data/workstations/*.tres` |
| 工作站节点 + NPC 解析 | `src/sim/workstations/workstation_node.gd`、`workstation_action_runner.gd` |
| 玩家 staging / 制造 / 原路退回 | `src/characters/player/player.gd`（`request_stage_to_workstation` / `request_unstage_*` / `request_craft` / `_return_staged_slot`）|
| ActionPanel / staging 槽 | `src/ui/action_panel/action_panel.gd`、`action_slot.gd` |
| 统一分离面板 | `src/ui/split/split_panel.gd` |
| E 路由 | `src/ui/hud/interaction_controller.gd` |
