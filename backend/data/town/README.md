# Town Design Data

`backend/data/town/` 是 worker 端的 **设计稿源头**：人设、地点说明等"开发期手写、运行时只读"的数据。跟 prompt 模板一起进 git，改完走 PR review。

## 与现有源的关系

| 维度 | 真值源 | 用途 |
|---|---|---|
| NPC mesh + 初始 transform | `src/levels/town.tscn` | Godot 渲染 |
| NPC 节点 id (`npc_id`) | `src/levels/town.tscn` | 跨端串联 |
| Marker 坐标 + 地点层级 + alias | `src/levels/town.tscn` + `src/world/town_world.gd` | 寻路、命令解析、agent 可见地点裁剪 |
| **NPC 基础资料 + seed memory**（name/age/mesh/inventory + soul / skills / other） | **本目录 `npcs.json`** | Godot + backend 共享设定 |
| **Group 定义**（成员可见的 location / 可用的 workstation / 初始成员） | **本目录 `groups.json`** | server boot 时校验 + 每个 town runtime 首次连接时灌种子到 SQLite `character_groups` |
| **角色 ↔ group 成员关系（运行时真值）** | **SQLite `character_groups` table** | 多对多；`groups.json` 只是初始种子，table 非空就不再读 |
| **地点语义描述**（例如 `saint_candle_chapel` 是圣烛教堂、能做什么） | **本目录 `locations.json`** | 当前地点描述 |
| Runtime 状态（事件、会话、记忆、关系） | SQLite 表（如 `world_events` / `agent_sessions` / `runtime_storage`） | 会随时间变 |

`src/characters/npcs/npc.gd` 也会直接读取 `npcs.json` 来生成头顶名字和本地 `soul_snapshot()`；如果 JSON 缺失，Godot 端才退回空值 / `npc_id` 这种通用兜底。backend worker 也从这同一份 `npcs.json` 读取 `soul[] / skills[] / other[]` 作为初始 memory seed。

## 文件清单

- `npcs.json` — 25 个当前 NPC 的统一设定：`name / age / gender / mesh / starting_inventory / soul[] / skills[] / other[]`。`soul[]` 放稳定自我认知与行为倾向，`skills[]` 放技能书 id，`other[]` 放对具体人物的牵挂、别扭、偏爱与受伤点。worker 启动时会把这些条目灌进 SQLite `runtime_storage`。**不存 `primaryLocation`**（location 以场景树 Marker3D 为准），**不存 `group`**（group 是动态多对多，运行时真值在 SQLite）。
- `groups.json` — group 注册表：每条 `{ nameZh, locations[], workstations[], initialMembers[] }`。
  - `locations[]` / `workstations[]`：本组成员才能看见 / 才能用的 id 集合（可见性 + 权限的来源）
  - `initialMembers[]`：server boot 后某个 town runtime 首次连接时，把这些角色作为 source="seed" 写入 `character_groups` table；之后 table 非空则不再读这一字段
  - **schema 约束**：`locations[]` 里的 id 必须能在 `locations.json` 里找到，否则 boot 直接 throw（见 `backend/src/services/group-seed.ts`）
- `locations.json` — 47 个地点的语义描述：alias / category / description / primaryNpcs。地点的父子层级不在这里维护，以 Godot `Positions` 场景树为准。

## Group / 权限模型

- group = **可见性 + 权限作用域**，不是身份/家族标签
- 一个角色可同时属于多个 group；一个 location 可被多个 group 共享，**任一组成员均可见**
- "god" group bypass 全部过滤（开发期玩家用；Player 现阶段在 client 默认带 god，后续会改成 `/god` 命令切换）
- 真值源：**SQLite `character_groups` table**，schema：`{ townId, characterId, groupId, joinedAt, source: "seed" | "runtime" }`
- 读 / 写接口：`backend/src/services/character-groups-service.ts`（`getCharacterGroups` / `addMember` / `removeMember` / `isMember`）
- AgentContextBuilder 在 build 时按角色 group 过滤 `visibleLocations`、`nearbyFarms`、`nearbyWorkstations` 和由它们生成的 `interactiveSites`；`nearbyBuildings` 是纯物理感知，不做 group 过滤

## TODO（Phase 2 之后）

- 把成员资格从 backend 推送到 Godot client，让 `LocationMarker.owner_group` / `WorkstationNode.owner_group` 客户端校验也能用 SQLite 真值
- 工作台 E 键交互按 `WorkstationNode.owner_group` 校验 player.groups
- `/god` slash command 切 god group
- LLM 自主收徒/拜师工具（`accept_apprentice` / `request_apprenticeship` / `dismiss_member`）
- workstation id 注册表（`data/workstations.json`），groups.json 的 `workstations[]` 也做 boot 校验

注意：`locations.json` 可以先记录设计稿地点；要让 NPC 实际寻路到该地点，还需要在 `town.tscn` 的 `Positions` 下补对应 marker。

## 地点层级与 agent context

`TownWorld` 会把 `Positions` 下的 Marker3D 场景树编成 location tree：

- `Positions` 的直接子节点是大地点，例如 `market_square`
- 大地点下的 Marker3D 子节点是局部地点，例如 `market_square/butcher`
- character context 默认只上报大地点；当角色抵达某个大地点附近时，才额外上报该地点的直接子地点
- backend 把 `visibleLocations` 写进 `move_to_location.location` 的动态 enum；普通 prompt 不展开候选地点，隐藏子地点也不会提前出现在参数 enum 中

## 接入计划（未做）

`AgentContextBuilder.build`（`backend/src/agents/context/builder.ts`）会装配当前 context；地点/物品/角色展示名由 `backend/src/agents/context/catalog.ts` 读取 `locations.json` 等设计数据来渲染。后续可继续做：

1. `# 当前附近建筑` 区块给 near/far 各 marker 加一行更短的描述
2. NPC 自身的 soul 也可以从 `npcs.json` 兜底；角色当前状态由 Godot live snapshot 提供，不落 backend 表。

接入前的 short-term 路径：继续把这俩 JSON 当 source of truth 维护；client 端不再复制 NPC 人设，只保留地点 alias 这类本地映射。
