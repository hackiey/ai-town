# 地点

小镇地点由场景中的 `Positions` 和数据中的 `locations.json` 共同描述。玩家和 NPC 的自然语言导航会使用这些地点。

## 顶层地点

| id | 中文名 | 类型 | 说明 |
|---|---|---|---|
| blacksmith_shop | 铁匠铺 | workshop | 主铁匠铺 |
| tavern | 酒馆 | social | 吃饭、喝酒、打听消息 |
| inn | 客栈 | logistics | 商队、过路客和信使住宿 |
| well | 水井 | civic | 公共打水点 |
| guard_post | 守卫岗 | military | 镇中心守卫驻点 |
| market_square | 集市 | commerce | 集市父地点 |
| saint_candle_chapel | 圣烛教堂 | civic | 市区主教堂 |
| livestock | 畜牧场 | service | 牲畜、鸡舍和饲料供应 |
| general_store | 杂货店 | commerce | 日用商铺和部分材料供应 |
| hale_bakery | 面包店 | commerce | 面包与粮饼 |
| notice_board | 告示板 | civic | 公告与悬赏 |
| mill | 磨坊 | workshop | 谷物加工 |
| north_wall_wheat_plot | 北墙麦圃 | production | 北侧 3 块田 |
| greystone_farmstead | 灰石农圃 | production | 主农区 5 块田 |
| saint_bell_chapel | 圣钟教堂 | civic | 医疗、病人照看和教堂事务 |
| saint_bell_garden | 圣钟草药园 | production | 2 块药田和前院 |
| fishing_dock | 渔码头 | production | 水边生产点 |
| lumberyard | 伐木场 | production | 木料堆场 |
| saltworks | 沿海盐场 | production | 熬晒海水成盐 |
| granary | 粮仓 | logistics | 公粮与余粮储存 |
| forge_yard | 锻造场 | workshop | 铁匠铺后院 |
| fishmonger | 鱼摊 | commerce | 当日鲜鱼 |
| apothecary | 药房 | commerce | 炼金与药剂 |
| training_ground | 训练场 | military | 守卫训练 |
| town_gate | 城门 | military | 城门出入和商队检查 |
| jail | 监狱 | military | 监狱看守岗位 |
| patrol_route | 巡逻路线 | military | 巡逻守卫路线 |

## 集市子地点

| 父地点 | id | 中文名 |
|---|---|---|
| market_square | butcher | 肉铺 |
| market_square | tailor | 裁缝 |
| market_square | jeweler | 珠宝店 |
| market_square | bookstore | 书店 |

## 农田子地点

| 父地点 | 子地点 |
|---|---|
| 北墙麦圃 | north_wall_field_1、north_wall_field_2、north_wall_field_3 |
| 灰石农圃 | greystone_field_1 到 greystone_field_5 |
| 圣钟草药园 | saint_bell_field_1、saint_bell_field_2 |

子地点通常要 NPC 或角色先到父地点附近后，才会作为可选具体目的地出现。
