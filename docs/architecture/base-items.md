# Base items（MVP 物品清单）

> Status: **drafting** — 仅设计稿，尚无 .tres。本文锁定 MVP 第一批 item / 反应规则 / NPC 职业链。框架机制见 [crafting-interaction.md](./crafting-interaction.md)。

## 1. Scope

中世纪小镇起点（**不**走原始时代刀耕火种）。MVP 目标：完整跑通"采集 → 加工 → 组装 → 使用 / 食用"四类动词链。

**总量**：29 件 item + 5 个工作站 + 5 个 NPC 职业链。

**不在 MVP 内**（后续补）：奶酪 / 啤酒 / 鱼类 / 皮革 / 羊毛 / wand / 药剂 / 装备护甲。武器只做工具的子集（knife / axe / hammer 兼武器）。

每件 item 都得有"能造"的路径 —— 见 [crafting-interaction.md §2.7](./crafting-interaction.md#27-经济闭环资源节点是唯一来源)：世界资源节点是唯一真实来源，NPC 商人卖的也来自实际劳动。

## 2. 物品清单（按层）

### 层 A · 原料（11 件）

世界资源节点是唯一真实来源。玩家自采 or 买 NPC 采集的库存。

| id | 资源节点 | 自采工具 | 节点行为 | NPC 职业 |
|---|---|---|---|---|
| `wood` | tree | iron_axe / stone_axe | 砍倒后 wood × 3-5；几 game-day 后林子里再生 sapling | 樵夫 |
| `stone` | rock_outcrop | iron_pick | 几次后耗尽，节点消失；按区块定期重刷 | 自采 / 暂无固定 NPC |
| `iron_ore` | iron_vein | iron_pick | 矿脉若干次后空，按矿洞慢刷 | 矿工 |
| `charcoal` | — | — | 不是原料，由烧炭人在炭窑把 wood `burn` 出来（见 §燃料） | 烧炭人 |
| `wheat` | wheat_field | sickle | 田块季节性产出，收割后需重种（农夫负责）| 农夫 |
| `tomato` | tomato_plant | 徒手 | 已有的 crop 系统，结果熟即可摘 | 农夫 |
| `berry` | berry_bush | 徒手 | 野生灌木，季节性挂果 | 采集者（樵夫兼）|
| `fiber` | flax_plant | 徒手 / sickle | 田块种植 | 农夫 |
| `raw_meat` | wild_animal / livestock | weapon | 猎杀 / 屠宰；livestock 由农夫圈养 | 猎人 / 屠夫 |
| `egg` | chicken_coop | 徒手 | 鸡舍每 game-day 产 1-3 枚 | 农夫 |
| `water` | well | bucket | 公共水井无限 | 自取 |

**水**单列（公共资源，零成本）。**raw_meat** MVP 里先简化 —— 先只能从屠夫买，hunt 机制和 wild_animal 实体后期再上。

### 层 B · 加工件（8 件）

需要工作站。

| id | 反应规则（草稿）| 工作站 | 动词 |
|---|---|---|---|
| `iron_ingot` | `smelt + iron_ore × 1 + charcoal × 1 → iron_ingot × 1` | 熔炉 | smelt |
| `iron_blade` | `strike + hammer.hard + iron_ingot + mold=flat_blade → iron_blade` | 铁砧 | strike |
| `iron_pick_head` | `strike + hammer.hard + iron_ingot + mold=pick_head → iron_pick_head` | 铁砧 | strike |
| `iron_axe_head` | `strike + hammer.hard + iron_ingot + mold=axe_head → iron_axe_head` | 铁砧 | strike |
| `wood_shaft` | `strike + knife.sharp + wood + mold=long_shaft → wood_shaft` | 工作台 | strike |
| `wood_plank` | `strike + knife.sharp + wood + mold=flat_plank → wood_plank` | 工作台 | strike |
| `flour` | `grind + wheat × 1 → flour × 1` | 磨坊 | grind |
| `rope` | `combine + fiber × 3 → rope × 1` | 工作台 | combine |

**模具**（mold）是 ActionPanel 的 dropdown 槽位，**不是 item**。玩家学过的形状才能选。

**燃料**统一为 `charcoal`（substance.category=`fuel`、tag=`fuel`）。`wood` 自身不带 `fuel` tag，必须先经炭窑 `burn` 出 charcoal 才能进熔炉/盐锅；这是世界里唯一的燃料路径。

### 层 C · 成品（10 件）

#### 工具 / 武器（5 件）

| id | 反应规则 | 工作站 |
|---|---|---|
| `iron_shovel` | `combine + iron_blade + wood_shaft + rope → iron_shovel` | 工作台 |
| `iron_pick` | `combine + iron_pick_head + wood_shaft + rope → iron_pick` | 工作台 |
| `iron_axe` | `combine + iron_axe_head + wood_shaft + rope → iron_axe` | 工作台 |
| `iron_knife` | `combine + iron_blade + wood_shaft → iron_knife`（无 rope，短小）| 工作台 |
| `sickle` | `combine + iron_blade + wood_shaft → sickle`（同 knife，模具不同？）| 工作台 |

⚠ `iron_knife` 和 `sickle` 配方歧义：相同输入不同产物。**临时方案**：combine 时也支持模具/形状参数（`mold=knife` vs `mold=sickle`）。统一到铁砧的 strike 模具机制。

#### 食物（5 件）

| id | 反应规则 | 工作站 | 食用效果（草稿）|
|---|---|---|---|
| `bread` | `cook + dough → bread` | 灶（烤）| hunger +30, stamina +5 |
| `dough` | `combine + flour + water → dough` | 工作台 | （中间品，不直接吃）|
| `veg_stew` | `cook + pot + tomato × 2 + water + salt → veg_stew` | 灶（炖）| hunger +25, hp +5 over 30s |
| `cooked_meat` | `cook + pan + raw_meat + salt → cooked_meat` | 灶（煎）| hunger +40, stamina +10 |
| `omelet` | `cook + pan + egg × 2 + salt → omelet` | 灶（煎）| hunger +20, stamina +15 |
| `berry_jam` | `cook + pot + berry × 5 + water → berry_jam` | 灶（慢炖，~10 game-min）| hp +15, sweet（mood +）|

**dough** 严格说是层 B 加工件，但和食物链耦合放这里。

⚠ `salt` 暂时**也算调味通用项**（可由"任意 substance.salty"匹配，避免单加 1 个 item）。等调味/香料系统正式做再独立。

### 容器 / 工作站（5 件）

工作站本身不进背包，是世界里的 Node3D：

| id | 怎么得到 |
|---|---|
| 工作台 `workbench` | 玩家家初始就有；额外的可去木匠处买 / 自造（combine wood × 4 + rope）|
| 铁砧 `anvil` | 镇上铁匠铺公共；自造需 iron_ingot × 4，铁匠帮做 |
| 熔炉 `forge` | 同上；自造需 stone × 8 + clay |
| 磨坊 `mill` | 公共，玩家不可造（基础设施级）|
| 灶 `stove` | 玩家家初始就有 |

`pot` / `pan` 是**便携容器** item（占背包格），不是工作站，但被灶的反应规则要求：

| id | 反应规则 |
|---|---|
| `pot` | 铁匠特殊订单（成品，不在 MVP 自造路径里）/ 商店买 |
| `pan` | 同上 |

## 3. NPC 职业 → 物品对应

[crafting-interaction.md §2.7](./crafting-interaction.md#27-经济闭环资源节点是唯一来源) 的实例化。MVP 镇上至少存在以下 NPC：

| 职业 | 节点 / 输入 | 输出 → 卖 |
|---|---|---|
| 樵夫 `lumberjack` | tree, berry_bush | wood, berry |
| 矿工 `miner` | iron_vein, rock_outcrop | iron_ore, stone |
| 烧炭人 `charcoal_burner` | 樵夫的 wood + 炭窑 | charcoal |
| 农夫 `farmer` | wheat_field, flax_plant, tomato_plant, chicken_coop, livestock_pen | wheat, fiber, tomato, egg, raw_meat（卖屠夫）|
| 猎人 `hunter` | wild_animal（后期）| raw_meat |
| 屠夫 `butcher` | 农夫的 livestock + 猎人的 wild meat | raw_meat（处理后）|
| 铁匠 `blacksmith` | 矿工的 iron_ore + charcoal | iron_ingot, iron_blade, iron_*_head, iron_knife/axe/pick/shovel; 拥有公共熔炉+铁砧 |
| 磨坊主 `miller` | 农夫的 wheat | flour; 拥有公共磨坊 |
| 面包师 `baker` | 磨坊主的 flour + well water | bread, dough; 拥有公共灶 |
| 木匠 `carpenter` | 樵夫的 wood + 农夫的 fiber | wood_shaft, wood_plank, rope, workbench |
| 杂货商 `grocer` | 二道贩子，转售各种基础品 | mixed |

**MVP 最小镇配置**：每职业 1 个 NPC = 9 个职业 NPC + 几个非职业角色（孩子、老人、酒馆老板等）。

库存模型：每 NPC 有 `inventory` + `daily_production_targets`。营业开始时按昨日产出补货，卖完即缺货。

**注意**：MVP 阶段 NPC 行为简化为"每天产出固定数量 → 自动入库存"，**不强求 NPC 真的走到节点逐次劳动**（那是 simulation-layer §2.6 的完整 NPC 行动系统的工作，独立 milestone）。

## 4. 起步与世界初始化

**玩家起步**：
- 背包：iron_knife × 1, bread × 3
- 钱：50 铜币
- 家里：1 个 workbench, 1 个 stove

**世界初始化**：
- NPC 们已在工作（铁匠铺有库存、磨坊主有 flour）—— 你来之前他们已经活在镇里
- 资源节点按 [town.tscn](../../src/levels/town.gd) 的区域配置 spawn（见 [design-doc §8](../design-doc.md)）

## 5. Open questions

- **配方歧义**：iron_knife / sickle 输入相同 → 用 mold 参数。但 mold 系统延伸到 combine 是不是过度统一？
- **盐 / 调味**：先 substance 抽象（"任意 salty"）vs 独立 item？MVP 走前者
- ~~**燃料**：wood 能不能当 charcoal 替代品？~~ 已决议：charcoal 是世界唯一燃料，wood 必须经炭窑烧成 charcoal 才能用。
- **食物 buff effect**：MVP 是否引入持续效果？（hp over time / mood）涉及扩 effect 系统
- **节点刷新参数**：每棵树多久再生、矿脉多久重刷 —— 强烈影响经济节奏，得 playtest 才能定
- **NPC 真实劳动 vs 抽象产出**：MVP 抽象（每日补货数）。何时切到真行走？（依赖 simulation-layer §2.6 落地）
- **后续扩张**：先列哪些（个人猜测优先级）：1. wand / 法术原料 2. 皮革甲胄 3. 鱼类 4. 酒类 5. 装饰建材
