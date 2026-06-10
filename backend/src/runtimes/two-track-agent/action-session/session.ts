// Two-track action 轨 session：快速反应、关闭 thinking、消费 working_memory。
//
// 关键约束：
// - 新事件会先进入 pendingEvents；若 turn 在跑，轻量 interrupt/release 让下一次 LLM call
//   使用 fresh context，慢工具本体继续由 Godot 执行。
// - 没有 idle 思考——15 分钟一次的"想一下"由 ThinkingTrackSession 跑出
//   working_memory，本 session 每个 LLM call 入口读取它注入 user prompt。
// - 每条 assistant message 的 tool 都跑完后强制断开 pi-agent-core 续航，回到本层重装
//   working_memory / 感知 / 工具，再决定是否继续下一次 LLM call。
//
// 设计假设：action 轨延迟很低（无 extended thinking），事件到来时即便排队
// 也只多等几秒就会被消费，可接受。

import {
  Agent,
  type AfterToolCallContext,
  type AfterToolCallResult,
  type AgentEvent,
  type AgentMessage,
} from "@mariozechner/pi-agent-core";
import type { AgentRuntimeContext } from "../../../agent-host/runtime.js";
import type { AgentConfig } from "../../../config/env.js";
import type { GameTimeSnapshot, WorldEventRecord } from "../../../godot-link/protocol.js";
import type { CharacterAction } from "../../../godot-link/actions.js";
import { SAY_TO_ACTION } from "../../../godot-link/actions.js";
import {
  resolveAgentProviderApiKey,
  type AgentModelSelection,
} from "../../../agents/model-registry.js";
import type { AgentInventorySnapshot, AgentKind, AgentToolSnapshot } from "../../../agents/types.js";
import { ContinuedActionManager } from "../../../agent-shared/notices/queue.js";
import { renderActionNotices, renderUseWorkstationToolResultPrompt } from "../../../agent-shared/notices/render.js";
import { shouldToolInterruptContinuedWork } from "../../../agent-shared/action-semantics/index.js";
import { isKnownCraft } from "../../../agent-shared/game-tools/craft-registry.js";
import {
  isAssistantMessage,
} from "../../../agent-shared/utils/agent-message.js";
import {
  extractToolCalls,
  formatContentText,
  snapshotAgentTools,
} from "../../../agent-shared/utils/log-format.js";
import {
  gameTimeTotalMinutes,
} from "../../../agent-shared/utils/game-time.js";
import { objectValue } from "../../../agent-shared/utils/primitives.js";
import type {
  AgentCurrentContext,
  GameAgentContext,
  TimelineCursor,
  WorkingMemorySnapshot,
} from "../../../agent-shared/prompt-context/types.js";
import type { RuntimeStorage } from "../../../agent-host/storage.js";
import { createTwoTrackAgentTools } from "../game-tools.js";
import {
  buildTwoTrackAgentBaseSystemPrompt,
  buildTwoTrackAgentMemoryPinnedUserMessage,
  buildTwoTrackAgentTurnSystemPrompt,
  countUncompactedTimelineEntries,
  isEventRelevantToCharacter,
  renderTwoTrackAgentActionNoticeUserMessage,
  renderTwoTrackAgentTurnUserMessage,
  resolveCharacterIdByName,
  TwoTrackAgentContextBuilder,
  UNSUMMARIZED_TIMELINE_TRIGGER_COUNT,
} from "../prompt/index.js";
import { getActiveLocale, t } from "../../../i18n/index.js";
import {
  classifyEventForCharacter,
  decideAction,
  isSelfAuthoredSensoryEvent,
  reasonForClassifications,
  shouldTriggerActionTurn,
  type EventClassification,
} from "../semantics/events.js";
import type { PiAgentRuntimeLogger } from "../runtime.js";
import { computeActiveWorkLines } from "./active-work.js";
import {
  eventRuntimeState,
  InterruptWindow,
} from "./interrupt-control.js";
import { TurnReleaseController } from "../../../agent-shared/game-tools/release-controller.js";
import {
  assembleMessagesForModel,
} from "./messages.js";
import { SessionPersistence, type PersistAgentMessageSnapshot } from "./persistence.js";

const GLOBAL_AMBIENT_EVENTS = new Set(["weather_changed", "market_price_changed", "time_advanced"]);
const PENDING_EVENTS_CAP = 50;

// 与 ThinkingTrackSession.persistWorkingMemory 对偶的反序列化器。
export const WORKING_MEMORY_STORAGE_KEY = "working_memory";

export async function readWorkingMemoryFromStorage(storage: RuntimeStorage): Promise<WorkingMemorySnapshot | undefined> {
  const raw = await storage.get(WORKING_MEMORY_STORAGE_KEY);
  const rec = objectValue(raw);
  if (!rec) return undefined;
  const content = typeof rec.content === "string" ? rec.content : "";
  const emotionalState = typeof rec.emotionalState === "string"
    ? rec.emotionalState
    : typeof rec.emotional_state === "string"
      ? rec.emotional_state
      : undefined;
  const updatedAt = typeof rec.updatedAt === "string" ? rec.updatedAt : new Date().toISOString();
  const triggerReason = typeof rec.triggerReason === "string" ? rec.triggerReason : undefined;
  const gameTime = objectValue(rec.gameTime) as GameTimeSnapshot | undefined;
  const compactedThrough = parseTimelineCursor(rec.compactedThrough);
  return { content, emotionalState, updatedAt, triggerReason, gameTime, compactedThrough };
}

