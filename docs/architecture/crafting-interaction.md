# Crafting & interaction layer

> Status: **drafting** — 仅设计稿，尚无代码。本文回答"玩家怎么触发反应"，是 [simulation-layer.md §2.2 反应规则三层](./simulation-layer.md#22-反应规则三层emergence--配方) 的输入侧补完。

## 1. Context

[simulation-layer.md §2.2-2.3](./simulation-layer.md#22-反应规则三层emergence--配方) 已经定了**无 recipe**：物理引擎只有 substance + reaction 表，"配方"活在 NPC 自然语言知识里。但**没说玩家怎么触发反应** —— 是在 3D 世界里 contextual aim（瞄铁砧、对位锤击）？还是打开某种 UI 选？

设计时面对的关键张力：

- **涌现 vs 配方书 UI**：Minecraft 3×3 格 / Stardew 制造菜单都把可能性穷举给玩家，玩家进入"翻菜单挑配方"心态，emergent 立刻退化。但完全不给 UI 又意味着玩家不知道能做什么
- **3D contextual 操作的真实代价**：TotK Fuse / Noita 之所以可玩，是 200 人团队 + 多年 polish。我们没那个预算，硬做 3D 精确交互（瞄准、对位、力度）操作感会烂
- **NPC 也要能制造**：[design-doc §3](../design-doc.md) 要求 NPC 真劳作。NPC 走 action → 反应表的链路天然不需要 UI；玩家用 UI 触发的反应必须最终落到**同一张反应表**，否则 NPC 和玩家产出不一致
- **视觉资产有限**（[design-doc §9](../design-doc.md)）：30-50 base mesh + tint + modifier。组装出来的复合物没有专属 mesh，得 fallback 到组件拼接或最近 base

## 2. Design

### 2.1 动词系统：反应表的查询键不是物品

把"制造"拆成一组**动词**，每个动词是反应表的一个查询入口。

| 动词 | 操作语义 | 触发处 | 反应表读什么 |
|---|---|---|---|
| **swing** | 手持工具朝世界目标挥动 | 鼠标 / 玩家输入 | tool.properties + target.substance |
| **strike** | 工具 + 静止目标（如铁砧上的热铁）| 工作站 UI | tool.properties + target.properties + mold.shape |
| **place** | 把物品放进容器 / 放到平面 / 放到火上 | 拖拽 / E 键 | container.properties |
| **combine** | 多件物品物理拼接 | 工作站 UI | parts[].properties + binding.properties |
| **heat / cool** | 环境改变物品温度 | place 的特化 | substance + env.temperature |

[simulation-layer.md §2.2](./simulation-layer.md#22-反应规则三层emergence--配方) 原本的反应是 `(substance, condition) → effect`（被动反应，verb 隐式 = passive）。本层把它升维成：

```
(verb, actor_properties, target_properties..., env) → effect
```

老的 `wood + temp > 300 → ignite` 仍然成立，是 `verb=passive, target=wood, env.temp > 300` 的特例。

**关键不变量**：反应表按属性束匹配，**永远不按 item_id 匹配**。"挥任意硬扁刃工具到任意软土" 是一条规则，覆盖铁铲 / 铜铲 / 长柄锅 / 木板的笛卡尔积。

### 2.2 工作站 + 万能 UI 模式

不做 contextual 3D 精确交互，也不做 recipe 选择菜单。中间方案：

- **工作站**（Workstation）= 世界里的 `Node3D`，玩家走近显示 prompt（"按 E 打开"）
- **万能 ActionPanel** = 一个 Control 复用所有工作站，UI 结构：
  - 标题：当前动词（"锻打" / "组装" / "烹饪"）
  - N 个槽位（动词决定槽数）
  - 执行按钮

```
┌─ 组装台 ────────────────────────────┐
│  零件 A: [ 拖入任意刚体 ]           │
│  零件 B: [ 拖入任意刚体 ]           │
│  绑定:   [ 拖入任意绳/铆钉/胶 ]    │
│                                     │
│         [ 组装 ]                     │
│                                     │
│  预览: ?                            │
└─────────────────────────────────────┘
```

**关键不变量**：槽位**不限定 item_id 类型**。槽位语义只到属性级（"任意刚体" / "任意绳"），具体能不能产出由反应表 / LLM 判定。这是它和 Minecraft 3×3 格的本质差别 —— 后者把"哪两件出什么"暴露在 UI 上，前者只暴露动词，结果靠引擎涌现。

### 2.3 三种 fallback 顺序

玩家点"执行"后，dispatcher 按顺序找匹配：

1. **反应表精确属性匹配** → 出预设 effect（设计师写的 .tres）
2. **反应表"族"匹配** → 通用 effect（"任意硬刃 + 任意软材 + 任意绳" → 复合工具，属性继承自零件）
3. **LLM 现场判** → 给一个 effect 或拒绝（"苹果绑不住，组装失败"）

后期 LLM 判定的成功结果可以**回写成新的反应表条目**（设计师审过的话），让常见组合下次走快路径。这是 [simulation-layer.md §2.3](./simulation-layer.md#23-recipe-退化为-npc-自然语言知识) 说"recipe 活在 NPC 知识里"的程序化对应物。

### 2.4 Item 两层结构：属性束 + 视觉

`Item` resource ([src/sim/items/item.gd](../../src/sim/items/item.gd)) 加两组字段，物理层和视觉层**互不读**：

```gdscript
# === 物理属性束（反应表读这个，不读 id）===
@export var properties: Dictionary = {}
# 例：{ "shape": "flat_blade", "hardness": "iron", "blade_area": 0.1, "handle": "long_shaft" }

# === 视觉表达层（UI/世界渲染读这个）===
@export var icon: Texture2D                        # 背包/UI；空 = 退化哈希色块
@export var world_mesh: PackedScene                # 掉地/装备的 3D 视觉
@export var tint: Color = Color(1, 1, 1, 1)        # 同 mesh 不同材质
@export var visual_modifiers: PackedStringArray = []  # ["fire_aura", "frost_glow"]
```

**对接 [design-doc §9](../design-doc.md)**：30-50 个 base mesh + tint 覆盖大部分物品。同一 mesh 不同硬度只换 tint（铁灰 / 铜橙 / 金黄）。涌现的奇异物 LLM 选最近 base + 修饰符。

**视觉对接 combine 输出**有三种策略，第一版选 A：

| 策略 | 做法 | 何时用 |
|---|---|---|
| A. **映射表 fallback** | 复合物按属性束查最近 base mesh | MVP，最省 |
| B. **组件拼接** | mesh 由零件 mesh 在 attachment point 拼出 | 后期，对应 §2.1 combine 的物理结构 |
| C. **base + modifier 叠加** | 最近 mesh + LLM 选粒子/光晕/tint | 应急表达"这不是普通的" |

### 2.5 工作站清单（按动词分，不按物品分）

| 工作站 | 默认动词 | 槽位语义 |
|---|---|---|
| 🔧 **工作台** | combine | 零件 A + 零件 B + 绑定（也兼基础切削，knife + wood + 模具）|
| 🔨 **铁砧** | strike | 软金属 + 模具（手持锤是必要条件）|
| 🔥 **熔炉** | smelt | 矿石 + 燃料 |
| 🌾 **磨坊** | grind | 谷物（自动磨，水/畜力驱动）|
| 🍲 **灶** | cook | 容器（锅/盘）+ 食材 × N + 调味 |

5 个工作站覆盖 MVP 全部制造。**不是 5 类 = 5 套代码** —— 共享同一套 ActionPanel，只是动词标签和槽位 schema 不同。加新工作站 = 新 Node3D + 一段配置。

工作站归属：MVP 阶段铁砧/熔炉/磨坊/灶都是**镇上 NPC 拥有的公共设施**（白天营业时玩家可用，可能要小费）；工作台默认在玩家家里。后期玩家可花钱在自家造私人工作站，提升离线产出和便利性。

### 2.6 Recipe = 已知反应的快捷调用

[§2.3](#23-三种-fallback-顺序) 说反应表是引擎，但每次都让玩家手动拖三件物品进 ActionPanel 槽位是不必要的劳累。Recipe **不重新引入 gating**，只是已知反应的**记忆化调用**。

| | Recipe 作为 gating（要避开）| Recipe 作为快捷键（这套用的）|
|---|---|---|
| 反应表的角色 | 不存在 | 永远是引擎；recipe 只是触发的捷径 |
| 解锁方式 | 看书 / 升级树解锁 | 玩家自己组合成功一次 → 自动记住；NPC 教 |
| 没 recipe 能做吗 | ❌ 菜单里没有就做不了 | ✅ 把材料拖进去走原始路径 |
| Emergent 还在吗 | ❌ 死了 | ✅ 完整保留 |
| 消耗 | 设计师写死 | 反应表说要啥就要啥（始终一致）|

**实现**：`Recipe` 是 `{verb, slot_assignments: [item_id...], workstation}` 的快照。玩家 ActionPanel 一侧有"已知配方"列表，点 → 自动从背包抓物品填进槽位 + 点执行。**没有平行数据路径** —— dispatcher 仍然查反应表，recipe 只是 UI 自动化。

**保证**：

- 反应表规则改了 → 所有 recipe 自动跟进
- 玩家用 recipe 和手动组合产出**完全一致**
- "老铁匠死了配方失传"仍然成立 —— recipe 是个人记忆集合，不是世界知识

**学习时机**：

- 玩家成功执行一次某 verb + slot 组合 → 自动加进个人 recipe book
- NPC 在对话里教 → "我教你做铁铲：要 1 铁刃 + 1 木杆 + 1 绳" → 自动加
- 拾取笔记 / 食谱书 → 加（可能错误，玩家执行时反应表会拒）

### 2.7 经济闭环：资源节点是唯一来源

跟 [simulation-layer.md §1](./simulation-layer.md#1-context) 的"NPC 必须真劳作"原则呼应：**世界里 item 的源头永远是资源节点 + 实际劳动**。NPC 商人不是凭空生成库存的自动售货机。

每件 [base-items.md](./base-items.md) 的层 A 原料都得满足：

1. 至少一种**资源节点**存在于世界（tree / iron_vein / wheat_field / chicken_coop ...）
2. 至少一种**对应 NPC 职业**会去采集（樵夫 / 矿工 / 农夫 / 猎人）
3. NPC 把采集物拉回市集售卖，**库存有限**，按 NPC 实际产出补充

加工件 / 成品同理：铁匠卖 iron_blade 是因为他买了矿工的 ore + charcoal 自己做出来的。链条任意一环 NPC 死了 / 罢工，整条供给受影响。

**玩家三种供给路径**（每件物品都至少有前两种）：

| 路径 | 成本 | 限制 |
|---|---|---|
| 自己去节点采 | 时间 + 工具消耗 | 节点刷新速率 |
| 市集买 | 金钱 | NPC 总产能、营业时间、库存 |
| 自己加工 | 时间 + 工作站 + 上游材料 | 上游材料供给 |

这套结构让镇里**经济节奏天然由资源节点参数 + NPC 数量决定**，设计师调一棵树多久长一次、镇里有几个樵夫，就调出了节奏。玩家行为也是经济变量 —— 砍多卖多 → 木材便宜；买空市场 → 别的 NPC 没料做事。

具体每个职业 → item 对应、节点参数草稿见 [base-items.md](./base-items.md)。

## 3. End-to-end 例子：铁铲（中世纪小镇起点）

中世纪起点：玩家是新移民，开局有 iron_knife + 一些铜币。镇上铁匠 / 樵夫 / 矿工已在工作。完整数据流：

| 步骤 | 玩家操作 | 触发 | 反应表查询 | 产出 |
|---|---|---|---|---|
| 0. 起步 | 开局 | — | — | iron_knife × 1, bread × 3, 50 铜 |
| 1. 砍木 | 走到林子，手持市集买的 iron_axe，对树左键 | swing | `swing + axe.shape=cleaving + target=tree` | wood × N |
| 2. 切杆 | 回家工作台，放 wood + 选模具"long_shaft"，手持 knife | strike | `strike + knife + wood + mold=long_shaft` | wood_shaft |
| 3. 攒铁刃 | 矿工太贵，自己去矿洞用 iron_pick 挖 → 拿到铁匠铺熔炉 + 铁砧（付小费）| smelt + strike | 见 [base-items.md](./base-items.md) §2 | iron_blade |
| 4. 买绳 | 市集买 rope（绳商从农夫处收 fiber 自己搓的）| 经济 | — | rope × 1 |
| 5. 组装 | 回家工作台，放 iron_blade + wood_shaft + rope，点"组装" | combine | `combine + flat_blade + long_shaft + binding` | **iron_shovel** + 自动入个人 recipe book |
| 6. 装备 | 背包里右键"使用" | equip | — | 角色手上挂 iron_shovel.world_mesh |
| 7. 用铲子 | 对软土左键 | swing | `swing + tool.shape=flat_blade + target=soil` | dirt × N，地块出现坑 |
| 8. 第二把 | 想再做一把送朋友 | recipe 快捷键 | — | 点 recipe → 自动抓材料 → combine 同一条路径 |

**全程没有 recipe 表作为 gating**。每一步都是 `(verb, properties...)` → 反应表 → effect。第 8 步的 recipe 只是第 5 步的快捷键，跑同一条路径。NPC 走 action 路径执行同一组动词、查同一张反应表，产出和玩家一致。

**经济触点**：步骤 1、3、4 都是"自己干 vs 买"的选择 —— 反映 [§2.7](#27-经济闭环资源节点是唯一来源) 的三路径权衡。

## 4. Open questions

- **槽数动态化**：组装台 2 件 + 1 绑定，但玩家想拼 3 件怎么办？固定 N 槽 vs 动态 +/- 按钮
- **视觉策略落地**：第一版用 A（映射 fallback），但 attachment point 系统（B 方案）何时引入。武器装备到角色手上目前还没系统
- **LLM fallback 在哪跑**：本地沙箱（[scripting-layer.md](./scripting-layer.md)）还是后端 worker？延迟和体验权衡待定
- **NPC 是否经过工作站 UI**：NPC 应该跳过 UI 直接 action→反应表。但"NPC 在铁砧前锻打"的动画/位置占用怎么和玩家共存
- **回写反应表**：LLM 判定成功的 emergent 组合要不要自动沉淀成 .tres？沉淀谁审？
- **失败反馈**："苹果绑不住"这种失败要不要给玩家清晰提示？是 LLM 的自然语言还是预设错误码

## 5. Implementation status

全部设计稿，未实现。代码上的下一批（按依赖排序，对应任务列表）：

1. `Item` resource 扩 `properties` + 视觉字段（[§2.4](#24-item-两层结构属性束--视觉)）
2. `inventory_slot.gd` 支持真 icon + tint，fallback 哈希色块
3. `Workstation` 基类（Node3D，靠近 prompt + E 触发）
4. `ActionPanel` 万能 UI（标题 + N 槽位 + 执行）
5. 组装台 + 端到端铁铲（用 §3 第 5 步那条 combine 反应跑通）
6. 反应表 dispatcher 的 verb 维度扩展（属于 simulation-layer 的工作）

`Recipe`（[§2.6](#26-recipe--已知反应的快捷调用)）和经济闭环（[§2.7](#27-经济闭环资源节点是唯一来源)）暂时不在第一批 —— 第一批跑通后再上：
- recipe book UI + 自动填槽
- NPC 商人 stock + 营业时间 + 资源节点 spawn

完整 item 清单和职业 → 节点对应见 [base-items.md](./base-items.md)。铁砧 / 熔炉 / 磨坊 / 灶按工作站基类同模板复制，每个新增大约 1 个 .tres + 几行配置。
