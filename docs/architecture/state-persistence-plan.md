# State Persistence Plan

> Status: **drafting** — 规划稿。定义“常见游戏状态哪些应该持久化、谁是权威、按什么阶段落地”。

## 1. Context

当前 SQLite 已经在存：

**Brain 表（backend 拥有 schema，`backend/src/db/schema.ts` 建表）**
- `action_log`：角色 action 提交、投递、ack 与 terminal result 记录
- `runtime_storage` / `agent_sessions` / `agent_session_messages`：Agent runtime 记忆、KV 状态与会话

**Game-world 表（Godot 拥有 schema，`src/autoload/db.gd` 的 `_GAME_WORLD_SCHEMA` 建表）**
- `world_events`：事件历史
- `character_groups`：group 成员关系
- `runtime_sessions`：runtime 连接历史
- `town_clock`：每镇当前 game time

> **所有权原则**：游戏运行不依赖 backend。Godot server 单独启动也必须能跑，因此凡是描述游戏世界状态的表，schema 由 Godot 端建——backend 只读写、永远不 CREATE。后续新增的"常见游戏状态"表（背包、农田、装备等）都归 Godot 端 schema。

这套数据足够支撑 **agent 决策链路**，但还不够支撑 **常见游戏状态真值**。现在缺的是：

- 玩家 / NPC 数值状态
- 背包、地面掉落、容器里的物品实例
- 装备状态
- 作物 / 农田状态
- 持续效果 / 到期计时器
- 可恢复的 town 级模拟状态

结果是：很多状态只能活在 Godot 内存里，或者临时混进 `world_events.data` / perception manifest 的 JSON 视图里，缺乏稳定查询路径，也不适合 runtime 重启恢复。

> **2026 进展更新**：本计划的核心目标"建立 game-world 真值表"已大量落地。当前 game-world schema（`character_states / item_instances / farm_states / farm_plots / workstation_states / container_states / location_markers / shelf_listings / trade_offers / player_accounts` 等）由 Godot `db.gd` CREATE 并持续 UPSERT，backend 通过 `services/world-state/*-repo.ts` SELECT-only 访问。Agent 上下文不再依赖 snapshot bundle，而是 perception manifest（id 清单）+ 当场 SELECT sqlite 拼成。下文 §3–§7 的"目标 schema/Phase"已被落地版本覆盖，留作设计原文参考。`player_accounts` 把 login name 映射到稳定 `character_id`（`player_<8hex>`），让玩家跨重连/换 peer 复用 `character_states` / `item_instances` 等表里的状态——详见 [runtime-layers.md §3.1](./runtime-layers.md) 的"玩家身份"小节。
>
> **2026-05 修订（派生量写者唯一）**：曾经"派生量不持久化、读时各端公式现算"的早期取舍（如 `farm_plots.stage` 注释"不存，从 spawnedAtGameHour 推"）已撤销。游戏存档天然就该带派生态，让多端各自实现公式必然漂移——Lua tick 用 hour-of-day 当 total-hour 写出"成熟麦回种子" bug；backend 自维 stages 数组 `{tillering, heading}` 与 Lua `{vegetative, flowering}` 不一致，NPC 看"分蘖"而 Godot 显示"生长"——都是这条路径的产物。现行原则：**派生量也持久化，且写者唯一**。Godot 唯一公式入口（Lua `compute_stage`）算完 stage，随 raw 字段一起 UPSERT 进 `farm_plots.stage`；backend SELECT 拿现成，不再镜像公式 / variety stages 数组 / maturation。Stage 显示名走共享 i18n catalog（`prompt.context.crop_stage.<variety>.<stage>` → `.default.<stage>` fallback），两边读同一份 key。同类原则适用于今后任何"raw + derived"形态的字段。

## 2. Goals

这份规划想解决 4 件事：

1. 给“常见游戏状态”建立正式真值源，而不是依赖事件日志回放。
2. 保持 [runtime-layers.md](./runtime-layers.md) 的边界：**Godot runtime 是执行权威，SQLite 是持久化真值**。
3. 让 runtime 重启后能从库里恢复世界，不需要靠 agent prompt 或事件文本猜状态。
4. 控制复杂度：先把高频、常用、跨系统共享的状态正规化；其余继续走事件和快照。