function parseTimelineCursor(value: unknown): TimelineCursor | undefined {
  const rec = objectValue(value);
  if (!rec) return undefined;
  const kind = rec.kind === "event" || rec.kind === "action" ? rec.kind : undefined;
  const id = typeof rec.id === "string" && rec.id.length > 0 ? rec.id : undefined;
  const createdAt = typeof rec.createdAt === "string" && rec.createdAt.length > 0 ? rec.createdAt : undefined;
  if (!kind || !id || !createdAt) return undefined;
  const gameMinutes = typeof rec.gameMinutes === "number" && Number.isFinite(rec.gameMinutes) ? rec.gameMinutes : undefined;
  return gameMinutes == null ? { kind, id, createdAt } : { kind, id, createdAt, gameMinutes };
}

export type ActionTrackSessionOptions = {
  ctx: AgentRuntimeContext;
  contextBuilder: TwoTrackAgentContextBuilder;
  config: AgentConfig;
  initialGameMinute?: number;
  initialGameTime?: GameTimeSnapshot;
  modelSelection: AgentModelSelection;
  townId: string;
  characterId: string;
  agentKind: AgentKind;
  logger?: PiAgentRuntimeLogger;
  requestTimelineBacklogThink?: () => void;
};

export class ActionTrackSession {
  // 已感知、未呈现给 LLM 的事件缓冲（onEvent 分类后非 ignored 才入队，自身/范围外不入）。
  // 每个 LLM 迭代入口抓 live 快照渲染、user message 持久化后按 id 移除——随到随显随清，不积压。
  // 是「当前触发」与历史段的源；turn 触发与否另算（见 pendingReasons）。
  private readonly pendingEvents: WorldEventRecord[] = [];
  // 未消费的"触发新 turn"理由队列。下一次 runTurnLoop 入口从这里拿；空了就停。
  private readonly pendingReasons: TurnReason[] = [];
  private readonly continuedActions: ContinuedActionManager;
  private readonly persistence: SessionPersistence;
  private readonly agent: Agent;

  private turnInFlight = false;
  private currentThinkReason?: string;
  private latestObservedGameMinute?: number;
  private latestObservedGameTime?: GameTimeSnapshot;

  // afterToolCall 上下文捕获——onPayload 抓 tools snapshot，每条 assistant message 落库时带上
  private currentToolsSnapshot?: AgentToolSnapshot[];
  private currentLlmMessagesSnapshot?: AgentMessage[];
  private currentLlmSystemPrompt?: string;
  // 本 LLM iteration 的 pinned Memory user message body（runCurrentTurn 装配 context 后填）。
  // transformContextForModel 可能脱离 context 重装 messages，复用这份缓存保持 pin 稳定。
  // 新 turn / 新 iteration 入口会被覆盖。
  private currentMemoryPin?: string;
  // 每次 LLM call 入口（renderTurnPrompt 前）从 context.current 抓一份；user 消息 message_end 落库时带上。
  // 持久化后清掉，避免后续 toolResult / assistant 行被误标。
  private currentInventorySnapshot?: AgentInventorySnapshot;

  // turn 内状态：限流/停 loop
  private toolCallsThisTurn = 0;
  private stopFurtherToolsThisTurn = false;
  private stopAgentLoopThisTurn = false;
  private stopFurtherToolsReason?: string;
  private blockRemainingToolCallsThisMessage = false;
  // 单次 LLM call 内是否有 tool 真的跑了——决定 runCurrentTurn 要不要再起一轮。
  // 不用 state.messages 判断，因为 pi-agent-core abort 路径会塞一条 fake aborted assistant 在末尾。
  private toolExecutedThisLlmCall = false;

  private publicThinkingActive = false;
  private publicThinkingStatusQueue: Promise<void> = Promise.resolve();

  // 打断机制状态：
  // - releaseController: turn 生命周期；runTurn 入口 new，finally 清空。
  //   注入到 game-tools.interrupts，让 plan_farm_work 等慢 tool 在 Promise.race 里 race 它的 waitForInterrupt。
  // - activeToolExecutions: tool_execution_start/_end 增减，用于判 idle/thinking/tool_waiting 三态。
  // - interruptWindow: 一个 turn 内只 fire 一次打断，避免同 turn 内多事件触发多次 release/abort。
  private releaseController?: TurnReleaseController;
  private activeToolExecutions = 0;
  private readonly interruptWindow = new InterruptWindow();
  // tool_execution_end 不带原始入参（只有 toolName/result），但预提交失败补记 failed action_log 时
  // 需要 target（对谁说、说了什么）。在 _start 按 toolCallId 暂存 args，_end 取回后清掉。
  private readonly pendingToolArgs = new Map<string, unknown>();
  private readonly completedToolCallIds = new Set<string>();
  private readonly recordedFailedToolCallIds = new Set<string>();

