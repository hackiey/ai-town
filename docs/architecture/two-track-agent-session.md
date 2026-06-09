# Two-track agent session

> Status: **landed** — `backend/src/runtimes/two-track-agent/` 已实装，是当前唯一 LLM runtime；NPC 与 player command 都走它（player 用同一 runtime 的 player agentKind session）。
>
> **Scope**：本文档描述 `two-track-agent` runtime 的双 session 模型。agent host 通用层见 [backend-agent-host.md](./backend-agent-host.md)，host 共享代码见 [agent-shared.md](./agent-shared.md)。

每个 NPC 有两条独立的 LLM session 并发跑：**Action 轨**做快速反应（关 thinking），**Thinking 轨**做慢思考（开 extended reasoning），通过 `runtime_storage.working_memory` 这一份 KV 单向传递 brief。无打断机制，事件到达时若 turn 在跑就排队。

## 1. Context

早期单 session 实现（已删除的 `default-agent`）把"思考策略"和"行动产出"塞同一个 LLM session：extended thinking 一开动辄几十秒，事件到来时必须 abort 流式响应、合并新事件、重启 turn，复杂度集中在 110+ 处的 interrupt machinery。维护成本高、行为难以预期，所以拆成 two-track。

`two-track-agent` 把两件事拆开：

- **想"做什么"**：thinking 轨定时（默认每 15 游戏分钟）+ 关键事件触发，跑一次带 reasoning 的 LLM call，输出一段中文 working memory
- **执行**：action 轨关 thinking，每个 turn 入口读最新 working memory 注入 system prompt，立刻产出 tool call

两条 session 完全独立，没有 cross-track 锁。Action 没有 interrupt：事件到来时若当前 turn 还没结束，仅入队等下个 turn——前提是 action 模型本身延迟低（无 extended reasoning），等几秒可接受。

## 2. Design

### 2.1 双轨结构

```
PiAgentRuntime (per town)
├── sessions       : Map<(agentKind:townId:characterId), ActionTrackSession>
├── thinkingSessions: Map<(townId:characterId),         ThinkingTrackSession>
└── modelsCache    : Map<characterId, { action, thinking }>   // per-NPC 解析后双模型

每 NPC：
  ActionTrackSession ──reads── runtime_storage.working_memory ──writes── ThinkingTrackSession
                     (每 turn 入口)                                       (每次 think 末尾)
```

| | Action 轨 | Thinking 轨 |
|---|---|---|
| 类 | `ActionTrackSession`（`action-session/session.ts`） | `ThinkingTrackSession`（`thinking-track.ts`） |
| 触发 | 事件 / player command / continued action notice | 定时（默认 15 游戏分钟）+ significant 事件 / think-first |
| 模型 | `npcs.json` `agent_models.action`（建议 thinking="off"）| `npcs.json` `agent_models.thinking`（建议 thinking="low"+）|
| Tools | 完整 game tool set（`createTwoTrackAgentTools`），不含 `update_memory` | `update_memory` + `write_working_memory` |
| 历史持久化 | 走 `agent_sessions` / `agent_session_messages`（agentKind="npc" / "player"） | **不持久化**——每次重建 `Agent` |
| 输出 | tool call → action_log → Godot | `memory:*` KV 变更 + working_memory KV upsert |
| 是否中断 | 不可中断（事件入队等下 turn） | 不可中断（同 NPC 串行；fire-and-forget 启动） |

**为什么 thinking 不持久化**：每次 thinking turn 的 system prompt 已经把当前完整 perception manifest + 历史事件 + 上一份 working_memory 都塞进去；不需要再带 message 历史。还能避免和 action session 在 `(townId, characterId, agentKind)` 唯一键上冲突。

### 2.2 Working memory 传递

```
runtime_storage 表（per-character KV）：
  key = "working_memory"
  value = {
    content: string,        // thinking 轨用中文写的 brief（一般几段）
    updatedAt: string,      // ISO 时间
    triggerReason?: string, // "scheduled" / "event:say_to:..." / "event:woke_up:think-first"
    gameTime?: GameTimeSnapshot,
  }
```

- 写：`ThinkingTrackSession` 的 `write_working_memory` tool 执行时 upsert。`storage.set()` 同步 sqlite 事务，单次 JSON value。
- 读：`ActionTrackSession.runTurn` 入口调 `readWorkingMemoryFromStorage()`，注入 `GameAgentContext.workingMemory`，渲染到 system prompt `# 工作记忆` section（在 `fact_boundary` 和 `memory` 之间）。
- 缺失时整节省略——首次启动 / 全新角色 working_memory 没写，action 仍能跑（system prompt 不出该节）。

