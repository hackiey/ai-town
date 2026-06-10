# Town Design Data

`backend/data/town/` 存放开发期手写、运行时只读的城镇 seed 数据。Godot 负责把其中一部分灌入游戏世界表；backend 只读取 agent 记忆和调试所需的共享设定。

## 文件清单

- `npcs.json`：NPC 基础资料、初始背包/钱包、`groups[]`、agent model 配置，以及 `soul[] / knowledge_books[] / other[]` seed memory。
- `player-template.json`：新玩家默认属性、初始物品/钱包，以及 AI takeover 时可用的 seed memory。
- `containers.json`：容器/货架的初始库存和钱包 seed。

## 真值边界

- NPC 节点、mesh、初始 transform：`src/levels/town.tscn` 和 Godot 场景。
- 地点/站点层级、坐标、owner group：Godot 场景树和 Godot 写入的 SQLite `sites` 表。
- group 显示名/合法性：`data/i18n/<locale>/groups.json`。
- 角色 group 成员关系：SQLite `character_groups` 表，初始成员由 Godot 根据 `npcs.json` seed。
- Runtime 状态：SQLite 表，例如 `world_events`、`action_log`、`agent_sessions`、`runtime_storage`。

## Backend 使用点

- `backend/src/services/group-seed.ts` 校验 `npcs.json` 中的 group id 是否有 i18n display name。
- `backend/src/services/character-groups-service.ts` 只提供 `getCharacterGroups` 读取当前角色 group。
- `backend/src/agent-shared/name-resolver/site-catalog.ts` 从 `sites` 表刷新地点/站点 catalog；backend 不再读取 `locations.json`。
- `backend/src/services/memory-service.ts` 使用 `npcs.json` 和 `player-template.json` seed agent memory。

本目录不再包含 `groups.json` 或 `locations.json`；不要新增同名文件作为真值源。