  constructor(private readonly options: ActionTrackSessionOptions) {
    this.continuedActions = new ContinuedActionManager({
      actions: options.ctx.actions(),
      storage: options.ctx.storage(),
      logger: options.logger,
      logContext: {
        townId: options.townId,
        characterId: options.characterId,
        agentKind: options.agentKind,
      },
      onNoticeQueued: () => this.onContinuedActionNoticeQueued(),
    });
    this.persistence = new SessionPersistence({
      ctx: options.ctx,
      townId: options.townId,
      characterId: options.characterId,
      agentKind: options.agentKind,
      logger: options.logger,
      getCurrentTurnReason: () => this.currentThinkReason,
    });
    if (options.initialGameTime) this.observeGameTime(options.initialGameTime);
    else if (options.initialGameMinute != null) this.observeGameMinute(options.initialGameMinute);

    this.agent = new Agent({
      initialState: {
        systemPrompt: buildTwoTrackAgentBaseSystemPrompt(),
        model: options.modelSelection.model,
        // Action 轨的 thinkingLevel 由 npcs.json agent_models.action 显式决定（一般是 "off"）。
        // 不在这里强制，以便偶尔需要"会一点点 reasoning 的 action 模型"时也能配。
        thinkingLevel: options.modelSelection.thinkingLevel,
        tools: createTwoTrackAgentTools({
          townId: options.townId,
          characterId: options.characterId,
          agentKind: options.agentKind,
          actions: options.ctx.actions(),
          memoryStorage: options.ctx.storage(),
          getCurrentContext: () => this.currentContextFromHost(),
        }),
        messages: [],
      },
      sessionId: `${options.agentKind}:${options.townId}:${options.characterId}`,
      getApiKey: (provider) => resolveAgentProviderApiKey(options.config, provider),
      onPayload: () => {
        // tools 是 createTwoTrackAgentTools 按 currentContext 动态生成的，每轮可能不同；
        // onPayload 在 LLM 请求实际发出前命中，抓快照随 assistant message 落库。
        this.currentToolsSnapshot = snapshotAgentTools(this.agent.state.tools);
        return undefined;
      },
      transformContext: (messages, signal) => this.transformContextForModel(messages, signal),
      toolExecution: "sequential",
      beforeToolCall: async ({ toolCall }) => {
        if (this.blockRemainingToolCallsThisMessage) {
          return { block: true, reason: t("error.tool_failure_self_correcting", getActiveLocale()) };
        }
        if (this.stopFurtherToolsThisTurn) {
          return { block: true, reason: this.stopFurtherToolsReason ?? t("error.interrupted_by_event", getActiveLocale()) };
        }
        this.toolCallsThisTurn += 1;
        if (this.toolCallsThisTurn > options.config.maxToolCallsPerTurn) {
          this.stopFurtherToolsThisTurn = true;
          this.stopFurtherToolsReason = t("error.tool_budget_exhausted", getActiveLocale());
          queueMicrotask(() => this.abortAgentWithReason("tool_budget_exhausted"));
          return { block: true, reason: this.stopFurtherToolsReason };
        }
        await this.continuedActions.restore();
        if (await this.continuedActions.hasOpenBodyAction() && shouldToolInterruptContinuedWork(toolCall.name)) {
          const cancelError = await this.continuedActions.cancelOpenBodyAction(toolCall.name);
          if (cancelError) return { block: true, reason: cancelError };
        }
        return undefined;
      },
      afterToolCall: async (context) => this.afterToolCall(context),
    });
    this.agent.subscribe((event) => this.onAgentEvent(event));
    options.logger?.info({
      townId: options.townId,
      characterId: options.characterId,
      agentKind: options.agentKind,
      model: options.modelSelection.reference.raw,
    }, "two-track action session created");
  }

  get townId(): string { return this.options.townId; }
  get characterId(): string { return this.options.characterId; }

  abort(): void {
    this.abortAgentWithReason("external_abort");
  }

  // pi-agent-core 的 abort() 不接 reason，无法把原因塞进 AbortSignal。
  // 这里在 logger 里留一行 warn，方便排查 action-log-service 的 "action wait aborted" 是谁触发的。
  private abortAgentWithReason(reason: string): void {
    this.options.logger?.warn({
      townId: this.options.townId,
      characterId: this.options.characterId,
      agentKind: this.options.agentKind,
      reason,
    }, "two-track action session aborting agent");
    this.agent.abort();
  }

  // 由 PiAgentRuntime 派发：常规 character world event。
  async onEvent(event: WorldEventRecord): Promise<void> {
    this.observeGameTime(event.gameTime);

    // 自己产生的 sensory 走 action.ack 路径回 LLM；这里直接短路。
    if (isSelfAuthoredSensoryEvent(event, this.options.characterId)) return;

    const relevant = isEventRelevantToCharacter(event, this.options.characterId);
    const globalAmbient = isGlobalAmbientEvent(event);
    if (!relevant && !globalAmbient) return;

    // 非 npc（玩家 session）：不做 npc 视角分类，保持原样累积。
    if (this.options.agentKind !== "npc") {
      this.appendPendingEvent(event);
      return;
    }

    // 先分类、再决定是否入队：被判 ignored 的事件（自身非 sensory 动作如 cook/shelf_updated、
    // 范围外）绝不进 pendingEvents——否则会无对应 reason 地滞留，被后续某个 turn 的渲染当成
    // "当前触发"倒出来（自己烤面包却被自己"触发"）。入队必须晚于这道闸门。
    const classification = classifyEventForCharacter(event, this.options.characterId);
    if (classification.kind === "ignored") {
      return;
    }

    this.appendPendingEvent(event);

    if (!shouldTriggerActionTurn(classification)) {
      // ambient_sensory：入队等下一个 turn 一并显示+清空，但自身不触发新 turn。
      return;
    }

    this.maybeDispatchInterrupt(reasonForClassification(classification), classification);
  }

  // 玩家命令是显式邀请回应：视同 hard_interrupt 走完整打断（idle 直接起；
  // 若 player session 已有 turn 在跑——罕见——也立刻抢占）。
  async onPlayerCommand(event: WorldEventRecord): Promise<void> {
    this.observeGameTime(event.gameTime);
    this.appendPendingEvent(event);
    this.maybeDispatchInterrupt("player_command", { kind: "hard_interrupt", interruptKey: "hard" });
  }

