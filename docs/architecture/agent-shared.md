# Agent-shared

> Status: **landed** — `backend/src/agent-shared/` 已实装。当前唯一 LLM runtime（two-track-agent）从这里取所有非策略代码；未来加新 runtime 时按本文 §3 的规则决定是放 shared 还是 per-agent。
>
> **Scope**：本文档描述 agent runtime 之间共享的、与"策略"无关的代码模块。具体 runtime 使用方式见 [two-track-agent-session.md](./two-track-agent-session.md)；host 通用层见 [backend-agent-host.md](./backend-agent-host.md)。

agent-shared 是个明确的分层：把"任何 LLM agent 都需要的、和具体决策策略无关的工具"集中到 `backend/src/agent-shared/`，让每个 runtime 只关心自己的核心差异（memory 策略、session 调度、prompt 编排）。

## 1. 共享 vs Per-agent 的边界

| 类别 | 归属 | 理由 |
|---|---|---|
| Entity 名字 ↔ id 翻译 | **shared** | LLM 边界约定（[[feedback_llm_id_name_boundary]]），所有 agent 用同一份翻译表 |
| 事件分类（hard / sensory / ignored） | **shared** | 世界事件的客观语义不随 agent 变化 |
| 事件渲染成文本（"X 对你说: ..."） | **shared** | 同一事件给所有 agent 看应是同一句话 |
| Action lane 判定 / 剩余时长估算 | **shared** | 跟世界物理挂钩，agent 改不了 |
| Continued action 队列 / notice 渲染 | **shared** | Detached body action 完成后追加给 LLM 的机制是通用的 |
| Game tool 工厂（say_to / move_to / ...） | **shared** | tool 是 Godot 协议的 1:1 包装，所有 agent 该看到同一套 |
| Perception manifest → context 装配 | **shared** | 世界翻译层，不是 agent 决策 |
| `update_memory` tool | **per-agent** | memory 写入策略是 agent 的核心差异（[[feedback_agent_memory_strategy_per_agent]]）：要不要写、何时写、淘汰策略、注入回 prompt 的格式 |
| Memory 持久化 / 表 | **per-agent** | 每个 agent 自维护独立 sqlite 表，schema 不共享 |
| Session loop（turn 调度 / abort / queueing） | **per-agent** | two-track 无打断机制走顺序队列；未来 agent 可能完全不同 |
| Prompt 编排（system 段顺序 / user 模板） | **per-agent** | section 顺序是 agent 策略——two-track 有 working_memory 段，未来 agent 可能没有 |
| Agent 反应表（哪些事件触发新 turn） | **per-agent** | 不同 agent 对同一事件可以决定 react / 不 react；two-track 的 `shouldTriggerActionTurn` 是它自己的策略 |

**核心原则**：shared 只放"世界翻译层"和"通用工具"，不掺进 agent 怎么决策、怎么记忆、怎么调度。

## 2. 模块清单

```
backend/src/agent-shared/
├── index.ts                       # barrel re-export，namespace-style：import { gameTools, nameResolver } from "agent-shared"
├── utils/                         # 通用 helper
├── name-resolver/                 # entity 名字 ↔ id 翻译
├── entity-descriptions/           # entity 状态翻译成 LLM 可读文本
├── event-descriptions/            # WorldEvent → LLM 可读文本（say_to → "X 对你说..."）
├── event-semantics/               # 事件的 actor / 分类
├── action-semantics/              # action lane / 剩余时长
├── notices/                       # continued action 队列 + 渲染
├── game-tools/                    # 完整 game tool set（不含 per-agent update_memory）
└── prompt-context/                # perception manifest 装配 + 共享 section renderer + 类型
```

### 2.1 `utils/`

无副作用纯工具。任何层都可以 import。

| 文件 | 内容 |
|---|---|
| `primitives.ts` | `finiteNumber / stringValue / stringArray / objectValue / arrayValue / pickString / numberValue / stableHash` |
| `game-time.ts` | `gameTimeTotalMinutes / eventGameMinuteValue / gameTimeFromEventData / gameDayKey` |
| `agent-message.ts` | `userMessage / isUserMessage / isAssistantMessage / agentMessageRole / assistantUsage / usageTokenCount / persistedMessageKey` |
| `log-format.ts` | `sanitizeForLog / extractToolCalls / formatContentText / serializeSessionMessage / snapshotAgentTools` + 敏感 key 屏蔽 |
| `text.ts` | `trimText(value, maxChars)` — 截断 + 国际化截断标记 |

### 2.2 `name-resolver/`

LLM 只看人类名字（中文），所有 input / output 在 tool 边界做 id ↔ 名字双向翻译。详见 [[feedback_llm_id_name_boundary]]。

