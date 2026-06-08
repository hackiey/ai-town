# Town Positions 位点现状

`src/levels/town.tscn` 的 `Positions` 现在已经不是早期的“待拖拽规划稿”，而是正在被 runtime 使用的正式地点树。本文只记录**当前真实状态**：哪些地点已经在场景里、哪些地点是子地点、哪些地点还只存在于 `locations.json`。

> 权威关系：
> - 场景树真源：`src/levels/town.tscn` 的 `Positions`
> - 语义真源：`backend/data/town/locations.json`
> - 中文名：`data/i18n/zh/locations.json` 的 `location.<id>.alias`

## 当前进度

- `locations.json` 一共 **53** 个 location。
- `town.tscn` 的 `Positions` 下已经有 **46** 个 marker。
- 其中 **24** 个是顶层地点，**14** 个是子地点。
- 当前还没落到 scene 的 data-only 地点有 **7** 个：`well`、`graveyard`、`farm`、`herbalist`、`barber`、`harbor_mill`、`pasture`。

## 使用规则

- 顶层地点默认可见，例如 `market_square`、`saint_candle_chapel`、`north_wall_wheat_plot`。
- 子地点只有在 NPC 先到父地点附近后，才会出现在 `move_to_location.location` 的动态 enum 里。
- 同名子地点依赖父地点语境区分，比如三个农区下面都各自有 `1号农田`。
- `TownWorld` 会优先解析 location id / 中文别名，找不到时才 fallback 到 region。

## 顶层地点

下表是当前已经在 `town.tscn` 里有 marker 的顶层地点。

| id | 中文名 | category | 说明 |
|---|---|---|---|
| `blacksmith_shop` | 铁匠铺 | workshop | 主铁匠铺 |
| `tavern` | 酒馆 | social | 吃饭、喝酒、打听消息和雇短工的地点 |
| `inn` | 客栈 | logistics | 外来商队、过路客和信使住宿；进口货物入口 |
| `well` | 水井 | civic | 公共打水点 |
| `guard_post` | 守卫岗 | military | 镇中心守卫驻点 |
| `market_square` | 集市 | commerce | 集市顶层父地点 |
| `saint_candle_chapel` | 圣烛教堂 / 教堂 / 市区教堂 | civic | 市区主教堂，现有 2 个教堂 NPC |
| `livestock` | 畜牧场 | service | 牲畜、鸡舍与饲料供应 |
| `general_store` | 杂货店 | commerce | 日用商铺 |
| `hale_bakery` | 面包店 | commerce | 面包与粮饼 |
| `notice_board` | 告示板 | civic | 公告与悬赏 |
| `mill` | 磨坊 | workshop | 谷物加工 |
| `north_wall_wheat_plot` | 北墙麦圃 | production | 3 块田的北侧农区 |
| `greystone_farmstead` | 灰石农圃 | production | 5 块田的主农区 |
| `saint_bell_chapel` | 圣钟教堂 / 郊区教堂 | civic | 郊区教堂本体，负责基础医疗、病人照看和教堂事务 |
| `saint_bell_garden` | 圣钟草药园 | production | 圣钟教堂旁边的两块田与前院，供种草药 |
| `fishing_dock` | 渔码头 | production | 水边生产点 |
| `lumberyard` | 伐木场 | production | 木料堆场 |
| `saltworks` | 沿海盐场 | production | 熬晒海水成盐，供应酒馆、肉铺和保藏食品链 |
| `granary` | 粮仓 | logistics | 公粮与余粮储存 |
| `forge_yard` | 锻造场 | workshop | 铁匠铺后院 |
| `fishmonger` | 鱼摊 | commerce | 当日鲜鱼 |
| `barber` | 理发店 | service | 理发与基础外科 |
| `apothecary` | 药房 | commerce | 炼金与药剂 |
| `training_ground` | 训练场 | military | 守卫训练场 |
| `town_gate` | 城门 | military | 大门守卫岗位 |
| `jail` | 监狱 | military | 监狱看守岗位 |
| `patrol_route` | 巡逻路线 | military | 两名巡逻守卫的路线锚点 |

## 子地点

### 集市下的子地点

这些点挂在 `market_square` 下面，属于集市内部可细分去的摊位或店铺。

| 父地点 | id | 中文名 |
|---|---|---|
| `market_square` | `butcher` | 肉铺 |
| `market_square` | `tailor` | 裁缝 |
| `market_square` | `jeweler` | 珠宝店 |
| `market_square` | `bookstore` | 书店 |

### 农田子地点

这些点是三块农区下面的具体田块，主要给农业 NPC 日常对话和行动指代使用。

| 父地点 | id | 中文名 |
|---|---|---|
| `north_wall_wheat_plot` | `north_wall_field_1` | 1号农田 |
| `north_wall_wheat_plot` | `north_wall_field_2` | 2号农田 |
| `north_wall_wheat_plot` | `north_wall_field_3` | 3号农田 |
| `greystone_farmstead` | `greystone_field_1` | 1号农田 |
| `greystone_farmstead` | `greystone_field_2` | 2号农田 |
| `greystone_farmstead` | `greystone_field_3` | 3号农田 |
| `greystone_farmstead` | `greystone_field_4` | 4号农田 |
| `greystone_farmstead` | `greystone_field_5` | 5号农田 |
| `saint_bell_garden` | `saint_bell_field_1` | 1号农田 |
| `saint_bell_garden` | `saint_bell_field_2` | 2号农田 |

## 还没进场景的地点

这些地点已经存在于 `backend/data/town/locations.json`，但 `town.tscn` 里还没有对应 marker，因此目前只算设计数据，不算可寻路的正式地点。

| id | 中文名 | 建议状态 |
|---|---|---|
| `graveyard` | 墓地 | 后续如果要做葬礼、守夜或夜间事件，再补 marker |
| `farm` | 农场 | 现在只是农业区的泛称，实际可用地点已经拆成三块农区，不急着单独落点 |
| `herbalist` | 草药铺 | 以后若要把草药铺做成独立职业点，再补 marker |
| `well` | 水井 | 现有井是工作站实例，未单独放 `Positions` marker |
| `barber` | 理发店 | 以后若要做理发/外科服务，再补 marker |
| `harbor_mill` | 港口磨坊 | NPC 已放置，后续可补独立磨坊 marker |
| `pasture` | 牧场 | 畜牧 NPC 已放置，后续可补牧场 marker |

## 当前与旧规划的区别

- 不再维护“原计划 50 个点位”那套清单。
- 不再把未落地地点写成“已删除位点”；现在区分为“scene 里已有”和“data-only 未落地”。
- 农田系统已经从单个 `farm` 演进成三块父地点加十块具体农田的层级结构。
- 教堂现在分成圣烛教堂 `saint_candle_chapel` 和圣钟教堂 `saint_bell_chapel`；圣钟草药园 `saint_bell_garden` 是与之并列的农务地点。

## 维护规则

1. 新增地点时，先写 `backend/data/town/locations.json` 的语义，再决定是否在 `town.tscn` 里补 marker。
2. 需要层级地点时，父子关系只在 `Positions` 场景树里表达，不在 `locations.json` 单独维护。
3. 加了中文叫法后，只维护 `data/i18n/zh/locations.json` 的 `location.<id>.alias`。
4. 如果一个地点只是世界观上的泛称，不一定要落 marker；例如当前的 `farm`。
