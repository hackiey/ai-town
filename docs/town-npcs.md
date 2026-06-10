# Town NPC Roster

当前花名册以 **三块农田的 11 个农业 NPC** 为基础，并补了教堂、矿场、守卫、王室采办、**小麦 → 面粉 → 家庭做饭 / 少量面包** 链路、畜牧/酒馆/盐场，以及 **铁矿石 → 铁铲** 链路上的铁矿、炭窑、伐木场、杂货店和铁匠铺 NPC。南侧现在拆成两个并列地点：`saint_bell_chapel` 是 **圣钟教堂**，`saint_bell_garden` 是 **圣钟草药园**。

> **人设的权威源**：`backend/data/town/npcs.json`。Godot 端的 `src/characters/npcs/npc.gd` 现在也直接读取这份 JSON 来生成名字和本地 soul snapshot。

## 农田地点

三块农田都在要塞城墙内：

| 地点 ID | 中文名 | 农田数 | 定位 |
|---|---|---:|---|
| `north_wall_wheat_plot` | 北墙麦圃 | 3 | 靠北墙的小型农田，靠近城墙，空间较窄 |
| `greystone_farmstead` | 灰石农圃 | 5 | 要塞内最大农圃，混种谷物、豆类、菜蔬和饲草 |
| `saint_bell_garden` | 圣钟草药园 | 2 | 圣钟教堂旁边的两块田地，主要种本地药草 |

## 教堂分工

| 地点 ID | 中文名 | 编制 | 定位 |
|---|---|---:|---|
| `saint_candle_chapel` | 圣烛教堂 | 2 | 负责晨祷、婚丧、节庆、看堂和账册，是城内正式教堂事务中心 |
| `saint_bell_chapel` | 圣钟教堂 | 3 | 郊区教堂本体，负责基础医疗、病人照看和教堂事务；旁边的田地由圣钟草药园承接 |

## 面包链分工

| 地点 ID | 中文名 | 编制 | 定位 |
|---|---|---:|---|
| `mill` | 米尔沃德磨坊 | 2 | 承接农户的小麦，把谷物磨成面粉，供给面包店和散客 |
| `harbor_mill` | 港口磨坊 | 1 | 第二家磨坊，给靠海一侧住户、客栈和酒馆供粉 |
| `hale_bakery` | 黑尔面包店 | 2 | 保留少量成品面包供应，主要卖给值守、旅人、采办和临时用餐 |

## 铁铲链分工

路线：`iron_ore + charcoal -> iron_ingot`（锻造场熔炉）→ `iron_ingot -> iron_blade`（铁匠铺铁砧）→ `wood -> wood_shaft`（工作台）+ `flax_seed -> flax_bundle -> fiber -> rope`（种亚麻收亚麻束，晾晒架取种或取纤维，纤维可做衣服/绳，再在工作台搓绳）→ `iron_blade + wood_shaft + rope -> iron_shovel`（铁匠铺工作台）。番茄留种也复用晾晒架：`tomato_fruit -> tomato_seed`。

| 环节 | 地点 ID | NPC ID | 定位 |
|---|---|---|---|
| 铁矿石 | `iron_mine` | `merrin_cairn` | 铁矿把头，负责铁矿石出料和挑矿 |
| 燃料 | `charcoal_kiln` | `dain_soot` | 炭窑烧炭人，把 wood 烧成木炭供熔炉/盐锅 |
| 木材 / 木杆 | `lumberyard` | `silas_coppice`, `garrick_ashby`, `fenn_coppice` | 三名低产量伐木工，主要供炭窑，也供木杆 |
| 晾晒 / 亚麻种子 / 绳 / 纤维 | `general_store` | `cora_reed` | 杂货铺掌柜，兼管晾晒架、亚麻种子、绳和纤维供货 |
| 冶炼 | `forge_yard` | `tilda_sparks` | 锻造场学徒，把铁矿石和木炭冶成铁锭 |
| 成品 | `blacksmith_shop` | `owen_barclay` | 铁匠铺主匠，打铁刃并组装铁铲 |

## 田块子地点

这些是三块农田下面的子 location。NPC 抵达父地点后，`move_to_location.location` 的参数 enum 会展开对应的 1 号、2 号等子地点。

| 所属农田 | 田块 ID | 中文名 | 用途 / 口语含义 |
|---|---|---|---|
| 北墙麦圃 | `north_wall_field_1` | 1号农田 | 北墙麦圃第 1 块农田 |
| 北墙麦圃 | `north_wall_field_2` | 2号农田 | 北墙麦圃第 2 块农田 |
| 北墙麦圃 | `north_wall_field_3` | 3号农田 | 北墙麦圃第 3 块农田 |
| 灰石农圃 | `greystone_field_1` | 1号农田 | 灰石农圃第 1 块农田 |
| 灰石农圃 | `greystone_field_2` | 2号农田 | 灰石农圃第 2 块农田 |
| 灰石农圃 | `greystone_field_3` | 3号农田 | 灰石农圃第 3 块农田 |
| 灰石农圃 | `greystone_field_4` | 4号农田 | 灰石农圃第 4 块农田 |
| 灰石农圃 | `greystone_field_5` | 5号农田 | 灰石农圃第 5 块农田 |
| 圣钟草药园 | `saint_bell_field_1` | 1号农田 | 圣钟草药园第 1 块农田 |
| 圣钟草药园 | `saint_bell_field_2` | 2号农田 | 圣钟草药园第 2 块农田 |