| 文件 | 责任 |
|---|---|
| `alias-index.ts` | `buildAliasIndex(ids, aliasesForId, normalize)` + 几种 normalize 策略（slug / character / item / attribute）|
| `_simple-entity.ts` | `createSimpleEntityResolver({ i18nNamespace, loadIds, normalize })` 工厂——item / workstation / container / material / attribute 都用它生成 |
| `character.ts` | 角色 resolver（含运行时注册的 player + npcs.json 静态名）|
| `location.ts` | location 用 `location.<id>.alias` 而不是 `.name` |
| `item.ts` / `workstation.ts` / `container.ts` / `material.ts` / `attribute.ts` | 由 simple-entity 工厂生成，各自 normalize 策略稍异 |
| `site.ts` | `resolveNavigableSiteIdByName`：location 失败再试 workstation；用于 `move_to_location` 兜底 |
| `localize.ts` | `localizeValue / localizeStringValue / localizeText`：把内部值（id / token）转成当前 locale 文本 |
| `source-data.ts` | 加载 catalog 真值源：`npcs.json` / `locations.json` / `data/i18n/zh/{items,workstations,...}.json`。**任何 IO 错误直接 throw** 带路径——历史踩过 catch 吞错导致全表静默变空 |
| `index.ts` | barrel + `normalizeCharacterId` 兜底 |

**为什么不让每个 agent 自己写 resolver**：i18n 翻译就一份真值（`data/i18n/zh/items.json` 给 Godot UI 和 backend LLM 共用），各 agent 重复实现只会增加不一致。

### 2.3 `entity-descriptions/`

entity 当前状态 → 给 LLM 看的一段文本（不是 entity 名字翻译，是状态翻译）。

| 文件 | 内容 |
|---|---|
| `lore.ts` | `getDefaultWorldLore / getFactBoundaryRules / getCommonSense / getDefaultReignEraName`：稳定的世界设定文案 |
| `farm.ts` | `farmDisplayName / formatFarmSummary` + per-slot 状态行 + 连续空格折叠 range |
| `workstation.ts` | `workstationDisplayName` |
| `index.ts` | barrel |

### 2.4 `event-descriptions/`