## 2.5 已确认语义：停机期间 game time 暂停

这条先定死，作为后续所有持久化和恢复逻辑的前提：

- `wall clock` 继续流逝
- `gameTime` 在服务器停机期间**暂停**
- 重启后从“停机前最后一次成功持久化的 gameTime”继续运行

这意味着：

- 停机期间作物不生长
- 停机期间 `hunger / rest / buff / burning / rot` 不推进
- 停机期间 NPC 不行动、不思考、不产生新事件
- 重启恢复的是“停机瞬间的世界 + Agent 状态”，**不是**“补算了停机时段后的世界”

这样做的原因不是偷懒，而是为了保持世界一致性。

如果让 `gameTime` 在停机期间继续跑，就必须同时定义并补算：

- 作物生长
- 角色数值衰减
- 持续效果与定时器
- NPC 这段时间做了什么
- Agent 会话怎样跨 downtime 延续

在这些规则全部落地前，只让时钟流逝会制造语义裂缝。MVP 先采用“停机 = 世界冻结”是更稳的方案。

## 3. Design Principles

### 3.1 事件日志不是查询真值

`world_events` 要继续保留，因为它适合：

- agent 近期回顾
- 调试和审计
- 叙事历史

但它**不应该**承担“现在这株番茄湿度是多少”“玩家背包里有什么”这类当前态查询。

### 3.2 静态定义和运行时实例分开

静态定义继续留在 `.tres` / JSON：

- `data/items/*.tres`
- `data/materials/*.tres`
- `data/shapes/*.tres`
- `backend/data/town/*.json`

SQLite 只存**实例态**：

- 这把铁斧现在耐久 143/200
- 这株番茄现在在 flowering 阶段，湿度 0.62
- 这名角色当前在教堂门口，hunger 48，装备着铁刀

### 3.3 角色 / 物品 / 作物分表，别全塞 JSON

允许保留少量开放字段 JSON，但高频主字段要能直接 `WHERE` / `ORDER BY`：

- 角色数值、地点、存活状态
- 物品位置 / 持有者 / 容器关系
- 作物 stage / moisture / pest_load / health
- effect 到期时间

### 3.4 先存“可恢复且跨系统共享”的状态

优先级判断标准：

- runtime 重启后必须恢复
- agent / UI / gameplay 都会读
- 会被多个系统改写
- 不适合只靠事件文本推导

## 4. What Should Be Persisted

### 4.1 Phase 1 必做：角色当前态

建议新增 `character_states` 作为**每角色一行**的当前态表。

要存：

- `townId`, `characterId`
- `currentLocationId`
- `position` / `rotation`（JSON，可先粗粒度）
- `hp`, `stamina`, `hunger`, `rest`
- `alive`
- `temperature`
- `burning`
- `equippedRightHandItemId`, `equippedLeftHandItemId`, `equippedBodyItemId`, `equippedHeadItemId`
- `updatedAt`

可先放 JSON，后续再拆：

- `activeStatuses`
- `derivedStats`

理由：

- 它是 UI、agent、战斗、移动、睡觉、吃饭、装备系统的交汇点。
- [player-stats.md](./player-stats.md) 里的 hp/stamina/hunger/rest 迟早都要有真值落点。
- Agent prompt 的 perception manifest 是"喂给 agent 的视图"（id 清单），不该兼任角色数值真值；数值真值在 character_states 表，由 backend 当场 SELECT。

### 4.2 Phase 1 必做：物品实例和持有关系

建议新增 `item_instances`，把“背包 / 装备 / 地面 / 容器里”的物品统一成一张实例表。

最小字段建议：

- `id`
- `townId`
- `itemDefId`
- `ownerKind`：`character | world | item | workstation | crop`
- `ownerId`
- `locationId`
- `slotKey`
- `stackCount`
- `quality`
- `durability`
- `temperature`
- `burning`
- `customProperties`（JSON）
- `createdAt`, `updatedAt`