  // 后台 detached action 完成（plan_farm_work 等）→ 当作 action_notice 触发新 turn。
  // 不打断正在跑的 turn——NPC 在忙就让它忙完，notice 在队列里等下次自然 turn 边界消费。
  private onContinuedActionNoticeQueued(): void {
    if (this.options.agentKind !== "npc") return;
    this.enqueueReason("action_notice");
    void this.runTurnLoop();
  }

  // 三态调度核心。事件分类已完成，仅决定"立刻 fire 还是仅累积"。
  // - idle: 开新 turn（保留现路径）
  // - tool_waiting: release 让慢 tool 立刻返回 runtime_pending；turn_end 的 queueMicrotask abort
  //                 会触发 runCurrentTurn 看 stopAgentLoopThisTurn 退出，让 outer runTurnLoop
  //                 拉新 reason 起 fresh turn（next LLM call 拿到完整新 context）。
  // - thinking: 直接 abort 当前 LLM 流式输出；半截 assistant message 被 persistence 跳过；
  //             outer while 退出，runTurnLoop 拉新 reason。
  // 同 turn 内只 fire 一次（interruptWindow）——后续事件累积进 pendingEvents，被即将启动的
  // 新 turn（或当前 turn 的下一个 LLM 迭代）随到随显随清地一并消费。
  private maybeDispatchInterrupt(reason: TurnReason, classification: EventClassification): void {
    const state = eventRuntimeState({
      turnInFlight: this.turnInFlight,
      activeToolExecutions: this.activeToolExecutions,
    });
    const decision = decideAction(classification, state);
    if (!decision.shouldAct) return;

    if (state === "idle") {
      this.enqueueReason(reason);
      void this.runTurnLoop();
      return;
    }

    // turn 在跑：本 turn 已经 fire 过打断的话直接累积（事件已在 pendingEvents 里）
    if (this.interruptWindow.hasFiredThisTurn()) {
      this.enqueueReason(reason);
      return;
    }

    this.interruptWindow.markFired();
    this.enqueueReason(reason);
    // 让 runCurrentTurn 在下一个循环顶部退出，把控制权交还 runTurnLoop 起 fresh turn
    this.stopAgentLoopThisTurn = true;

    if (state === "tool_waiting") {
      // 不取消 Godot 端动作：release 只让 backend 这边的 Promise.race 解出 runtime_pending
      // 进度快照；ContinuedActionManager 把 action 标 detached_pending，Godot 端真实动作继续，
      // 完工时再走 onContinuedActionNoticeQueued 触发后续 turn 续上。
      this.releaseController?.release();
      // turn_end 处现有的 queueMicrotask(abort) 会接管，让 prompt() 返回；不重复 abort 避免误伤
    } else {
      // thinking：LLM 在 streaming，没有 turn_end 自然 fire，必须显式 abort
      this.abortAgentWithReason("interrupt_during_thinking");
    }
  }

  // 周期性 game-time tick。Action 轨不做 idle 思考——只推时钟。
  async thinkIfGameTimeDue(_gameMinute: number, gameTime?: GameTimeSnapshot): Promise<void> {
    if (this.options.agentKind !== "npc") return;
    if (gameTime) this.observeGameTime(gameTime);
  }

  // Thinking 轨写完 working_memory 后由 runtime 调用，确保空闲也能被周期总结唤醒。
  // 不打断当前 turn——若有 turn 在跑就排队等 turn_end 后 loop 自然消费。
  // working_memory 是最低优先级的兜底：入队不去重，但 runTurnLoop 消费时，若队列里还排着任何
  // 非 working_memory 的 reason，这一轮唤醒会被直接丢弃（见 runTurnLoop）。所以排队的
  // working_memory 被即时事件（sensory/interrupt/...）超越时不会占用一次 LLM turn。
  enqueueWorkingMemoryTurn(): void {
    if (this.options.agentKind !== "npc") return;
    this.enqueueReason("working_memory");
    void this.runTurnLoop();
  }

  // 预提交校验失败（工具在 submitToolAction 之前就 throw，如 resolveCraftWorkstation 翻不出 slug）
  // 不会建 action_log 行，于是失败动作在 debug 时间轴和下一轮 prompt 里找不到。
  // 这里补记一条 failed action_log（不发 Godot、不写 world_events），让失败动作有内部锚点。
  // 判据：error result（createErrorToolResult）的 details 里没有 actionId；Godot 提交后失败的
  // result 带 actionId，已有行，不重复记。返回 true 表示本次确实补记了内部失败 action。
  private recordPreSubmitToolFailure(toolName: string, result: unknown, args: unknown, toolCallId?: string): boolean {
    if (toolCallId) {
      if (this.recordedFailedToolCallIds.has(toolCallId)) return false;
      this.recordedFailedToolCallIds.add(toolCallId);
    }
    const details = objectValue(objectValue(result)?.details);
    if (details && typeof details.actionId === "string" && details.actionId) {
      return false; // Godot 已落行
    }
    const error = formatContentText(objectValue(result)?.content) ?? `${toolName} failed`;
    try {
      this.options.ctx.actions().recordFailed({
        characterId: this.options.characterId,
        action: toolName as CharacterAction,
        target: buildPreSubmitFailureTarget(toolName, args),
        reason: buildPreSubmitFailureReason(args),
        gameTime: this.latestObservedGameTime,
      }, error);
      return true;
    } catch (error) {
      this.options.logger?.warn({
        error,
        townId: this.options.townId,
        characterId: this.options.characterId,
        agentKind: this.options.agentKind,
        toolName,
      }, "failed to record pre-submit tool failure");
      return false;
    }
  }

