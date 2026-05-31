// Agent-shared 是所有 agent runtime 共享的非策略代码：
// - utils/                通用类型工具、game time 工具、log format
// - name-resolver/        entity 名字 ↔ id 翻译（[[feedback_llm_id_name_boundary]]）
// - entity-descriptions/  把 entity 状态翻译成 LLM 可读的文本（lore / farm / workstation）
// - event-descriptions/   把 WorldEvent 翻译成 LLM 可读的文本（say / trade / 通用）
// - event-semantics/      事件 actor / 分类（classifyEventForCharacter）
// - action-semantics/     action lane / body action / 剩余时长估算
// - notices/              continued action 队列 + 渲染
// - game-tools/           完整 game toolset（不含 per-agent 的 update_memory）
// - prompt-context/       perception manifest 装配 + 共享 section renderer + 类型
//
// Per-agent 自己维护：memory、session loop、prompt 编排器、agent-specific reaction 表。
// 见 [[feedback_agent_memory_strategy_per_agent]] / [[project_agent_runtime_design]]。

export * as utils from "./utils/index.js";
export * as nameResolver from "./name-resolver/index.js";
export * as entityDescriptions from "./entity-descriptions/index.js";
export * as eventDescriptions from "./event-descriptions/index.js";
export * as eventSemantics from "./event-semantics/index.js";
export * as actionSemantics from "./action-semantics/index.js";
export * as notices from "./notices/index.js";
export * as gameTools from "./game-tools/index.js";
export * as promptContext from "./prompt-context/index.js";