说明：

- 即便 reaction schema 倾向“不堆叠”，`stackCount` 也建议保留，哪怕 MVP 固定为 1，避免以后表结构返工。
- `ownerKind + ownerId + slotKey` 可以同时表达：
  - 玩家背包中的第 3 格
  - NPC 手上的铁刀
  - 地上的一块矿石
  - 木桶里的水

这张表会直接替代“背包只在 context 文本里出现”的临时状态。

### 4.3 Phase 1 必做：农田 / 作物状态

建议新增 `farm_plots` 或 `crop_instances`。如果田格是固定存在的，优先 `farm_plots`；如果未来有盆栽、树、野生作物，优先 `crop_instances`。

MVP 建议先做 `farm_plots`：

- `id`
- `townId`
- `farmId`
- `plotIndex`
- `cropDefId`
- `stage`
- `growthProgress`
- `health`
- `moisture`
- `pestLoad`
- `soilFertility`
- `lastWateredAt`
- `lastWateredBy`
- `currentlyBeingWorkedBy`
- `currentActionType`
- `updatedAt`

理由：

- [simulation-layer.md](./simulation-layer.md) 里农作系统已经不是“72h 定时成熟”，而是连续条件驱动。
- 这种状态无法从事件日志稳定回推。
- agent context 现在已经在暴露农事行动；没有正式真值表，后面只会越补越乱。

### 4.4 Phase 1 必做：持续效果和定时器

建议新增 `active_effects`，把 buff/debuff、燃烧、scheduled event 放在同一张表。

字段建议：

- `id`
- `townId`
- `targetKind`
- `targetId`
- `effectType`
- `params`（JSON）
- `startedAt`
- `durationMinutes`
- `fireAt`
- `cancelIf`
- `sourceCharacterId`
- `sourceItemId`
- `updatedAt`

理由：

- [entity-model.md](./entity-model.md) 和 [simulation-layer.md](./simulation-layer.md) 都已经把 active effects / scheduled events 当成核心基建。
- 不先给它落库，runtime 重启会丢 buff、腐烂计时、燃烧倒计时这类状态。

### 4.5 Phase 1 必做：town 当前模拟状态

建议新增 `town_states`，每镇一行。

要存：

- `townId`
- `gameTime`（JSON 或拆列）
- `weather`
- `season`
- `lastSimulatedAt`
- `updatedAt`

理由：

- 这是 slow tick / 作物 / 睡眠 / hunger 衰减 / scheduled events 的共同时间基准。
- 现在 `gameTime` 常混在事件里，不适合作为稳定恢复点。

### 4.6 Phase 2：容器 / 交易 / 工作工单

等 Phase 1 稳住后，再考虑正规化：

- `trade_offers`
- `work_orders`
- `containers` 或 `storage_access_rules`
- `relationship_edges`

这些也重要，但不该先于角色、物品、作物、effects。

### 4.7 暂时不单独建表

下面这些短期继续放静态资源、事件或 agent 数据即可：

- 材质定义、shape 定义、reaction 定义
- NPC 长期记忆、会话历史
- 一次性的调试事件
- 纯展示型 context 文本

## 5. Proposed Ownership Boundary

### Godot runtime 负责

- 内存中的即时状态
- 物理、寻路、动画、交互执行
- tick 推进后的 commit

### Backend / SQLite 负责

- 持久化真值表
- schema / migration
- 查询接口
- runtime 重启恢复时的装载

### Worker 负责

- 只读这些状态的“裁剪视图”
- 把 world state 转成 agent prompt 可消费的 context
- 不直接拥有 hp、inventory、crop moisture 这类数字真值

这和 [runtime-layers.md](./runtime-layers.md) 的脑/身分层一致，不引入第二个数字状态权威。

## 5.5 Restart Semantics Matrix

重启时，不同类型的数据按下面 3 类处理：

- **恢复**：重启后继续生效，是世界连续性的一部分
- **保留但不直接恢复执行**：历史和 Agent 连续性要保留，但不会把运行中的过程无脑接着跑
- **丢弃并重建**：纯运行时缓存