  // 有些失败发生在 tool execute 前（参数 JSON/schema 解析失败等），不会出现
  // tool_execution_start/end。尽力从 assistant error message 里抽 tool_call，补成内部
  // failed action_log；下一轮 action prompt 会在同一事件时间线里看到这条反馈。
  private recordAssistantToolParseFailures(message: AgentMessage): boolean {
    const messageObject = objectValue(message) ?? {};
    const error = typeof messageObject.errorMessage === "string" && messageObject.errorMessage.trim()
      ? messageObject.errorMessage.trim()
      : "tool call failed before execution";
    let recorded = false;
    for (const toolCall of extractToolCalls(messageObject)) {
      if (!toolCall.name) continue;
      if (toolCall.id && this.completedToolCallIds.has(toolCall.id)) continue;
      const result = { content: [{ type: "text", text: error }] };
      recorded = this.recordPreSubmitToolFailure(toolCall.name, result, toolCall.args, toolCall.id) || recorded;
    }
    return recorded;
  }

  // --- Turn 调度 ---

  private enqueueReason(reason: TurnReason): void {
    this.pendingReasons.push(reason);
  }

  private async runTurnLoop(): Promise<void> {
    if (this.turnInFlight) return;
    this.turnInFlight = true;
    try {
      while (true) {
        // 优先按 push 顺序消费 reasons；空了就退出（不做 idle）。
        const reason = this.pendingReasons.shift();
        if (!reason) return;
        // working_memory 是最低优先级的兜底（防止 NPC 长时间不动），只在实在没别的事可做时才跑。
        // 队列里只要还排着任何非 working_memory 的 reason（sensory/interrupt/player_command/
        // action_notice），就丢弃这一轮唤醒：让即时事件以「回应」语义优先跑，也省掉一次
        // 无谓的 LLM 调用（感知事件本身由每个 turn 随到随显随清，不依赖这条丢弃逻辑兜底）。
        if (reason === "working_memory" && this.pendingReasons.some((pending) => pending !== "working_memory")) {
          continue;
        }
        await this.runTurn(reason);
      }
    } finally {
      this.turnInFlight = false;
    }
  }

  // --- 单 turn 执行 ---

  private async runTurn(reason: TurnReason): Promise<void> {
    this.currentThinkReason = reason;
    this.toolCallsThisTurn = 0;
    this.stopFurtherToolsThisTurn = false;
    this.stopAgentLoopThisTurn = false;
    this.stopFurtherToolsReason = undefined;
    this.blockRemainingToolCallsThisMessage = false;
    // 每 turn 独立的 release 控制器——前一 turn 的 waiters 已经 release 过或随 abort 失效。
    // 不复用 session 级实例，避免跨 turn 的旧 waiter 被新 release 误伤
    // （参 release-controller.ts 类头注释里的"一次性广播"约束）。
    this.releaseController = new TurnReleaseController();
    this.activeToolExecutions = 0;
    this.interruptWindow.reset();
    this.completedToolCallIds.clear();
    this.recordedFailedToolCallIds.clear();

    try {
      await this.persistence.ensureSession();
      await this.continuedActions.restore();
      await this.persistence.drain();
      // pendingEvents 的显示+清空已下沉到 runCurrentTurn 的每个 LLM 迭代里（随到随显随清），
      // turn 级不再抓快照、不再统一移除——避免长 turn 期间到达的事件溢到下一个 turn。
      await this.runCurrentTurn(reason);
    } catch (error) {
      this.options.logger?.error({
        error,
        townId: this.options.townId,
        characterId: this.options.characterId,
        agentKind: this.options.agentKind,
        reason,
      }, "two-track action turn failed");
    } finally {
      this.currentThinkReason = undefined;
      await this.setPublicThinkingStatus(false, reason);
      this.currentToolsSnapshot = undefined;
      this.currentLlmMessagesSnapshot = undefined;
      this.currentLlmSystemPrompt = undefined;
      this.currentMemoryPin = undefined;
      this.currentInventorySnapshot = undefined;
      this.releaseController = undefined;
      this.activeToolExecutions = 0;
      this.interruptWindow.reset();
      this.blockRemainingToolCallsThisMessage = false;
      this.completedToolCallIds.clear();
      this.recordedFailedToolCallIds.clear();
    }
  }