## 当前 NPC

当前共有 **50 人**：11 个农户/农工，5 个教堂/医护 NPC（其中圣钟教堂 3 人兼顾菜园），3 个贵金属矿工，8 个守卫，1 个王室内务采办，5 个面粉/面包链职业 NPC，8 个工具材料/铁匠链职业 NPC，以及畜牧、肉铺、酒馆、客栈商队进口、裁缝和盐场岗位 NPC。

| 地点 | NPC ID | 英文名 | mesh | 一句话 |
|---|---|---|---|---|
| 北墙麦圃 | `oren_vale` | Oren Vale | Peasant_Male_01 | 北墙麦圃农户，熟悉三块田的土质、排水和收成 |
| 北墙麦圃 | `alma_vale` | Alma Vale | Peasant_Female_01 | 种子管事，负责晾晒、腌制，也会把热汤分给附近干活的人 |
| 北墙麦圃 | `niko_vale` | Niko Vale | Peasant_Male_01 | 少年帮工，挑水、赶鸟、跑腿，熟悉哪块田最容易长得好 |
| 灰石农圃 | `cedric_rowan` | Cedric Rowan | Peasant_Male_01 | 最大农圃主事，协调农田、粮仓和磨坊 |
| 灰石农圃 | `elspeth_rowan` | Elspeth Rowan | Peasant_Female_01 | 账目管事，记录粮种、工钱、收成和配给 |
| 灰石农圃 | `tavin_rowan` | Tavin Rowan | Peasant_Male_01 | 主劳力，不甘心只种田，常偷空去训练场看练剑 |
| 灰石农圃 | `lysa_rowan` | Lysa Rowan | Peasant_Female_01 | 家庭帮工，能较早察觉作物上的魔法污染 |
| 灰石农圃 | `bram_holt` | Bram Holt | Peasant_Male_01 | 外来长工，干活可靠，似乎背着旧债 |
| 圣烛教堂 | `aldric_voss` | Aldric Voss | Peasant_Male_01 | 圣烛教堂司祭，主持晨祷、婚丧、节庆和镇民求助 |
| 圣烛教堂 | `mirelle_hart` | Mirelle Hart | Peasant_Female_01 | 看堂执事，负责开门点灯、清扫祭坛、整理账册 |
| 圣钟教堂 | `greta_moss` | Greta Moss | Peasant_Female_01 | 圣钟教堂草药医者，照看病人，也会去菜园看草药和老种子 |
| 圣钟教堂 | `borin_ash` | Borin Ash | Peasant_Male_01 | 圣钟教堂田务帮工，负责翻土、浇水、修篱笆和搬运药草 |
| 圣钟教堂 | `pella_moss` | Pella Moss | Peasant_Female_01 | 圣钟教堂见习照护人，学习种草药、换布带和煮药汤 |
| 金矿 | `tomas_pike` | Tomas Pike | Peasant_Male_01 | 金矿矿工，靠领主国库按矿石产量结日工钱 |
| 银矿 | `harlan_dunn` | Harlan Dunn | Peasant_Male_01 | 银矿老矿工，熟悉老坑口，带着年轻矿工下井 |
| 银矿 | `wilf_drake` | Wilf Drake | Peasant_Male_01 | 银矿矿工，稳手慢工，细细攒钱 |
| 铁矿 | `merrin_cairn` | Merrin Cairn | Peasant_Female_01 | 铁矿把头，给铁匠铺供应铁矿石 |
| 炭窑 | `dain_soot` | Dain Soot | Peasant_Male_01 | 炭窑烧炭人，给锻造场供应木炭 |
| 伐木场 | `silas_coppice` | Silas Coppice | Peasant_Male_01 | 木料工，给铁铲链提供木材和木杆 |
| 杂货店 | `cora_reed` | Cora Reed | Peasant_Female_01 | 杂货铺掌柜，给铁匠铺和伐木场供亚麻种子、绳与纤维，也管店外晾晒架 |
| 铁匠铺 | `owen_barclay` | Owen Barclay | Peasant_Male_01 | 主匠，打铁刃并组装铁铲等工具 |
| 锻造场 | `tilda_sparks` | Tilda Sparks | Peasant_Female_01 | 锻造学徒，负责烧炉和冶铁锭 |
| 王室采办 | `magda_kerr` | Magda Kerr | Peasant_Female_01 | 王室内务采办，负责从磨坊、面包店、肉铺、裁缝等处采购并报账 |
| 磨坊 | `jonas_millward` | Jonas Millward | Peasant_Male_01 | 磨坊主，收小麦、磨面粉，供给面包店和散客 |
| 面包店 | `edda_hale` | Edda Hale | Peasant_Female_01 | 面包店老板娘，把面粉和水做成面团，再烤成面包上架 |
| 面包店 | `mara_hale` | Mara Hale | Peasant_Female_01 | 黑尔面包店帮工，揉面、打水、看炉 |
| 磨坊 | `rudi_millward` | Rudi Millward | Peasant_Male_01 | 米尔沃德磨坊帮工，第二个磨坊工位 |
| 港口磨坊 | `selma_rusk` | Selma Rusk | Peasant_Female_01 | 第二家磨坊主，给住户、客栈和酒馆供粉 |
| 伐木场 | `garrick_ashby` | Garrick Ashby | Peasant_Male_01 | 低产量伐木工，供炭窑和木杆 |
| 伐木场 | `fenn_coppice` | Fenn Coppice | Peasant_Female_01 | 低产量伐木工，负责分料和挑木 |
| 训练场 | `keir_march` | Keir March | Peasant_Male_01 | 守卫队长，训练场四人编制之一，周薪由国库发放 |
| 巡逻路线 | `sona_ward` | Sona Ward | Peasant_Female_01 | 镇守卫，和艾娃一起巡逻集市、面包店、酒馆和客栈 |
| 训练场 | `garret_pell` | Garret Pell | Peasant_Male_01 | 年轻守卫，训练场四人编制之一 |
| 巡逻路线 | `iva_stone` | Iva Stone | Peasant_Female_01 | 夜巡守卫，和索娜一起负责日常巡逻 |
| 训练场 | `brenna_vail` | Brenna Vail | Peasant_Female_01 | 训练场守卫，负责基础队列和盾牌训练 |
| 训练场 | `rolan_teague` | Rolan Teague | Peasant_Male_01 | 训练场守卫，负责器械和耐力训练 |
| 城门 | `merek_gate` | Merek Gate | Peasant_Male_01 | 大门守卫，负责城门出入和商队检查 |
| 监狱 | `oswin_locke` | Oswin Locke | Peasant_Male_01 | 监狱看守，负责牢门钥匙和交接记录 |
| 牧场 | `osric_bell` | Osric Bell | Peasant_Male_01 | 牲畜照料人，负责肉源和饲料节奏 |
| 牧场 | `maeve_coop` | Maeve Coop | Peasant_Female_01 | 鸡舍与鸡蛋管事，供应酒馆蛋类 |
| 牧场 | `milo_fallow` | Milo Fallow | Peasant_Male_01 | 牧场帮工，负责喂料、清圈、赶牲口和搬饲料 |
| 牧场 | `tessa_coop` | Tessa Coop | Peasant_Female_01 | 鸡舍和幼畜帮工，负责收蛋、补饲料和病鸡隔离 |
| 肉铺 | `hugh_marrow` | Hugh Marrow | Peasant_Male_01 | 肉铺屠夫，屠宰并售卖生肉 |
| 酒馆 | `garron_potter` | Garron Potter | Peasant_Male_01 | 酒馆掌火人，处理熟肉和热食 |
| 酒馆 | `nell_millward` | Nell Millward | Peasant_Female_01 | 酒馆调味帮工，磨坊主的女儿，脾气冲嘴刀子但护人紧 |
| 客栈 | `vera_clay` | Vera Clay | Peasant_Female_01 | 客栈掌柜，接待外来商队、过路客和信使 |
| 客栈 | `tobin_reeve` | Tobin Reeve | Peasant_Male_01 | 商队账房，登记进口货、住宿账和商队消息 |
| 裁缝 | `hilda_fenwick` | Hilda Fenwick | Peasant_Female_01 | 裁缝铺主裁，负责衣服、被褥和缝补 |
| 裁缝 | `perrin_weft` | Perrin Weft | Peasant_Male_01 | 织补帮工，处理亚麻纤维、线和补丁 |
| 沿海盐场 | `iona_brine` | Iona Brine | Peasant_Female_01 | 盐场盐工，把海水熬晒成盐 |

## 接入状态

- 已写入 `backend/data/town/npcs.json`、`backend/data/town/groups.json` 和 `backend/data/town/locations.json`。
- `src/characters/npcs/npc.gd` 直接读取 `backend/data/town/npcs.json`，不再维护单独的人设副本。
- `town.tscn` 的 `NPCs` 下会按机制接入进度逐步放置 NPC 场景实例；地点层里已把 `saint_bell_chapel` 和 `saint_bell_garden` 分开，并补了 `iron_mine`、`charcoal_kiln` 标记，以及铁匠铺附近的工作台 / 铁砧 / 熔炉锚点。
- `Shelves` 下已放置 `mill_flour_shelf` 与 `bakery_bread_shelf`。

## 后续建任务建议

先从农业链条开始，不急着补全全部职业：

1. 北墙麦圃：三块田的土质、排水、少年帮工想弄明白哪块田最容易长得好。
2. 灰石农圃：收成记录、欠粮、外来长工旧债。
3. 圣钟教堂 / 圣钟草药园：教堂医护、老种子、药田与草药照护职责。