| 数据类别 | 处理方式 | 说明 |
|---|---|---|
| `town_states` | 恢复 | `gameTime`、天气、季节从停机前状态继续 |
| `character_states` | 恢复 | 角色位置、数值、装备、存活状态继续有效 |
| `item_instances` | 恢复 | 背包、地面掉落、容器内容、耐久等继续有效 |
| `farm_plots` | 恢复 | 作物 stage / moisture / pest / fertility 保持停机瞬间状态 |
| `active_effects` | 恢复 | buff / debuff / burning / scheduled events 恢复，但时间不补算 |
| `character_groups` | 恢复 | group 成员关系属于长期世界事实 |
| `runtime_storage` | 恢复 | Agent runtime 长期记忆 / KV 状态属于世界的一部分 |
| `world_events` | 保留但不直接恢复执行 | 保留历史、审计和 Agent 连续性，不把历史事件 replay 成当前真值 |
| `agent_sessions` | 恢复 | Agent 会话摘要、压缩状态、usage 等要恢复 |
| `agent_session_messages` | 恢复 | Agent 历史消息要恢复，支持连续扮演和后续压缩 |
| `action_log` 终态 | 保留但不直接恢复执行 | `completed / failed / cancelled` 只保留历史和工具结果 |
| `action_log` 非终态 | 保留并转恢复流程 | 保留记录，但重启后要经过显式恢复策略，不是盲目续跑 |
| `runtime_sessions` | 保留但不直接恢复执行 | 只做连接历史和调试 |
| WebSocket / heartbeat / ack | 丢弃并重建 | 纯连接态 |
| 当前寻路路径 / 动画播放状态 / nearby 列表 | 丢弃并重建 | 纯 runtime 内存态 |
| in-flight LLM call | 丢弃并重建 | 只恢复会话历史，不恢复“思考到一半”的执行栈 |

### 5.5.1 Action 的重启策略

`action_log` 需要单列规则，因为它处在“Agent 决策”和“Godot 运行时执行”之间。

建议：

- `completed / failed / cancelled`：原样保留，纯历史
- `submitted`：尚未投递给 Godot，可以重发或统一失败，取决于当时是否有 agent-host connection
- `pushed / accepted / cancelling`：**不要盲目续跑**

对 `pushed / accepted / cancelling` 有两种可选策略：

1. **MVP 推荐**：启动时统一标记为 `failed`，错误原因如 `runtime_restarted`
2. 后续增强：只对显式声明 `resumable` 的 action 做恢复，其余仍失败

MVP 先选策略 1，语义最清晰，也最不容易出现“动作执行到一半，世界和 Agent 对不上”的问题。

## 6. Rollout Plan

### Milestone A：把角色和物品从“文本上下文”升级成真值表

目标：

- 角色数值有正式落点
- 背包 / 装备 / 地面物品能查

工作：

- 新增 `character_states`
- 新增 `item_instances`
- runtime 启动时从 DB hydrate
- agent context 改为先读真值表，再渲染成 prompt 文本

### Milestone B：把农田和时间推进纳入持久化

目标：

- runtime 重启后作物不丢状态
- hunger / rest / crop growth 有统一时间基准

工作：

- 新增 `town_states`
- 新增 `farm_plots`
- slow tick 只改内存，按 tick 边界或批次 flush 到库

### Milestone C：把持续效果 / 定时器正规化

目标：

- buff、燃烧、腐烂、未来剧情定时器都可恢复

工作：

- 新增 `active_effects`
- runtime 启动时重建 effect scheduler

### Milestone D：收口 context 快照职责（已落地）

目标：

- snapshot 不承担"隐式真值缓存"

工作：

- ✅ 用 perception manifest（id 清单）替换 snapshot bundle，agent host 只缓存 id 列表 + 自身位置
- ✅ 所有角色数值 / 背包 / 装备 / 农田 / 工作台数据由 `services/world-state/*-repo.ts` 当场 SELECT 真值表拼装
- ✅ backend 不持有任何 game-world schema 所有权

## 7. Migration Strategy

### 7.1 不做“一次性大重构”

