// SQLite schema bootstrap for **brain tables only**. 在 plugin boot 时执行；
// 表已存在则 no-op。
//
// 所有权边界：
// - **本文件只管 brain 表**：action_log / runtime_storage /
//   agent_sessions / agent_session_messages。这些
//   是 LLM/agent runtime 的产物，backend 是真值方。
// - **game-world 表（character_groups / world_events / runtime_sessions）
//   由 Godot 端 `src/autoload/db.gd` 的 `_GAME_WORLD_SCHEMA` 建**。
//   backend 只读写、不创建。理由：游戏运行不能依赖 backend 是否启动过——
//   详见 [[feedback_backend_not_game_db_owner]]。
// - 这意味着 fresh checkout 必须先跑 Godot server 至少一次，让它建好 game-world
//   表，backend 之后启动才能 INSERT 进 runtime_sessions / world_events。
//
// 设计约定：
// - 所有 ISO 时间戳存 TEXT；ISO 8601 字典序 == 时间序，可直接比较 / ORDER BY
// - 复杂嵌套字段（target / result / data / message 等）存 JSON TEXT；
//   读出时由各 service 用 parseJson() 还原成对象
// - id 列默认 TEXT（业务侧生成，例如 createMessageId("action")）
// - 每个表保留之前 ensureIndexes 里定义的所有索引

