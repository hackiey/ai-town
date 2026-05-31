# 经济数值计算模型

这份文档描述 `pnpm balance:economy` 使用的新版每日经济设计模型。它不是库存报表，不计算库存覆盖天数，也不假设所有生产都会自动发生。

目标是回答一个问题：按当前实际 NPC 人口，每天需要多少资源、多少工人、多少体力、多少工资，以及钱最终会集中到哪些 group。

## 1. 计算顺序

新版模型只走一条流水线，避免继续叠补丁。

```text
实际 NPC 需求
-> 食物篮子目标
-> 配方产出计划
-> 原料需求
-> 畜牧饲料和工具折旧
-> 农田/矿山/采集/设施供给
-> 工时和体力校验
-> 工资表
-> 行业现金流
-> group 财富捕获
-> 风险提示
```

这意味着同一个数字只在一个地方生成，然后被后续表复用。

## 2. 核心假设

| 参数 | 当前值 |
|---|---:|
| 规划 NPC 数 | 读取 `npcs.json` 实际人数 |
| 每人每日饱食需求 | 75 hunger |
| 全镇每日饱食需求 | `实际 NPC 数 * 75` hunger |
| 工作站每日有人值守时间 | 8 game-hours |
| 每名工人每日可用体力 | 180 stamina |
| 劳动价格锚 | 2.5 银/game-hour |
| 农田利用率 | 65% |
| 农田照料产量系数 | 80% |
| 留种/复种预留 | 作物需求的 10% |
| 农田租赁费 | 非教堂用地每格农田每周向王室交 1 银，日报表按 `taxable Farm slots / 7` 折算 |

## 3. 食物篮子

食物需求不再被面包单独吃满，而是按 hunger 占比分配。

| 食物组 | 目标占比 | 默认食物 | 目的 |
|---|---:|---|---|
| 家庭主食 | 42% | flour | 大多数住户从磨坊买面粉回家做饭 |
| 少量成品面包 | 10% | bread | 给值守、旅人、采办和临时用餐保留面包需求 |
| 家庭肉食 | 12% | raw_meat | 住户从肉铺买生肉回家烹饪 |
| 家庭蛋类 | 6% | egg | 鸡蛋是补充蛋白，不作为稳定主蛋白 |
| 蔬果 | 20% | tomato_fruit | 给农田多样化和短保质食物一个去处 |
| 保藏食品 | 10% | cured_stew | 给盐、燃料、酒馆加工一个稳定需求 |

当前 51 NPC 目标会生成大约：

| 食物 | 目标/day |
|---|---:|
| flour | 53.55 |
| bread | 12.75 |
| raw_meat | 20.86 |
| egg | 11.48 |
| tomato_fruit | 25.5 |
| cured_stew | 13.66 |

## 4. 资源来源和需求

每个目标食物会递归展开配方。主食现在主要是住户买面粉回家做饭，面包只保留少量成品需求。主食链按批量劳动计价，不能套用“单件手工艺品最低 1 银”的定价，否则面包会变成普通人吃不起的奢侈品。

例如：

```text
home meal
-> flour
-> wheat
```

畜牧不是免费产出：

| 产物 | 饲料规则 |
|---|---:|
| 1 raw_meat | 1.0 wheat |
| 1 egg | 0.3 wheat |

工具也不是免费资本：

| 工具 | 使用者 | 损耗规则 |
|---|---:|---:|
| iron_pick | 矿工 | 0.10/人/day |
| iron_shovel | 农民 | 0.05/人/day |
| sickle | 农民 | 0.03/人/day |
| iron_axe | 伐木 | 0.25/人/day，当前 3 名伐木工 |

工具折旧会反向生成铁矿、木炭、木杆、纤维、绳等需求。

沿海镇子的盐不按进口处理，默认来自本地盐场：

```text
seawater + 少量 fuel + saltworks labor -> salt
```

当前模型已接入盐锅配方：`fuel x1 -> salt x20`，盐场按下游需求制盐，不再额外凭空给固定日产盐。

木材如果没有足够建筑和维修消耗，会通过炭窑进入燃料链：

```text
wood + charcoal_kiln labor -> charcoal
```

当前模型把木材产出设为 `45 wood/day`，对应 3 名低产量伐木工，约 `15 wood/人/day`。木炭设为 `28 charcoal/day`，每 1 charcoal 消耗 `1.4 wood`（kiln_burn 实际配方是 1 log → 4 charcoal，按日预算的 wood 单位是抽象单位）。

模型不额外添加房屋维修或建筑维护来消耗木材。若木材仍然 surplus，应优先通过炭窑、贸易、降低伐木产出或新增真实木工需求解决，而不是用抽象维护成本吞掉。

## 5. 产能校验

产能现在分两层检查。

### 5.1 行业总劳动

每个行业汇总所有工作需求：

```text
required_hours = sum(recipe_actions * duration_seconds / 3600) + non_recipe_activity_hours
required_stamina = sum(recipe_actions * stamina_cost) + non_recipe_activity_stamina
```

然后和该行业的工人数量比较：

```text
available_hours = workers * 8
available_stamina = workers * 180
```

### 5.2 单个配方设施

每个配方再单独看工作站数量：

```text
time_capacity = station_count * 8h * 3600 / duration_seconds * output_qty
stamina_capacity = sector_workers * 180 / stamina_cost * output_qty
capacity = min(time_capacity, stamina_capacity)
```

这样可以区分两种问题：

| 问题 | 例子 |
|---|---|
| 有设施但工人体力不足 | 2 个 mill 够用，但 1 个磨坊工人一天只有 180 stamina |
| 有工人但设施不足 | 未来如果只剩 1 个 stove，酒馆热食会被炉灶卡住 |