建议按表分阶段落地，每阶段遵循：

1. 先建表
2. runtime 双写一段时间
3. 读路径切到新表
4. 删掉临时 JSON 依赖

### 7.2 `world_events` 保留，不回填成真值

不要尝试把历史事件完整 replay 成正式世界状态。成本高，且历史事件并不保证覆盖全部必要字段。

更现实的做法：

- 新表从“当前运行中的内存态”开始写入
- 必要时做一次性 seed
- 老事件继续只做历史

### 7.3 agent prompt 走 manifest + sqlite SELECT（已落地）

旧：worker 等 Godot 推送整包 snapshot bundle，缓存最新一份做 prompt。
新：worker 持有 per-character perception manifest 缓存（仅 id 列表），每次 think 当场用 manifest id 列表 SELECT 共享 sqlite 拼 view。优点：无 cache 失效——NPC B 在家 idle 时也能看到 A 远处刚种的 10 格，下次 think 重新 SELECT 即可。

### 7.4 恢复顺序要和 ownership 边界一致

重启后的推荐恢复顺序：

1. 读取 `town_states`
2. 读取 `character_states` / `item_instances` / `farm_plots` / `active_effects`
3. 读取 `runtime_storage`（含 `memory:*`）/ `agent_sessions` / `agent_session_messages`
4. 处理非终态 `action_log`
5. runtime 完成 hydrate 后，重新开始接受新的 action / event

不要反过来先恢复 Agent 再补世界状态，否则 prompt 很容易读到不完整世界。

## 8. Suggested SQLite Tables

```sql
character_states   -- 每角色当前态
item_instances     -- 物品实例 + 持有关系
farm_plots         -- 固定农田格状态
active_effects     -- 持续效果 / 定时事件
town_states        -- 每镇当前时间 / 天气 / season
```

现有表继续保留：

```sql
action_log
world_events
runtime_storage
agent_sessions
agent_session_messages
character_groups
runtime_sessions
```

## 9. Priority Summary

如果只按“常见游戏状态”排序，建议优先级是：

1. `character_states`
2. `item_instances`
3. `town_states`
4. `farm_plots`
5. `active_effects`

原因很简单：

- 角色和物品是所有玩法的底盘
- 时间是 slow tick 的底盘
- 农田是当前最明确的持续模拟玩法
- effects 是后续系统扩张的底层基建

## 10. SQLite vNext Draft

下面这部分不是泛泛的“应该有这些字段”，而是按当前 [schema.ts](../../backend/src/db/schema.ts) 的风格，给出下一版 SQLite 草案。

约定延续现有 schema：

- 主键默认 `TEXT`
- 时间戳默认 ISO `TEXT`
- 复杂结构默认 `JSON TEXT`
- enum 先用 `TEXT`，由应用层约束

### 10.1 `town_states`

一镇一行，作为 world snapshot 的顶层锚点。

```sql
CREATE TABLE IF NOT EXISTS town_states (
  townId TEXT PRIMARY KEY,
  gameTime TEXT NOT NULL,         -- JSON GameTimeSnapshot
  weather TEXT,
  season TEXT,
  lastSimulatedAt TEXT NOT NULL,  -- 最后一次 runtime commit 的 wall clock
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
```

说明：

- `gameTime` 先沿用现有 `GameTimeSnapshot` JSON，和 [protocol.ts](../../backend/src/godot-link/protocol.ts) 保持一致。
- `lastSimulatedAt` 是 wall clock，不是 game time；主要用于运维和调试。
- 停机期间 `gameTime` 不前进，所以重启恢复直接读这一行即可。

### 10.2 `character_states`

每角色一行。它是角色真值表，不是 agent prompt 视图。