System prompt 自递归避免：thinking 自己不把"上一份 working_memory" 注入自己的 system prompt——而是放到 user message 里显式说"上一份是这样的，请更新"。否则 thinking 看着自己写的东西再写一遍，容易陷入回声。

### 2.2.1 长期 Memory

长期 Memory 同样存在 `runtime_storage`（`key = "memory:<id>"`），由 thinking 轨的 `update_memory` 维护。记录结构包含现实时间和游戏时间：

```
value = {
  id: string,
  townId: string,
  characterId: string,
  kind: "self_knowledge" | "common_sense" | "skill" | "other",
  text: string,
  importance: number,
  createdAt: string,
  lastAccessedAt?: string,
  createdGameTime?: GameTimeSnapshot,
  updatedGameTime?: GameTimeSnapshot,
  timeDisplay?: "auto" | "none",
}
```

- Prompt 渲染格式：`[序号] [时间] 正文`，或对稳定身份/常识/技能省略时间为 `[序号] 正文`。
- 序号只代表当前 prompt 里显示的顺序，不持久化；`edit/remove` 用 `memory_index` 指向它，不再用正文精确匹配。
- 时间按当前游戏时间降精度：24 小时内精确到分钟；24-72 小时显示清晨/上午/中午/下午/晚上/午夜；72 小时以前只显示日期。
- 价格类 seed memory 写入初始游戏时间并表述为“最近的价格是...”；这类价格是近期行情，可被后续交易和记忆更新改变。
- `other` 段按更新时间倒序截断，避免新近记忆被旧 key 顺序挤掉。

### 2.3 事件触发的三条路径

事件进来后，按事件性质走不同路径。`PiAgentRuntime.handleCharacterWorldEvent`：

```
event 到达
  ↓
isPlayerCommandEvent → session("player").onPlayerCommand → 入 reason 队列 "player_command"，启动 runTurnLoop
  ↓ 否则
isThinkFirstEvent(event) → 路径 A："先想再行动"
  ├─ await session(npc).appendEventToHistoryOnly(event)  // 把事件 stash 进历史，不触发 turn
  ├─ await thinkingSession.runThinkBlocking(...)         // 同步等 thinking 写完
  └─ await session(npc).onEvent(event)                   // 此时 turn 入口读到的是最新 working_memory
  ↓ 否则
session(npc).onEvent(event)
  ↓
  classifyEventForCharacter → kind ∈ {hard_interrupt, sensory, ignored}
  ├─ ignored → 仅 stash 进 pendingEvents（历史），不触发 turn
  ├─ ambient_sensory → 仅 stash（同上）
  └─ direct_speech / hard_interrupt → push reason，启动 runTurnLoop
  ↓
若 isSignificantForThinking(event) → 异步 void thinkingSession.requestThink(...)  // 不阻 action
```

**路径 A（think-first）**：当前只有 `woke_up`。角色刚醒，意识断了一整觉，第一反应前必须重建认知——blocking 等 thinking 写好 working_memory，action 才看得到"我醒了，今天打算做什么"。

**路径 B（significant for thinking）**：`spoken_to_directly` / 交易提议事件 / player 喊话 / always-interrupting 事件——异步触发 thinking 提前重写 working_memory；action 不等它，按自己节奏跑。下次 action turn 入口才会用上更新后的 brief。

**路径 C（普通）**：仅入历史 / 触发 action turn，thinking 不动。

### 2.4 Action 轨的 turn 调度

```
ActionTrackSession 内部状态：
  pendingEvents: WorldEventRecord[]  // 所有 relevant + globalAmbient 事件，turn 入口 snapshot，turn 后按 id trim
  pendingReasons: TurnReason[]       // 触发新 turn 的理由队列
  turnInFlight: boolean              // serialize flag

runTurnLoop():
  if turnInFlight: return  // 当前已在跑，等它结束时 outer loop 会重新看队列
  turnInFlight = true
  while reason = pendingReasons.shift():
    await runTurn(reason)              // ← 单 turn 完整流程
  turnInFlight = false
  void runPendingSleepSummary()
```

事件 mid-turn 到达：仅入 `pendingEvents` + 可能 push 到 `pendingReasons`。当前 turn 不 abort、不打断。turn 自然结束时循环看 `pendingReasons` 还有没有，有就接着跑。

