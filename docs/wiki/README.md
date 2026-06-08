# 游戏机制 Wiki

这里记录当前项目的玩家可见机制。优先整理已经能在当前版本中体验到的规则，规划中的魔法、战斗和 DM 剧情单独放在 `planned-systems/`。

## 入口

| 页面 | 内容 |
|---|---|
| [当前版本](./current-version.md) | 当前能玩什么、关键限制、最值得记住的规则 |
| [操作与指令](./core-systems/controls-and-commands.md) | 按键、背包操作、slash 指令、自然语言命令 |
| [角色状态](./core-systems/character-stats.md) | HP、体力、饱食、精力、行动消耗 |
| [背包与物品](./core-systems/inventory-and-items.md) | 背包容量、堆叠、物品身份、耐久和容器 |
| [制造系统](./production/crafting.md) | 工作台、投料、制作时间、品质惩罚 |
| [配方速查](./production/recipes.md) | 当前工作站配方表 |
| [农场系统](./production/farming.md) | 作物、水分、虫害、照料评分、收获 |
| [地点](./town/locations.md) | 小镇地点和农田子地点 |
| [NPC](./town/npcs.md) | NPC 群体、职业分工和当前定位 |
| [已知限制](./references/known-limitations.md) | 当前版本中容易误解或尚未实装的内容 |

## 分类

| 目录 | 说明 |
|---|---|
| `core-systems/` | 时间、角色状态、背包、品质、食物、液体和容器 |
| `production/` | 工作站、制造、配方、农场、采矿伐木制盐、熟练度 |
| `town/` | 地点、NPC、经济、商店和货架 |
| `agents-and-social/` | 说话、自然语言指令、NPC agent 行为 |
| `references/` | 开局路线、物品/作物/工作站/技能清单、限制说明 |
| `planned-systems/` | 魔法、战斗、DM 剧情等规划内容 |

## 维护口径

- “当前版本”以 `docs/architecture/game-mechanics.md` 里的可玩规则为主。
- `docs/town-npcs.md` 和 `docs/town-positions.md` 记录了更完整的城镇数据和规划，NPC 数量与当前可玩口径可能不同。
- 魔法、战斗、DM 剧情目前按规划记录，不写进当前玩法规则。