WorldEvent → LLM 可读文本。每个 event 类型一个 renderer。读 `event.data` 时严格按 `backend/src/godot-link/world-events.ts` 定义的 `WorldEventDataByType` 单 key 读，不写 alias fallback（详见 [godot-agent-protocol.md §3.2](./godot-agent-protocol.md#32-event)）。

| 文件 | 内容 |
|---|---|
| `say.ts` | `renderSayToEventText`：把 say_to event 渲染成 `"X 对你说: ..."` 等格式 |
| `trade.ts` | `renderOfferTradeEventText / renderRespondToTradeEventText` |
| `index.ts` | `renderEventText / renderEventSummary / renderEventGameTimeLabel / isSayToEventType / eventNormalizedGameTime` 通用入口 |

新增 event 类型 → 先在 `world-events.ts` 加 typed shape，再在这里加 renderer，所有 agent 立刻能用上。

### 2.5 `event-semantics/`

事件的客观语义。**不**包含"agent 该不该 react"——那是 per-agent。

| 文件 | 内容 |
|---|---|
| `actor.ts` | `eventActorId / isPlayerActor / directSpeechTargetIds / resolveCharacterIdsForEvent`。Wire 契约已收口（actor 走 `event.actorId` 顶层，target / 受影响人都走 `data.targetCharacterId` / `data.affectedCharacterIds` 单 key），这里只做 slug 归一不再做 alias 翻译 |
| `classification.ts` | `EventSemanticKind = "hard_interrupt" \| "sensory" \| "ignored"`, `EventInterruptKey = "hard" \| "direct_speech" \| "ambient_sensory"`, `classifyEventForCharacter()` + 常量 `ALWAYS_INTERRUPTING_EVENTS / SENSORY_EVENT_TYPES` |
| `index.ts` | barrel |

**Per-agent 那部分**（哪些事件触发自己起 turn）：
- two-track 的 `shouldTriggerActionTurn` 和 `isSignificantForThinking` 在 `runtimes/two-track-agent/semantics/events.ts`

### 2.6 `action-semantics/`

Action 的客观属性。哪些 tool 是 body action、哪些是 speech / mental，剩余时长怎么估。

| 文件 | 内容 |
|---|---|
| `index.ts` | `ActionLane / ActionSemantics / actionSemantics / toolActionLane / isBodyAction / shouldToolInterruptContinuedWork / estimateRemainingBodyActionGameMinutes` + workstation / farm / sleep 各自的剩余时长估算器 |

### 2.7 `notices/`

Continued action（detached 长 body action）的队列管理 + 给 LLM 的 notice 文本渲染。

| 文件 | 内容 |
|---|---|
| `queue.ts` | `ContinuedActionManager`：`restore / markToolResult / hasOpenBodyAction / firstOpenBodyAction / cancelOpenBodyAction / hasQueuedNotices / consumeNotices / activeIntentLine`；持久化 in `runtime_storage.continued_actions:v1` |
| `render.ts` | `renderActionNotices`（多条 notice 合并成一段 user message）+ `renderUseWorkstationToolResultPrompt`（workstation tool result 改写）+ workstation context builder（约 350 行的渲染细节）|
| `index.ts` | barrel |

### 2.8 `game-tools/`

完整 game tool 工厂集。**不包含 `update_memory`**——那个工具的 schema 在这里 export 出来，但实际 tool 实例由 per-agent 自己组装（见 [[feedback_agent_memory_strategy_per_agent]]）。

| 文件 | 内容 |
|---|---|
| `factory.ts` | `createSharedGameAgentTools(options)`：返回 18 个 tool 数组（say_to / move_to_location / pick_up_item / use_item / use_workstation / plan_farm_work / start_trade / respond_to_trade / equip_item / unequip_item / give_item / drop_item / open_container / close_container / put_in_container / take_from_container / sleep / do_nothing 等） |
| `tool-factories.ts` | 每个 tool 单独的 factory 函数 |
| `schemas.ts` | TypeBox schema 集合，包括 export `updateMemorySchema` 给 per-agent 拼装用 |
| `targets.ts` | `resolveItemTarget / resolveContainerTarget / resolveWorkstationTarget / resolveLocationOrSiteTarget / resolveOptionalKnownTargetName` —— 名字 → id 翻译的 tool 边界 |
| `action-results.ts` | tool 执行后给 LLM 的文本格式（"已使用 X" / "已交付到 Y" 等）|
| `character-changes.ts` | Godot ack 里 character_changes 字段的渲染 |
| `i18n.ts` | tool description / label 的 i18n key 取值 |
| `types.ts` | tool 公共类型 |
| `index.ts` | barrel re-export，包括 `updateMemorySchema` / `MemoryToolDetails` / `UpdateMemoryParams` |

**Per-agent 怎么用**：
```ts
// runtimes/<agent>/memory-tool.ts
export function createRuntimeUpdateMemoryTool(storage, townId, characterId) {
  return createToolFromSharedSchema(updateMemorySchema, async (args) => {
    // Per-agent strategy decides how memory_index/new_string are interpreted and stored.
  });
}
```

### 2.9 `prompt-context/`

Perception manifest → 装配出 `AgentCurrentContext` / `GameAgentContext` —— 这是世界翻译，不是 prompt 编排（prompt 编排留 per-agent）。

| 文件 | 内容 |
|---|---|
| `types.ts` | `AgentCurrentContext / GameAgentContext / DistanceBandContext / FarmContext / WorkstationContext / ShelfContext / InteractiveSiteContext / AgentMemoryKind / PromptMemoryRecord / WorkingMemorySnapshot` 等全部 perception context 类型 |
| `assemble-from-manifest.ts` | 入口：manifest + repos SELECT → AgentCurrentContext。约 500 行 |
| `events.ts` | `isEventRelevantToCharacter / isCharacterContextEvent`：事件可见性闸 |
| `sections.ts` | `renderNearbyEnvironmentSections / renderInteractiveSitesSection`：共享的 section 渲染器（per-agent renderer 可以挑用） |
| `time.ts` | 游戏时间格式化（`formatGameDate / formatGameTime / gameTimeFromRecord / normalizeGameTime / pad2`）|
| `index.ts` | barrel |

**Per-agent 那部分**：
- system / user prompt 的 section 顺序、章节标题、固定文案——在 `runtimes/<agent>/prompt/context/renderer.ts` 自己写。共享的只是单个 section 的渲染函数和数据结构。

## 3. 加新模块的规则

下次想往 agent-shared 加东西前，先问自己：

1. **这个模块对所有 agent 是同一份语义吗**？（"X 对 Y 说话" 渲染成什么文本——是 → 共享；"听到 Y 说话该不该打断我的 thinking"——否，per-agent）
2. **它依赖某个 agent 的内部状态吗**？（依赖就一定 per-agent；纯函数 / 仅依赖 ctx / 仅依赖世界真值 → 可共享）
3. **如果两个 agent 想用得稍微不同，能用参数表达吗**？（能 → 共享带配置；不能 → per-agent 自维护一份）

不通过的 → 留在 `runtimes/<agent>/`。"以后可能多个 agent 都要用" 不构成共享理由——等真有第二个 agent 复用时再抽。

## 4. 与其它文档

- two-track-agent 怎么用 shared：[two-track-agent-session.md](./two-track-agent-session.md)
- AgentRuntime / host 通用层：[backend-agent-host.md](./backend-agent-host.md)