export const SCHEMA_STATEMENTS = [
  // NOTE: runtime_sessions 和 world_events 由 Godot 端建表（src/autoload/db.gd
  // 的 _GAME_WORLD_SCHEMA）。backend 只 INSERT/SELECT，不在这里 CREATE。

  // runtime_storage：runtime-scoped KV，作为 runtime 长期记忆/状态持久化通道。
  `CREATE TABLE IF NOT EXISTS runtime_storage (
    runtimeName TEXT NOT NULL,
    townId TEXT NOT NULL,
    characterId TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,        -- JSON RuntimeStorageValue
    updatedAt TEXT NOT NULL,
    PRIMARY KEY (runtimeName, townId, characterId, key)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_runtime_storage_town_runtime_char ON runtime_storage (townId, runtimeName, characterId)`,

  // action_log：瘦身后的 action 观测/恢复表。Godot 仍是执行真值；backend 只记录 submit 和 ack。
  `CREATE TABLE IF NOT EXISTS action_log (
    actionId TEXT PRIMARY KEY,
    townId TEXT NOT NULL,
    characterId TEXT NOT NULL,
    action TEXT NOT NULL,
    target TEXT NOT NULL,       -- JSON canonical ActionTarget
    reason TEXT,
    priority INTEGER NOT NULL,
    expiresAt TEXT,
    gameTime TEXT,
    submittedAt TEXT NOT NULL,
    status TEXT NOT NULL,
    pushedAt TEXT,
    pushedMessageId TEXT,
    acceptedAt TEXT,
    acceptedGameTime TEXT,
    terminalAt TEXT,
    terminalGameTime TEXT,
    terminalStatus TEXT,
    error TEXT,
    result TEXT                 -- JSON canonical ActionResult
  )`,
  `CREATE INDEX IF NOT EXISTS idx_action_log_town_char_submitted ON action_log (townId, characterId, submittedAt DESC)`,
  `CREATE INDEX IF NOT EXISTS idx_action_log_town_status ON action_log (townId, status, submittedAt DESC)`,

  // agent_sessions：(townId, characterId, agentKind) UNIQUE
  // lastUsage* 是 debug timeline 用的累计统计；compaction 链路（summary/compactedBeforeSeq/...）
  // 已在 thinking-track 接管 working_memory + 长期 memory 后整套拆除，不再 schema-resident。
  `CREATE TABLE IF NOT EXISTS agent_sessions (
    id TEXT PRIMARY KEY,
    townId TEXT NOT NULL,
    characterId TEXT NOT NULL,
    agentKind TEXT NOT NULL,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    messageSeq INTEGER NOT NULL,
    lastUsage TEXT,                  -- JSON Usage
    lastUsageTokenCount INTEGER,
    lastUsageCostUsd REAL,
    lastUsageUpdatedAt TEXT,
    UNIQUE (townId, characterId, agentKind)
  )`,

  // agent_session_messages：(sessionId, seq) UNIQUE
  // toolsSnapshot / llmMessages：assistant 行专用，记录该次 LLM call 的输入快照（JSON）
  `CREATE TABLE IF NOT EXISTS agent_session_messages (
    id TEXT PRIMARY KEY,
    sessionId TEXT NOT NULL,
    townId TEXT NOT NULL,
    characterId TEXT NOT NULL,
    agentKind TEXT NOT NULL,
    seq INTEGER NOT NULL,
    role TEXT NOT NULL,
    message TEXT NOT NULL,           -- JSON AgentMessage
    createdAt TEXT NOT NULL,
    gameTime TEXT,                   -- JSON GameTimeSnapshot captured when message was persisted
    turnReason TEXT,
    toolsSnapshot TEXT,              -- JSON ToolSnapshot[]，仅 assistant 行写入
    llmMessages TEXT,                -- JSON AgentMessage[]，仅 assistant 行写入
    llmSystemPrompt TEXT,            -- 该次 LLM call 的 system prompt
    UNIQUE (sessionId, seq)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_session_messages_town_char_kind_seq ON agent_session_messages (townId, characterId, agentKind, seq DESC)`,

  // thinking_turns：two-track-agent 慢轨每次 LLM call 一行。debug timeline 上的 diamond 标记。
  // 与 agent_session_messages 不同：thinking 每次从零开始，不复用历史，因此用独立表，一行一次完整调用。
  `CREATE TABLE IF NOT EXISTS thinking_turns (
    id TEXT PRIMARY KEY,
    townId TEXT NOT NULL,
    characterId TEXT NOT NULL,
    triggerReason TEXT NOT NULL,
    intent TEXT,
    startedAt TEXT NOT NULL,
    endedAt TEXT NOT NULL,
    durationMs INTEGER NOT NULL,
    startGameTime TEXT,                 -- JSON GameTimeSnapshot
    endGameTime TEXT,                   -- JSON GameTimeSnapshot
    modelId TEXT,
    systemPrompt TEXT NOT NULL,
    userPrompt TEXT NOT NULL,
    assistantMessage TEXT,              -- JSON AgentMessage（含 thinking blocks + write_working_memory tool_call）
    writtenContent TEXT,
    previousMemoryUpdatedAt TEXT,
    usage TEXT,                         -- JSON pi-ai Usage
    totalTokens INTEGER,
    costUsd REAL,
    error TEXT
  )`,
  `CREATE INDEX IF NOT EXISTS idx_thinking_turns_town_char_started ON thinking_turns (townId, characterId, startedAt DESC)`,
  `CREATE INDEX IF NOT EXISTS idx_thinking_turns_town_started ON thinking_turns (townId, startedAt DESC)`,

  // NOTE: character_groups 由 Godot 端建表（src/autoload/db.gd 的 _GAME_WORLD_SCHEMA）。
  // backend service (services/character-groups-service.ts) 只 SELECT/INSERT/DELETE，不 CREATE。
];

// 新增列的幂等迁移；首次运行成功，之后失败被吞掉。
// 项目无 migration runner，按 memory 约定就地处理。
export const MIGRATION_STATEMENTS = [
  `ALTER TABLE agent_session_messages ADD COLUMN toolsSnapshot TEXT`,
  `ALTER TABLE agent_session_messages ADD COLUMN gameTime TEXT`,
  `ALTER TABLE agent_session_messages ADD COLUMN llmMessages TEXT`,
  `ALTER TABLE agent_session_messages ADD COLUMN llmSystemPrompt TEXT`,
  `ALTER TABLE agent_sessions ADD COLUMN lastUsageCostUsd REAL`,
  `DROP TABLE IF EXISTS character_contexts`,
  // user 行专用：把那一回合 LLM 实际看到的背包/装备槽快照存下来（结构化 JSON）。
  // 渲染后的 inventory/backpack 字符串数组已在 user message 文本里，但调试需要单独可视化。
  `ALTER TABLE agent_session_messages ADD COLUMN inventorySnapshot TEXT`,
];