```sql
CREATE TABLE IF NOT EXISTS character_states (
  townId TEXT NOT NULL,
  characterId TEXT NOT NULL,
  currentLocationId TEXT,
  position TEXT,                         -- JSON {x,y,z}
  rotation TEXT,                         -- JSON {x,y,z} or quaternion
  hp REAL NOT NULL,
  stamina REAL NOT NULL,
  hunger REAL NOT NULL,
  rest REAL NOT NULL,
  alive INTEGER NOT NULL,                -- 0 / 1
  temperature REAL,
  burning INTEGER NOT NULL DEFAULT 0,    -- 0 / 1
  activeStatuses TEXT,                 -- JSON
  derivedStats TEXT,                     -- JSON
  equippedRightHandItemId TEXT,
  equippedLeftHandItemId TEXT,
  equippedBodyItemId TEXT,
  equippedHeadItemId TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL,
  PRIMARY KEY (townId, characterId)
);
CREATE INDEX IF NOT EXISTS idx_character_states_town_location
  ON character_states (townId, currentLocationId);
CREATE INDEX IF NOT EXISTS idx_character_states_town_alive
  ON character_states (townId, alive);
```

说明：

- `alive` / `burning` 用 `INTEGER` 存布尔，和 SQLite 习惯一致。
- `activeStatuses` 先保留 JSON，等我们把 status / effect 的边界彻底理顺后再决定是否完全并到 `active_effects`。
- 装备槽先内联在这张表里，能更快落地；真要扩很多槽位，再拆 `character_equipment`。

### 10.3 `item_instances`

这张表是 inventory / ground / container / equipment 的统一实例层。

```sql
CREATE TABLE IF NOT EXISTS item_instances (
  id TEXT PRIMARY KEY,
  townId TEXT NOT NULL,
  itemDefId TEXT NOT NULL,
  ownerKind TEXT NOT NULL,               -- character | world | item | workstation | crop
  ownerId TEXT,
  locationId TEXT,
  slotKey TEXT,
  stackCount INTEGER NOT NULL DEFAULT 1,
  quality TEXT,
  durability REAL,
  temperature REAL,
  burning INTEGER NOT NULL DEFAULT 0,    -- 0 / 1
  customProperties TEXT,                 -- JSON
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_item_instances_town_owner
  ON item_instances (townId, ownerKind, ownerId);
CREATE INDEX IF NOT EXISTS idx_item_instances_town_location
  ON item_instances (townId, locationId);
CREATE INDEX IF NOT EXISTS idx_item_instances_town_slot
  ON item_instances (townId, ownerKind, ownerId, slotKey);
CREATE INDEX IF NOT EXISTS idx_item_instances_town_itemdef
  ON item_instances (townId, itemDefId);
```

说明：

- `ownerKind = world` 时，`ownerId` 可为空或指向某个 world anchor；MVP 不强求统一。
- `slotKey` 用来表达背包格、装备槽、容器槽位。MVP 不加唯一约束，避免一开始就把堆叠/容器规则锁死。
- 如果未来要支持“一个容器里多份同物品”，由 `id` 区分实例，不靠 `(ownerId, slotKey)`。

### 10.4 `farm_plots`

MVP 按固定田格建表，而不是一上来泛化到所有作物实例。

```sql
CREATE TABLE IF NOT EXISTS farm_plots (
  id TEXT PRIMARY KEY,
  townId TEXT NOT NULL,
  farmId TEXT NOT NULL,
  plotIndex INTEGER NOT NULL,
  cropDefId TEXT,
  stage TEXT,                            -- seed | sprout | vegetative | flowering | ripe | rotten | empty
  growthProgress REAL,
  health REAL,
  moisture REAL,
  pestLoad REAL,
  soilFertility REAL,
  lastWateredAt TEXT,
  lastWateredBy TEXT,
  currentlyBeingWorkedBy TEXT,
  currentActionType TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL,
  UNIQUE (townId, farmId, plotIndex)
);
CREATE INDEX IF NOT EXISTS idx_farm_plots_town_farm
  ON farm_plots (townId, farmId);
CREATE INDEX IF NOT EXISTS idx_farm_plots_town_stage
  ON farm_plots (townId, stage);
CREATE INDEX IF NOT EXISTS idx_farm_plots_town_worker
  ON farm_plots (townId, currentlyBeingWorkedBy);
```

说明：