## 6. 工资模型

工资现在进入同一张现金流表。

| 类型 | 当前处理 |
|---|---|
| 矿工 | 读取 `backend_action_runner.gd` 的 `claim_wages` 规则 |
| 金矿工 | gold_ore * 2 银 |
| 银矿工 | silver_ore * 1 银 |
| Magda Kerr | 读取每周 60 银，折算 8.57 银/day |
| 卫兵 | 8 人 * 18 银/day，从国库公共工资支付；4 训练场、1 大门、1 监狱、2 巡逻 |
| Tilda Sparks | 设计占位：铁匠学徒 10 银/day，由 blacksmith_shop 支付 |
| Pella Moss | 设计占位：草药/教会学徒 6 银/day，由 saint_bell_chapel 支付 |
| Niko Vale, Lysa Rowan | 家庭劳动力份额，不发现金工资 |

矿工、Magda 和守卫是已实现运行时工资规则。学徒工资是数值设计输入，后续需要写进实际工资系统。

## 7. 行业现金流

行业现金流公式：

```text
retained = revenue - materials - fixed_wages - owner_labor_draw - spoilage - tax_or_rent
capture = max(retained, 0) + fixed_wages + owner_labor_draw
```

字段含义：

| 字段 | 含义 |
|---|---|
| revenue | 行业卖出产品或国库获得矿产资产的价值 |
| materials | 从其他行业采购的净输入成本 |
| fixed_wages | 明确发给 NPC 的工资或津贴 |
| owner_labor_draw | 老板/家庭成员自己劳动的报酬，不算留存利润 |
| spoilage | 食物行业的腐烂/滞销风险成本 |
| tax_or_rent | 回收到国库或公共部门的钱 |
| retained | 行业/店铺扣完成本后留存的钱 |
| capture | 这个行业相关人群实际捕获的钱，包括工资和劳动报酬 |

不要再把行业收入直接理解成个人财富。

农业不再使用按利润抽成的比例税。`primary_agriculture` 按场景里的实际 FarmSlot 数收固定地租：非教堂用地每格农田每周 1 银，教堂用地免租；折算成每日成本进入 `tax_or_rent`，收入归 `royal_treasury`。

## 8. Group 财富捕获

group 表把钱拆成：

```text
total_capture = business_retained + owner_labor_draw + wages_received + tax_rent_received - direct_payroll_paid
```

农业不再作为一个黑箱行业，而是按 `groups.json` 里拥有的农田槽位分摊到具体 group。

当前农田 ownership 和地租来源：

| Group | Farm slots | Rent/week | Rent/day | 说明 |
|---|---:|---:|---:|---|
| greystone_farmstead | 149 | 149 银 | 21.29 银 | 最大农田 group |
| north_wall_wheat_plot | 96 | 96 银 | 13.71 银 | 第二大农田 group |
| saint_bell_chapel | 58 | 0 银 | 0 银 | 教会农田，免租 |

全镇 303 格农田中，245 格应租、58 格教堂用地免租。每周向王室交 245 银，折算 35 银/day。

面包行业现在只保留 `hale_bakery` 一家面包店。大多数住户从磨坊买面粉回家做饭，面包店主要供应值守、旅人、采办和临时用餐。

磨坊行业现在也按两家磨坊建模：`millward_mill` 占 2 个工位和 2/3 收益，`harbor_mill` 占 1 个工位和 1/3 收益。

`hale_bakery`、`millward_mill` 和 `harbor_mill` 已写进 `groups.json`，可以参与 group 级财富捕获。

## 9. 当前报告暴露的设计问题

新版模型跑出来的关键问题是：

| 问题 | 含义 |
|---|---|
| milling 体力已解决 | 两家磨坊共 3 个工位后，磨粉不再被体力卡住 |
| mill ownership missing | 两家磨坊还只是设计 group，需要写进 `groups.json` |
| charcoal supply via kiln | 木炭从 20/day 提到 28/day，由炭窑消耗 surplus wood 烧出（coal 原料已废弃，charcoal 是唯一燃料） |
| salt balanced by saltworks | 盐从进口改为沿海盐场盐锅配方生产 |
| lumber crew implemented | 木材按 3 名低产量伐木工和 45 wood/day 建模，新增伐木工已写进数据 |
| farm slot rent implemented | 农业现金流按非教堂农田每格每周 1 银向王室交固定租赁费 |

这些是设计动作，不是 bug：它们告诉我们下一步该补哪些职业、工资或成本。

## 10. 下一步数值动作

优先顺序：

1. ~~决定 `coal` 是否以后拆成 `charcoal` 和 `mineral_coal`。~~ 已决议：只保留 `charcoal`，由炭窑 `kiln_burn` 从 wood 烧出。
2. 给已新增的守卫、面包店、磨坊、盐场、畜牧、酒馆和采集岗位补日程。
3. 把 Tilda、Pella 等学徒工资正式写入工资系统。
4. 继续给高捕获 group 增加家庭消费、债务、维修、慈善或采购支出。

## 11. 使用原则

每次新增物品、职业或设施时，都必须决定：

| 问题 | 必须给出的答案 |
|---|---|
| 来源 | 谁每天生产多少 |
| 去处 | 谁每天消耗多少 |
| 劳动 | 需要多少工时和体力 |
| 工资 | 谁付钱给谁 |
| 所有权 | 留存利润归哪个 group |
| 维护 | 是否消耗工具、燃料、饲料或租税 |
| 风险 | 是否腐烂、滞销、失败或导致财富集中 |

如果这些字段缺一个，经济就会出现“免费资源”“免费劳动”或“财富凭空集中”。