`runTurn(reason)` 单 turn 流程：
1. reset 一堆 per-turn flag
2. `pendingSnapshot = [...pendingEvents]`
3. `ensureSession + persistence.drain + continuedActions.restore`
4. `currentContext = await ctx.getCurrentContext()` （perception manifest + SELECT sqlite）
5. `workingMemory = await readWorkingMemoryFromStorage()`
6. `context = contextBuilder.build({ ctx, current, pendingEvents: snapshot, workingMemory })`
7. 重建 tools（按当前 currentContext 动态生成）
8. messages = `assembleMessagesForModel(...)`（summary + continuity prefix + 历史 trim）
9. systemPrompt = `buildTwoTrackAgentTurnSystemPrompt(context)`
10. 渲染 user prompt：`renderTwoTrackAgentTurnUserMessage` + 可能拼一段 action notice
11. `runCurrentTurn(prompt)` ：LLM `prompt → continue ...` 直到 `stopAgentLoopThisTurn` 或队列空
12. `removeConsumedPendingEvents(pendingEvents, snapshot)` 按 id trim

### 2.5 一次性回应停 loop（保留的 stopArmed 机制）

没有 interrupt 机器，但保留一个 turn 终止策略：**sensory / player_command 触发的 turn，LLM 交付完一条 assistant message 即停 loop，不让继续 continue**。设计意图是 action 没有"自反思"——做完一件事就停下，避免 LLM 自言自语刷 tool。

实现（`onAgentEvent`）：
- `stopArmedForResponse = reason === "player_command" || reason === "sensory"`
- 收到 `message_end` 且是 assistant：
  - 含 tool calls：`responseMessagePendingTools = toolCalls.length`，`responseMessageBound = true`，等本 message 的所有 tool 跑完后 stop
  - 纯说话 message：直接 stop loop
- 收到 `tool_execution_end`：
  - `responseMessageBound` → 倒数 pending，归零 → stop loop + `agent.abort()`
  - `do_nothing` 成功 → 直接 stop loop（防 do_nothing 循环）

`interrupt` / `action_notice` reason 走完整 loop（hard interrupt 不走单次回应；action_notice 是后台动作完成提醒，让 LLM 自由决定下一步）。

### 2.6 模型配置：per-NPC 强制

**`npcs.json` 每个 NPC 必须显式写 `agent_models`**——two-track 启动时校验，缺则 fatal，不读 env 兜底。

```jsonc
{
  "keir_march": {
    "name": "...",
    "agent_models": {
      "action":   "dashscope:glm-5.1/off",   // 关 thinking 的 fast model
      "thinking": "dashscope:glm-5.1"         // 带 thinking 的 reasoning model
    },
    // ...其它字段
  }
}
```

- 两个 reference 都必须出现在 env `AGENT_AVAILABLE_MODELS` 列表里（启动时 `assertModelsAreAvailable` 校验）
- thinkingLevel 由配置决定（`/off` / `/low` / `/high`），不在 session 内 force——想让 action 也开一点 reasoning 也行；想让 thinking 关 reasoning 也尊重
- 解析器：`resolveTwoTrackAgentModels(config, identity, raw)` 在 `agents/model-registry.ts`，per-character 解析结果在 runtime per-character 缓存

**Qwen-style API 的二元 thinking**：dashscope 走 qwen `enable_thinking: true/false`，level 字段对它无效——`/low` 和 `/high` 都是 `enable_thinking: true`。`/off` 不发该参数，思考真正关闭。详见 `model-registry.ts` `inferOpenAICompletionsCompat` 把 dashscope baseUrl 识别成 qwen format 的路径。

### 2.7 Session 持久化与压缩

Action 轨用 `agent_sessions` / `agent_session_messages` 表（agentKind 列区分 "npc" / "player"），通过 `SessionPersistence` 串 append queue：

- `action-session/persistence.ts` —— ensureSession / append queue / updateSummary / markUsageCompressionChecked
- `action-session/messages.ts` —— `assembleMessagesForModel`：summary prefix + continuity prefix + recent N trim
- `action-session/continuity.ts` —— `renderSessionContinuity`：active intent / player commands / open threads / recent outcomes 拼一段 user message
- `action-session/compaction.ts` —— `SessionCompactor`：sleep summary（每游戏天最多压一次）+ token-emergency 压缩（超 `compressionTokenThreshold` 就压老消息）

Thinking 轨 **不入** `agent_sessions`——每次 turn 重建 Agent，无需 message 历史。

### 2.9 一图概览