- `cropDefId` 允许为空，表示空地。
- `stage` 允许为空或 `empty`，两种都能工作；我倾向统一写 `empty`，减少判空分支。
- `currentlyBeingWorkedBy` / `currentActionType` 是 runtime 协作态，但它们会影响 Agent 感知，所以值得落库。

### 10.5 `active_effects`

持续效果和 one-shot scheduled event 统一表。

```sql
CREATE TABLE IF NOT EXISTS active_effects (
  id TEXT PRIMARY KEY,
  townId TEXT NOT NULL,
  targetKind TEXT NOT NULL,              -- character | item | farm_plot | world
  targetId TEXT NOT NULL,
  effectType TEXT NOT NULL,
  params TEXT,                           -- JSON
  startedAt TEXT NOT NULL,
  durationMinutes REAL,
  fireAt TEXT,
  cancelIf TEXT,
  sourceCharacterId TEXT,
  sourceItemId TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_active_effects_town_target
  ON active_effects (townId, targetKind, targetId);
CREATE INDEX IF NOT EXISTS idx_active_effects_town_fireat
  ON active_effects (townId, fireAt);
CREATE INDEX IF NOT EXISTS idx_active_effects_town_type
  ON active_effects (townId, effectType);
```

说明：

- `durationMinutes` 和 `fireAt` 允许二选一；应用层保证至少一个有值。
- `cancelIf` 先按设计稿保留 `TEXT`，未来可以是表达式、枚举 key、或脚本 hook id。
- `targetKind` 不做外键，避免把 runtime 演进速度绑死在 SQLite 约束上。

### 10.6 与现有表的关系

这些新表和现有表的职责边界建议是：

- `town_states`：世界当前时钟和环境真值
- `character_states`：角色当前态真值
- `item_instances`：物品实例真值
- `farm_plots`：农田当前态真值
- `active_effects`：持续状态 / 定时任务真值
- `world_events`：历史流
- `character.perception_manifest`：id-only 视图缓存（in-memory，agent host 用做 SELECT 入参），不持久化
- `runtime_storage`（含 `memory:*`）/ `agent_sessions` / `agent_session_messages`：Agent 连续性

不要再让下面这些职责混在一起：

- 不能让 perception manifest 继续兼职角色数值和背包真值（manifest 只列 id；数值在 character_states / item_instances 表）
- 不能让 `world_events` 兼职物品位置查询
- 不能让 `agent_sessions` 兼职 world state

### 10.7 `schema.ts` 落地顺序

如果把这份草案转成 `backend/src/db/schema.ts`，我建议顺序是：

1. `town_states`
2. `character_states`
3. `item_instances`
4. `farm_plots`
5. `active_effects`

原因：

- `town_states` 是恢复锚点
- `character_states` 和 `item_instances` 会最早影响 context、inventory、装备
- `farm_plots` 依赖 town time 和角色/物品交互
- `active_effects` 虽重要，但落地时对 runtime tick 侵入更深

### 10.8 建表后第一批读写责任

为了避免“表有了但没人真正用”，建议第一批接线是：

- `town_states`：GameClock load/save
- `character_states`：角色 spawn/hydrate、数值更新、装备更新
- `item_instances`：拾取/丢弃/使用/装备/容器转移
- `farm_plots`：water/plant/harvest/remove_pest + slow tick flush
- `active_effects`：buff 到期、burning、未来的 scheduled event

这能保证建表不是纯文档动作，而是能形成闭环。
## 11. Open Questions

- `item_instances` 是不是从一开始就支持堆叠，还是 MVP 强制 `stackCount = 1`
- 装备槽是先放在 `character_states` 列里，还是一开始就拆 `character_equipment`
- `position` 要不要进库，还是 MVP 先只存 `currentLocationId`
- `farm_plots` 和未来 `crop_instances` 是不是现在就统一
- `active_statuses` 是直接挂 `character_states` JSON，还是复用 `active_effects`
- 非终态 action 未来是否要引入 `resumable` 标记；如果要，哪些 action 允许恢复

## 修订记录

- 2026-05-11：初版。基于当前 SQLite 真值范围和现有 architecture 文档，补出“常见游戏状态持久化规划”。