  // 每次 LLM call 都是独立 "iteration"：重读 working_memory + 当前感知，重装配 messages，
  // 渲染新 user message 后调 agent.prompt()。afterToolCall 强制 abort pi-agent-core 的内部
  // 续航，控制权回到这里 → 下一轮拿到的就是 thinking 写完之后最新的 working_memory。
  // 不再回喂历史 transcript：assembleMessagesForModel 只返回置顶 Memory pin，过去做过什么
  // 由本轮 user message 的近期事件时间线承担（transcript 仍持久化，只是不进 LLM 消息序列）。
  //
  // pendingEvents（感知缓冲）随每个迭代「随到随显随清」：迭代顶部抓当前 live 快照渲染，user
  // message 持久化后立即从缓冲移除。这样 turn 进行中（如连烤数炉、跨数游戏分钟）陆续到达的
  // 事件会被本 turn 后续迭代逐批显示+清空，不会积压溢到下一个 turn。
  private async runCurrentTurn(reason: TurnReason): Promise<void> {
    let llmCallCount = 0;
    const maxLlmCalls = Math.max(1, this.options.config.maxToolCallsPerTurn);

    while (true) {
      if (this.stopAgentLoopThisTurn || this.stopFurtherToolsThisTurn) return;

      // 本迭代的感知快照 = 此刻 live pendingEvents。下方 user message 持久化后即移除这些。
      const iterationEvents = [...this.pendingEvents];

      llmCallCount += 1;
      if (llmCallCount > maxLlmCalls) {
        this.options.logger?.warn({
          townId: this.options.townId,
          characterId: this.options.characterId,
          agentKind: this.options.agentKind,
          reason,
          llmCallCount,
        }, "two-track action turn exceeded LLM call cap");
        return;
      }

      const currentForCall = await this.currentContextFromHost();
      if (!currentForCall) return;
      const workingMemory = await readWorkingMemoryFromStorage(this.options.ctx.storage());
      const context = await this.options.contextBuilder.build({
        ctx: this.options.ctx,
        current: currentForCall,
        pendingEvents: iterationEvents,
        workingMemory,
      });
      this.observeGameTime(context.current.gameTime);
      this.alignContextGameTime(context);
      if (this.options.agentKind === "npc"
        && countUncompactedTimelineEntries(context) > UNSUMMARIZED_TIMELINE_TRIGGER_COUNT) {
        this.options.requestTimelineBacklogThink?.();
      }

      await this.persistence.drain();
      this.agent.state.tools = createTwoTrackAgentTools({
        townId: this.options.townId,
        characterId: this.options.characterId,
        agentKind: this.options.agentKind,
        currentContext: context.current,
        actions: this.options.ctx.actions(),
        memoryStorage: this.options.ctx.storage(),
        getCurrentContext: () => this.currentContextFromHost(),
        interrupts: this.releaseController,
      });
      this.agent.state.systemPrompt = buildTwoTrackAgentTurnSystemPrompt(context);
      this.currentMemoryPin = buildTwoTrackAgentMemoryPinnedUserMessage(context);
      this.agent.state.messages = await assembleMessagesForModel({
        persistence: this.persistence,
        renderMemoryPin: () => this.currentMemoryPin,
      });
      this.agent.clearAllQueues();

      this.currentInventorySnapshot = {
        inventory: [...context.current.inventory],
        backpack: [...context.current.backpack],
        walletCenti: context.current.walletCenti,
      };
      const userPrompt = await this.renderTurnPrompt(reason, iterationEvents, context);
      this.toolExecutedThisLlmCall = false;
      this.blockRemainingToolCallsThisMessage = false;
      await this.agent.prompt(userPrompt);
      await this.persistence.drain();

      // 持久化后清空本迭代显示过的事件。pi-agent-core 在 runAgentLoop 顶部同步无条件 emit
      // user message，早于流式与任何 abort 检查；只要 prompt() 跑了，user message 必已入持久化
      // 队列，drain 后即落库。故"先持久化、后移除"安全，不会显示而不落库、也不会移除而未显示。
      removeConsumedPendingEvents(this.pendingEvents, iterationEvents);

      if (this.stopAgentLoopThisTurn) return;

      // 是否再起一轮：本轮 LLM call 调了 tool 说明它想看结果继续做事——
      // 没调 tool 说明 LLM 自己已经决定停（纯说话 / end_turn）。
      // state.messages 末尾通常是 pi-agent-core abort 路径塞的 fake aborted assistant，不可信。
      if (!this.toolExecutedThisLlmCall) return;
    }
  }

  private async afterToolCall(context: AfterToolCallContext): Promise<AfterToolCallResult | undefined> {
    // 断开 pi-agent-core 续航的 abort 不在这里发——放到 turn_end（整条 assistant message 的所有 tool 都跑完之后），
    // 否则同一条 message 内 LLM emit 多个 tool 时，第二个 tool 会被前一个 tool 的 microtask abort 误伤
    // （pi-agent-core sequential 循环在 tool 之间不查 signal，第二个 tool 已进 waitForTerminal 才看到 abort）。
    // 10 个 axis tool 共享 workstation 结果模板
    // （toolResultDetails / target shape 完全一致，渲染逻辑无差别）。
    const toolName = context.toolCall.name;
    const isWorkstationTool = isKnownCraft(toolName);
    const overrideText = isWorkstationTool
      ? renderUseWorkstationToolResultPrompt(context)
      : undefined;
    const noticesText = await this.consumeQueuedActionNoticesText("同时完成的行动");
    if (!overrideText && !noticesText) return undefined;
    const baseText = overrideText ?? formatContentText(context.result.content) ?? "";
    return {
      content: [{ type: "text", text: [baseText, noticesText].filter(Boolean).join("\n\n") }],
    };
  }

  private async transformContextForModel(messages: AgentMessage[], signal?: AbortSignal): Promise<AgentMessage[]> {
    if (signal?.aborted) {
      this.captureLlmCallMessages(messages);
      return messages;
    }
    try {
      await this.persistence.drain();
      this.captureLlmCallMessages(messages);
      return messages;
    } catch (error) {
      this.options.logger?.error({
        error,
        townId: this.options.townId,
        characterId: this.options.characterId,
        agentKind: this.options.agentKind,
      }, "failed to transform agent context before llm call");
      this.captureLlmCallMessages(messages);
      return messages;
    }
  }

  private captureLlmCallMessages(messages: AgentMessage[]): void {
    this.currentLlmMessagesSnapshot = messages.map((message) => ({ ...message }));
    this.currentLlmSystemPrompt = this.agent.state.systemPrompt;
  }

  private async renderTurnPrompt(
    reason: TurnReason,
    pendingEvents: WorldEventRecord[],
    context: GameAgentContext,
  ): Promise<string> {
    // Triggering events = 本迭代的 pendingEvents 快照（随到随显随清）；不再区分 windowEvents。
    const activeWorkLines = await computeActiveWorkLines({
      ctx: this.options.ctx,
      characterId: this.options.characterId,
      continuedActions: this.continuedActions,
    });
    const base = renderTwoTrackAgentTurnUserMessage(reason, pendingEvents, pendingEvents, context, activeWorkLines);
    const noticeText = await this.consumeQueuedActionNoticesText("行动完成提醒");
    return [
      base,
      noticeText ? renderTwoTrackAgentActionNoticeUserMessage(noticeText) : undefined,
    ].filter(Boolean).join("\n\n");
  }