```
                    Godot world event
                          │
            ┌─────────────┼──────────────────────────┐
            │             │                          │
            ▼             ▼                          ▼
       player_cmd    isThinkFirstEvent           其它事件
            │             │                          │
            │       appendEventToHistoryOnly         │
            │             │                          │
            │       await thinkingSession            │
            │       .runThinkBlocking                │
            │             │                          │
            ▼             ▼                          ▼
   session.onPlayerCommand    session.onEvent(event) ──┐
            │                          │               │
            └──── pendingReasons ──────┴───────────────┘
                          │
                          ▼
                  runTurnLoop (serial)
                          │
                          ▼
        runTurn → read working_memory → LLM → tool_calls → action_log → Godot

       并行：significant 事件 → void thinkingSession.requestThink()
              定时（15 游戏分钟）→ thinkingSession.onGameTime() → write working_memory
```

## 3. Implementation

文件结构：

```
backend/src/runtimes/two-track-agent/
├── index.ts                       # re-export runtime.ts
├── runtime.ts                     # PiAgentRuntime + TwoTrackAgentRuntime（AgentRuntime 实现）
├── thinking-track.ts              # ThinkingTrackSession + update_memory / write_working_memory tools
├── game-tools.ts                  # action 轨完整 toolset = shared（不含 update_memory）
├── memory-tool.ts                 # createTwoTrackUpdateMemoryTool（per-agent，不在 shared）
├── memory.ts                      # load/update two-track memory：写 runtime_storage memory:* KV
├── semantics/
│   └── events.ts                  # shouldTriggerActionTurn / isThinkFirstEvent / isSignificantForThinking
├── prompt/                        # system / user prompt 模板（per-agent，shared 不管编排）
│   ├── index.ts                   # barrel re-export shared + 本地 messages
│   ├── messages.ts                # buildTwoTrackAgent{Base,Turn}SystemPrompt + renderTurnUserMessage
│   ├── i18n.ts                    # 本 agent 的 locale getter
│   ├── context/
│   │   ├── builder.ts             # TwoTrackAgentContextBuilder（call assemble-from-manifest）
│   │   └── renderer.ts            # renderAgentSystemContext（含 working_memory 那节）
│   └── locales/{zh,en}/prompts.json
└── action-session/
    ├── index.ts                   # barrel
    ├── session.ts                 # ActionTrackSession 主类（~600 行）
    ├── persistence.ts             # SessionPersistence
    ├── messages.ts                # assembleMessagesForModel / trim
    ├── continuity.ts              # renderSessionContinuity
    └── compaction.ts              # SessionCompactor
```

**Action 轨 turn 进入点**（`session.ts`）：
- `onEvent(event)` — 普通事件
- `onPlayerCommand(event)` — 玩家命令直触发 turn
- `appendEventToHistoryOnly(event)` — think-first 用：仅 stash 进 pendingEvents（按 id dedup 防重入）
- `thinkIfGameTimeDue(_, gameTime)` — game time tick：仅 `observeGameTime`，不做 idle 思考
- `onContinuedActionNoticeQueued()` — 后台 detached action terminal → push action_notice reason

**Thinking 轨 entry**（`thinking-track.ts`）：
- `requestThink(reason)` — fire-and-forget；已在跑就只更 `queuedReason`
- `runThinkBlocking(reason)` — think-first 用：等当前 in-flight 跑完，再串行跑自己这一轮（绝不抢占）
- `onGameTime(gameMinute, gameTime)` — `nextThinkGameMinute` 到了 → `requestThink("scheduled")`

## 4. Open questions

- Working memory 长度上限（当前 hard cap 4000 chars in `write_working_memory` schema）；超长会被截，没有 graceful 压缩
- Thinking 轨失败（LLM 抛错 / 没调 `write_working_memory`）只 warn 不 retry——action 仍用旧 brief 跑，可能滞后
- Thinking 轨没 persist message 历史，如果想做"thinking 自己的反思链"必须新建表 + 不与 action `agent_sessions` 冲突
- 多 worker / failover 下两轨 session 的恢复一致性（thinking 不入表，重启后无状态可恢复，靠下一次定时 fire）
- Think-first 列表当前只有 `woke_up`；后续遇到"NPC 长时间脱离感知后回归"（被绑架释放、远途归来）也可能要加，但分类规则尚未抽象

## 5. 与其它文档

- 共享 vs per-agent 边界：[agent-shared.md](./agent-shared.md)
- AgentRuntime 接口、router、game tools 抽象：[backend-agent-host.md](./backend-agent-host.md)
- 进程拓扑：[runtime-layers.md](./runtime-layers.md)