  private async consumeQueuedActionNoticesText(title: string): Promise<string | undefined> {
    const notices = await this.continuedActions.consumeNotices();
    if (notices.length === 0) return undefined;
    return renderActionNotices(title, notices);
  }

  // --- Agent 事件 ---

  private onAgentEvent(event: AgentEvent): void {
    if (event.type === "message_start" && isAssistantMessage(event.message)) {
      void this.setPublicThinkingStatus(true);
    }
    if (event.type === "message_end" && isAssistantMessage(event.message)) {
      void this.setPublicThinkingStatus(false);
    }
    if (event.type === "message_end") {
      const isAssistant = isAssistantMessage(event.message);
      // user 消息 = 本轮 turn 的 prompt（pi-agent-core 由 prompt() 入队）。
      // tool_result 走 toolResult role，不会命中这里。
      const isTurnUserMessage = event.message.role === "user";
      const snapshot: PersistAgentMessageSnapshot = {
        gameTime: this.latestObservedGameTime,
        toolsSnapshot: isAssistant ? this.currentToolsSnapshot : undefined,
        llmMessages: isAssistant ? this.currentLlmMessagesSnapshot : undefined,
        llmSystemPrompt: isAssistant ? this.currentLlmSystemPrompt : undefined,
        inventorySnapshot: isTurnUserMessage ? this.currentInventorySnapshot : undefined,
      };
      if (isAssistant) {
        this.currentToolsSnapshot = undefined;
        this.currentLlmMessagesSnapshot = undefined;
        this.currentLlmSystemPrompt = undefined;
      }
      if (isTurnUserMessage) {
        this.currentInventorySnapshot = undefined;
      }
      this.persistence.enqueueMessage(event.message, snapshot);
    }
    if (event.type === "tool_execution_start") {
      // sequential 模式（agent 构造 toolExecution: "sequential"）下 0↔1 摆动，
      // 同 message 多 tool 时按 emit 顺序串行 start/end，计数永不超过 1。
      this.activeToolExecutions += 1;
      this.pendingToolArgs.set(event.toolCallId, event.args);
    }
    if (event.type === "tool_execution_end") {
      this.activeToolExecutions = Math.max(0, this.activeToolExecutions - 1);
      const toolArgs = this.pendingToolArgs.get(event.toolCallId);
      this.pendingToolArgs.delete(event.toolCallId);
      this.completedToolCallIds.add(event.toolCallId);
      this.toolExecutedThisLlmCall = true;
      void this.continuedActions.markToolResult(event.toolName, event.result);
      if (event.isError) {
        this.recordPreSubmitToolFailure(event.toolName, event.result, toolArgs, event.toolCallId);
        this.blockRemainingToolCallsThisMessage = true;
      }
      if (event.toolName === "do_nothing" && !event.isError && isDoNothingToolResult(event.result)) {
        this.stopFurtherToolsThisTurn = true;
        this.stopAgentLoopThisTurn = true;
        this.stopFurtherToolsReason = t("error.do_nothing_loop_stopped", getActiveLocale());
        queueMicrotask(() => this.abortAgentWithReason("do_nothing_stopped"));
      }
    }
    if (event.type === "turn_end" || event.type === "agent_end") {
      void this.setPublicThinkingStatus(false);
      // 中途 abort 的 tool 可能只有 _start 没 _end，残留 args 在此清掉，避免 map 缓慢泄漏。
      this.pendingToolArgs.clear();
      this.blockRemainingToolCallsThisMessage = false;
    }
    if (event.type === "turn_end" && this.toolExecutedThisLlmCall) {
      // 整条 assistant message 的 tool 都跑完了，断开 pi-agent-core 续航，把控制权交还 runCurrentTurn
      // 重新装配 context 后再起新 LLM call。这是 two-track 让 working_memory / 感知 "每次 LLM call 都新鲜" 的关键。
      // 不在 afterToolCall（每个 tool 后）做，避免同 message 多 tool 时 abort 误伤后续 tool。
      queueMicrotask(() => this.abortAgentWithReason("after_turn_force_break"));
    }
    if (event.type === "turn_end" && event.message.role === "assistant" && event.message.stopReason === "error") {
      if (this.recordAssistantToolParseFailures(event.message)) {
        this.toolExecutedThisLlmCall = true;
      }
      this.options.logger?.warn({
        townId: this.options.townId,
        characterId: this.options.characterId,
        agentKind: this.options.agentKind,
        error: event.message.errorMessage,
      }, "two-track action turn ended with error");
    }
  }

  // --- 上下文辅助 ---

  private async currentContextFromHost(): Promise<AgentCurrentContext | undefined> {
    const fromManifest = await this.options.ctx.getCurrentContext();
    if (!fromManifest) return undefined;
    this.observeGameTime(fromManifest.gameTime);
    this.alignCurrentGameTime(fromManifest);
    return fromManifest;
  }

  private observeGameTime(gameTime: GameTimeSnapshot | undefined): void {
    const minute = gameTimeTotalMinutes(gameTime);
    if (minute == null) return;
    if (this.latestObservedGameMinute != null && minute < this.latestObservedGameMinute) return;
    this.latestObservedGameTime = gameTime;
    this.latestObservedGameMinute = minute;
  }

  private observeGameMinute(minute: number): void {
    if (this.latestObservedGameMinute != null && minute < this.latestObservedGameMinute) return;
    this.latestObservedGameMinute = minute;
  }

  private alignContextGameTime(context: GameAgentContext): void {
    this.alignCurrentGameTime(context.current);
  }

  private alignCurrentGameTime(current: AgentCurrentContext): void {
    if (!this.latestObservedGameTime) return;
    const latestMinute = gameTimeTotalMinutes(this.latestObservedGameTime);
    const currentMinute = gameTimeTotalMinutes(current.gameTime);
    if (latestMinute == null || (currentMinute != null && latestMinute < currentMinute)) return;
    current.gameTime = this.latestObservedGameTime;
  }

  private appendPendingEvent(event: WorldEventRecord): void {
    // think-first 路径会先 stash 一份再走正常 onEvent —— 防重入造成历史里同 id 出现两次。
    if (this.pendingEvents.some((existing) => existing.id === event.id)) return;
    this.pendingEvents.push(event);
    if (this.pendingEvents.length > PENDING_EVENTS_CAP) {
      this.pendingEvents.splice(0, this.pendingEvents.length - PENDING_EVENTS_CAP);
    }
  }

  // think-first 路径用：把事件先塞进历史，但不分类、不入 reason 队列、不触发 turn。
  // 调用方接着 await thinking，再走 onEvent —— 那时 appendPendingEvent 会按 id dedup。
  async appendEventToHistoryOnly(event: WorldEventRecord): Promise<void> {
    this.observeGameTime(event.gameTime);
    if (isSelfAuthoredSensoryEvent(event, this.options.characterId)) return;
    const relevant = isEventRelevantToCharacter(event, this.options.characterId);
    const globalAmbient = isGlobalAmbientEvent(event);
    if (!relevant && !globalAmbient) return;
    // 与 onEvent 一致：ignored 的事件不进 pendingEvents。
    if (this.options.agentKind === "npc"
      && classifyEventForCharacter(event, this.options.characterId).kind === "ignored") return;
    this.appendPendingEvent(event);
  }

  // --- 公共状态发布 ---

  private setPublicThinkingStatus(active: boolean, reason = this.currentThinkReason ?? ""): Promise<void> {
    if (this.publicThinkingActive === active) return this.publicThinkingStatusQueue;
    this.publicThinkingActive = active;
    this.publicThinkingStatusQueue = this.publicThinkingStatusQueue.then(() => this.publishThinkingStatus(active, reason));
    return this.publicThinkingStatusQueue;
  }

  private async publishThinkingStatus(active: boolean, reason: string): Promise<void> {
    try {
      await this.options.ctx.setThinkingStatus(active, reason, this.options.agentKind);
    } catch (error) {
      this.options.logger?.warn({
        error,
        townId: this.options.townId,
        characterId: this.options.characterId,
        agentKind: this.options.agentKind,
        active,
        reason,
      }, "failed to publish thinking status");
    }
  }
}

type TurnReason = "interrupt" | "sensory" | "player_command" | "action_notice" | "working_memory";

function reasonForClassification(classification: EventClassification): TurnReason {
  return reasonForClassifications([classification]);
}

// 兜底：上游字段写的是 nameZh / alias / 大小写不规范 slug 时，归一回内部 slug。
function normalizeCharacterId(value: string): string {
  return resolveCharacterIdByName(value) ?? value;
}

function isDoNothingToolResult(value: unknown): boolean {
  const result = objectValue(value);
  const details = objectValue(result?.details);
  return details?.didNothing === true;
}

// 预提交失败补记 failed action_log 时，从原始工具入参还原 target，避免 say_to 失败行退化成
// "你想开口说「」"。args 是 LLM 原始入参（slug 还没解析——解析失败往往正是失败原因），
// 故 character 此处仍是人类名字；渲染器 characterDisplayName 对非 slug 原样返回，显示无碍。
// 其他工具的失败行走通用模板（"你尝试{动作}没成"），不需要 target，返回空对象即可。
function buildPreSubmitFailureTarget(toolName: string, args: unknown): Record<string, unknown> {
  if (toolName !== SAY_TO_ACTION) return {};
  const a = preSubmitArgsObject(args);
  const target: Record<string, unknown> = {};
  if (typeof a.character === "string" && a.character) target.targetCharacterId = a.character;
  if (typeof a.text === "string" && a.text) target.text = a.text;
  return target;
}

function buildPreSubmitFailureReason(args: unknown): string | undefined {
  const reason = preSubmitArgsObject(args).reason;
  if (typeof reason !== "string" || !reason.trim()) return undefined;
  return t("tool.common.agent_tool_reason_format", getActiveLocale(), { reason: reason.trim() });
}

function preSubmitArgsObject(args: unknown): Record<string, unknown> {
  return objectValue(args) ?? parseJsonObject(args) ?? {};
}

function parseJsonObject(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "string") return undefined;
  try {
    return objectValue(JSON.parse(value));
  } catch {
    return undefined;
  }
}

function isGlobalAmbientEvent(event: WorldEventRecord): boolean {
  return GLOBAL_AMBIENT_EVENTS.has(event.type) || event.data?.scope === "global" || event.data?.global === true;
}

function removeConsumedPendingEvents(pendingEvents: WorldEventRecord[], consumed: WorldEventRecord[]): void {
  const consumedIds = new Set(consumed.map((event) => event.id));
  for (let index = pendingEvents.length - 1; index >= 0; index -= 1) {
    if (consumedIds.has(pendingEvents[index].id)) pendingEvents.splice(index, 1);
  }
}
