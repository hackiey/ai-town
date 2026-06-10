// Thinking 慢轨：定时（默认每 15 游戏分钟）+ 关键事件触发，跑一次 LLM call
// 写出 working_memory 到 runtime_storage，供 action 快轨下一轮 turn 读。
//
// 设计取舍：
// - 不持久化 session message 历史（agent_sessions 不写）。每次 turn 重建 Agent，
//   上下文靠 perception manifest + 上一份 working_memory 自带，不需要 LLM 自己记。
//   这样能避免和 action 轨在 (townId, characterId, agentKind) 唯一键上冲突。
// - 只暴露长期记忆 update_memory 和收尾 write_working_memory。LLM 调 write_working_memory
//   就把内容存进 runtime_storage，tool 自己 return 结束信号；我们读到 store 完成后 abort 当前 turn，省 token。
// - 并发去重：requestThink 在 running 时只更新 queuedReason；当前 turn finally 检查并起一轮。

import { Agent, type AgentEvent, type AgentMessage, type AgentTool, type AgentToolResult } from "@mariozechner/pi-agent-core";
import { Type, type Static } from "@mariozechner/pi-ai";
import type { AgentRuntimeContext } from "../../agent-host/runtime.js";
import type { RuntimeStorage } from "../../agent-host/storage.js";
import type { AgentConfig } from "../../config/env.js";
import type { GameTimeSnapshot } from "../../godot-link/protocol.js";
import {
  resolveAgentProviderApiKey,
  type AgentModelSelection,
} from "../../agents/model-registry.js";
import {
  assistantUsage,
  isAssistantMessage,
  userMessage,
  usageCostUsd,
  usageTokenCount,
} from "../../agent-shared/utils/agent-message.js";
import { createTwoTrackUpdateMemoryTool } from "./memory-tool.js";
import { AgentContextBuilder } from "./prompt/context/builder.js";
import {
  buildAgentTimelineEntries,
  filterTimelineEntriesAfterCursor,
  latestTimelineCursor,
  renderAgentMemoryPinnedUserMessage,
  renderAgentSystemContext,
  renderAgentTimelineEntries,
  renderAgentTurnContext,
  UNSUMMARIZED_TIMELINE_TRIGGER_COUNT,
  type AgentTimelineEntry,
} from "./prompt/context/renderer.js";
import { formatGameTime } from "../../agent-shared/prompt-context/time.js";
import { getActiveLocale, t } from "../../i18n/index.js";
import type { WorkingMemorySnapshot } from "../../agent-shared/prompt-context/types.js";
import type { PiAgentRuntimeLogger } from "./runtime.js";
import { WORKING_MEMORY_STORAGE_KEY, readWorkingMemoryFromStorage } from "./runtime.js";

// 与 [[project_game_time_scale]] 对齐：1 real-min ≈ 7 game-min @ default time_scale=7×。
// 15 game-min 约等于 ~2 real-min。
const DEFAULT_THINKING_INTERVAL_GAME_MINUTES = 15;
const WRITE_WORKING_MEMORY_TOOL_NAME = "write_working_memory";
const WORKING_MEMORY_MAX_LENGTH = 4000;

export type ThinkingTrackSessionOptions = {
  ctx: AgentRuntimeContext;
  config: AgentConfig;
  townId: string;
  characterId: string;
  modelSelection: AgentModelSelection;
  intervalGameMinutes?: number;
  logger?: PiAgentRuntimeLogger;
  // 写完 working_memory 后通知 action 轨"该看一眼世界"，让 NPC 在没有事件
  // 的情况下也能被周期性唤醒（否则 action 只在事件到来时才 fire）。
  onWorkingMemoryWritten?: () => void;
};

type WriteWorkingMemoryParams = Static<ReturnType<typeof createWriteWorkingMemorySchema>>;

function createWriteWorkingMemorySchema() {
  const locale = getActiveLocale();
  return Type.Object({
    content: Type.String({
      minLength: 1,
      maxLength: WORKING_MEMORY_MAX_LENGTH,
      description: t("prompt.agent.thinking_track.write_tool.param.content", locale),
    }),
    emotional_state: Type.Optional(Type.String({
      maxLength: 1000,
      description: t("prompt.agent.thinking_track.write_tool.param.emotional_state", locale),
    })),
    intent: Type.Optional(Type.String({
      maxLength: 200,
      description: t("prompt.agent.thinking_track.write_tool.param.intent", locale),
    })),
  });
}

export class ThinkingTrackSession {
  private readonly intervalGameMinutes: number;
  private latestObservedGameTime?: GameTimeSnapshot;
  private nextThinkGameMinute?: number;
  private running = false;
  private queuedReason?: string;
  private currentAgent?: Agent;
  // 当前 in-flight runOnce 的 promise wrapper。runThinkBlocking 用它判断是否要先等当前轮结束。
  // requestThink 在 running 时只塞 queuedReason 直接返回，不暴露给外部 await——保持原 fire-and-forget 语义；
  // 只有 runThinkBlocking 显式走 currentRun 才"必须等到我自己跑完"。
  private currentRun?: Promise<void>;
  private readonly contextBuilder = new AgentContextBuilder();

  constructor(private readonly options: ThinkingTrackSessionOptions) {
    this.intervalGameMinutes = options.intervalGameMinutes ?? DEFAULT_THINKING_INTERVAL_GAME_MINUTES;
  }

  get townId(): string { return this.options.townId; }
  get characterId(): string { return this.options.characterId; }

  observeGameTime(gameTime: GameTimeSnapshot | undefined): void {
    if (!gameTime) return;
    this.latestObservedGameTime = gameTime;
  }

  // 由 PiAgentRuntime.onGameTime 派发。返回前推进时钟；若到达 nextThinkGameMinute → 请求一次 think。
  async onGameTime(gameMinute: number, gameTime?: GameTimeSnapshot): Promise<void> {
    if (gameTime) this.observeGameTime(gameTime);

    if (this.nextThinkGameMinute == null) {
      // 首次 observe：错峰起点，避免一整批 NPC 同时打 LLM。
      this.nextThinkGameMinute = gameMinute + initialThinkingOffset(this.options.characterId, this.intervalGameMinutes);
      return;
    }
    if (gameMinute < this.nextThinkGameMinute) return;
    this.nextThinkGameMinute = gameMinute + this.intervalGameMinutes;
    await this.requestThink("scheduled");
  }

  async requestThink(reason: string): Promise<void> {
    if (this.running) {
      // 跑中再来：只记最早 reason，避免事件 burst 时排队过深。已经在跑就够新了。
      if (!this.queuedReason) this.queuedReason = reason;
      return;
    }
    await this.runWithLock(reason);
  }

  async requestThinkIfTimelineBacklog(): Promise<void> {
    if (this.running) return;
    const current = await this.options.ctx.getCurrentContext();
    if (!current) return;
    this.observeGameTime(current.gameTime);
    const previousMemory = await readWorkingMemoryFromStorage(this.options.ctx.storage());
    const context = await this.contextBuilder.build({
      ctx: this.options.ctx,
      current,
      workingMemory: undefined,
    });
    const uncompactedCount = filterTimelineEntriesAfterCursor(
      buildAgentTimelineEntries(context),
      previousMemory?.compactedThrough,
    ).length;
    if (uncompactedCount > UNSUMMARIZED_TIMELINE_TRIGGER_COUNT) {
      await this.requestThink("timeline_backlog");
    }
  }

  // "先想再行动"路径用：阻塞调用方直到本次思考真的写完 working_memory。
  // 若另一轮正在跑，先等它完（不抢占），再起自己这一轮。
  async runThinkBlocking(reason: string): Promise<void> {
    while (this.running) {
      await this.currentRun?.catch(() => {});
    }
    await this.runWithLock(reason);
  }

  // 实际占锁 + 跑一次 runOnce 的内部实现。requestThink / runThinkBlocking 共用。
  private async runWithLock(reason: string): Promise<void> {
    this.running = true;
    const run = (async () => {
      try {
        await this.runOnce(reason);
      } catch (error) {
        this.options.logger?.error({
          error,
          townId: this.options.townId,
          characterId: this.options.characterId,
          reason,
        }, "thinking track turn failed");
      } finally {
        this.running = false;
        this.currentAgent = undefined;
        this.currentRun = undefined;
        const queued = this.queuedReason;
        this.queuedReason = undefined;
        if (queued) {
          // 用 queueMicrotask 拆栈，避免同步递归导致栈深。
          queueMicrotask(() => { void this.requestThink(queued); });
        }
      }
    })();
    this.currentRun = run;
    await run;
  }

  abort(): void {
    this.currentAgent?.abort();
  }

  private async runOnce(reason: string): Promise<void> {
    const current = await this.options.ctx.getCurrentContext();
    if (!current) {
      this.options.logger?.info({
        townId: this.options.townId,
        characterId: this.options.characterId,
        reason,
      }, "thinking track skipped: no perception manifest");
      return;
    }
    this.observeGameTime(current.gameTime);

    const previousMemory = await readWorkingMemoryFromStorage(this.options.ctx.storage());

    const context = await this.contextBuilder.build({
      ctx: this.options.ctx,
      current,
      // Thinking 自己写 working_memory，不把它注入自己 prompt 的 "工作记忆" 节
      // —— 而是放进 user message 里显式说"上一份是这样的"，避免 system prompt 自递归。
      workingMemory: undefined,
    });

    const timelineEntries = buildAgentTimelineEntries(context);
    const uncompactedEntries = filterTimelineEntriesAfterCursor(timelineEntries, previousMemory?.compactedThrough);
    const nextCompactedThrough = latestTimelineCursor(uncompactedEntries) ?? previousMemory?.compactedThrough;

    const systemPrompt = renderThinkingSystemPrompt(context);
    const userPrompt = renderThinkingUserPrompt(reason, previousMemory, context, uncompactedEntries);
    // 长期 Memory 抽到 system 之外，作为消息序列里第一条 pinned user message。
    // 与 action 轨同样的理由：update_memory 改它只让 messages 段 cache 失效，
    // 不连累 system/tools。空时跳过这条预置。
    const memoryPin = renderAgentMemoryPinnedUserMessage(context);
    const initialMessages: AgentMessage[] = memoryPin ? [userMessage(memoryPin)] : [];

    let writtenContent: string | undefined;
    let writtenEmotionalState: string | undefined;
    let writtenIntent: string | undefined;
    let assistantMessage: AgentMessage | undefined;
    const startGameTime = this.latestObservedGameTime;
    const startedAtIso = new Date().toISOString();
    const startedAtMs = Date.now();

    const locale = getActiveLocale();
    const writeTool: AgentTool<ReturnType<typeof createWriteWorkingMemorySchema>> = {
      label: "Write Working Memory",
      name: WRITE_WORKING_MEMORY_TOOL_NAME,
      description: t("prompt.agent.thinking_track.write_tool.description", locale),
      parameters: createWriteWorkingMemorySchema(),
      execute: async (_id: string, args: WriteWorkingMemoryParams): Promise<AgentToolResult<{ ok: true }>> => {
        writtenContent = args.content.trim();
        writtenEmotionalState = typeof args.emotional_state === "string" ? args.emotional_state.trim() || undefined : undefined;
        writtenIntent = typeof args.intent === "string" ? args.intent.trim() || undefined : undefined;
        return {
          content: [{ type: "text", text: t("prompt.agent.thinking_track.write_tool.result", locale) }],
          details: { ok: true as const },
        };
      },
    };

    // Thinking 也可以维护长期 Memory（self_knowledge / skill / other）。
    // 跟 action 轨复用同一份实现 + 同一个 RuntimeStorage（memory: 前缀和 working_memory key 共存）。
    // afterToolCall 只在 write_working_memory 时 abort，所以 update_memory 可以连续多次调用，
    // 最后一次性 write_working_memory 收尾。
    const updateMemoryTool = createTwoTrackUpdateMemoryTool(
      this.options.ctx.storage(),
      this.options.townId,
      this.options.characterId,
      this.latestObservedGameTime,
      context.memory,
    );

    const agent = new Agent({
      initialState: {
        systemPrompt,
        model: this.options.modelSelection.model,
        // Thinking 轨的 thinkingLevel 由 npcs.json agent_models.thinking 显式决定（一般是 "high"）。
        thinkingLevel: this.options.modelSelection.thinkingLevel,
        tools: [updateMemoryTool, writeTool],
        messages: initialMessages,
      },
      sessionId: `thinking:${this.options.townId}:${this.options.characterId}`,
      getApiKey: (provider) => resolveAgentProviderApiKey(this.options.config, provider),
      toolExecution: "sequential",
      // 工具一旦命中即关 loop —— write_working_memory 已经"宣告本次思考结束"，
      // 不需要 LLM 继续 message。
      afterToolCall: async ({ toolCall }) => {
        if (toolCall.name === WRITE_WORKING_MEMORY_TOOL_NAME) {
          queueMicrotask(() => agent.abort());
        }
        return undefined;
      },
    });
    this.currentAgent = agent;

    // 抓 assistant message 给 debug timeline 详情面板看（thinking blocks + write_working_memory tool_call）。
    // write_working_memory 命中后我们 queueMicrotask(abort)，pi-agent-core 可能在 abort 生效前再起一轮
    // LLM call，emit 一个空/aborted 的 message_end，把首条覆盖掉 → debug 上 assistant 内容看不到。
    // 因此只保留第一条 isAssistantMessage 的 message_end（即真正写 working_memory 的那一条）。
    agent.subscribe((event: AgentEvent) => {
      if (event.type !== "message_end") return;
      if (!isAssistantMessage(event.message)) return;
      if (assistantMessage) return;
      assistantMessage = event.message;
    });

    this.options.logger?.info({
      tag: "thinking-track",
      where: "start",
      townId: this.options.townId,
      characterId: this.options.characterId,
      reason,
      hasPreviousMemory: !!previousMemory,
    }, `[thinking-track] start reason=${reason}`);

    let runError: unknown;
    try {
      await agent.prompt(userPrompt);
    } catch (error) {
      runError = error;
    }

    const endGameTime = this.latestObservedGameTime;
    const endedAtIso = new Date().toISOString();
    const durationMs = Math.max(0, Date.now() - startedAtMs);

    if (writtenContent) {
      const now = new Date().toISOString();
      // RuntimeStorageValue 不允许 undefined 字段，要么 stringify 要么剔除。
      // gameTime 可能没观测到，所以条件式装入。
      const snapshot: { [k: string]: unknown } = {
        content: writtenContent,
        updatedAt: now,
        triggerReason: writtenIntent ? `${reason}: ${writtenIntent}` : reason,
      };
      if (writtenEmotionalState) {
        snapshot.emotionalState = writtenEmotionalState;
      }
      if (this.latestObservedGameTime) {
        snapshot.gameTime = this.latestObservedGameTime as unknown as Record<string, unknown>;
      }
      if (nextCompactedThrough) {
        snapshot.compactedThrough = nextCompactedThrough as unknown as Record<string, unknown>;
      }
      await this.options.ctx.storage().set(WORKING_MEMORY_STORAGE_KEY, snapshot as never);
      this.options.logger?.info({
        tag: "thinking-track",
        where: "wrote",
        townId: this.options.townId,
        characterId: this.options.characterId,
        reason,
        length: writtenContent.length,
      }, `[thinking-track] wrote working_memory length=${writtenContent.length}`);
      // 通知 action 轨：脑子里刚理过一遍，去看看眼前世界有没有事可做。
      // try/catch 兜底，避免回调里的异常把 thinking 主流程带挂。
      try {
        this.options.onWorkingMemoryWritten?.();
      } catch (callbackError) {
        this.options.logger?.warn({
          error: callbackError,
          townId: this.options.townId,
          characterId: this.options.characterId,
        }, "onWorkingMemoryWritten callback threw");
      }
    } else {
      this.options.logger?.warn({
        tag: "thinking-track",
        where: "no_write",
        townId: this.options.townId,
        characterId: this.options.characterId,
        reason,
      }, `[thinking-track] finished without write_working_memory call`);
    }

    // 写库给 debug timeline 用 — 失败也写，把 error 留下来，diamond 红显。
    // 写库本身失败只 log，不向上抛，避免污染 thinking 主流程。
    const usage = assistantMessage ? assistantUsage(assistantMessage) : undefined;
    try {
      await this.options.ctx.thinkingTurns().record({
        townId: this.options.townId,
        characterId: this.options.characterId,
        triggerReason: reason,
        intent: writtenIntent,
        startedAt: startedAtIso,
        endedAt: endedAtIso,
        durationMs,
        startGameTime,
        endGameTime,
        modelId: this.options.modelSelection.model.id,
        systemPrompt,
        userPrompt,
        assistantMessage,
        writtenContent,
        previousMemoryUpdatedAt: previousMemory?.updatedAt,
        usage,
        totalTokens: usage ? usageTokenCount(usage) : undefined,
        costUsd: usage ? usageCostUsd(usage) : undefined,
        error: runError ? errorMessage(runError) : undefined,
      });
    } catch (recordError) {
      this.options.logger?.error({
        error: recordError,
        townId: this.options.townId,
        characterId: this.options.characterId,
        reason,
      }, "failed to record thinking turn");
    }

    if (runError) throw runError;
  }
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.stack ?? `${error.name}: ${error.message}`;
  }
  return String(error);
}

// System prompt：把模型角色从"行动者"切到"慢思考 / working-memory 维护者"。
// 这里只放完全静态的背景（世界设定、常识、事实边界）。
// 长期 Memory → 已抽到一条 pinned user message（见 runOnce 里的 memoryPin），
// 角色感知 / 周围环境 / 属性 / 背包 / 当前时间 / 事件 → 全部在 turn user prompt 里，
// 这样 system prompt 跨 turn 可以稳定走 prompt cache（update_memory 也不污染）。
function renderThinkingSystemPrompt(context: ReturnType<AgentContextBuilder["build"]> extends Promise<infer T> ? T : never): string {
  const locale = getActiveLocale();
  const header = t("prompt.agent.thinking_track.system", locale);
  const emotionMemory = t("prompt.agent.thinking_track.emotion_memory_instruction", locale);
  const compaction = t("prompt.agent.thinking_track.compaction_system", locale);
  return `${header}\n\n${emotionMemory}\n\n${compaction}\n\n${renderAgentSystemContext(context)}`;
}

function renderThinkingUserPrompt(
  reason: string,
  previous: WorkingMemorySnapshot | undefined,
  context: ReturnType<AgentContextBuilder["build"]> extends Promise<infer T> ? T : never,
  uncompactedEntries: AgentTimelineEntry[],
): string {
  const parts: string[] = [];

  // 角色感知（位置 / 属性 / 周围 / 背包 / 当前时间）放进 user message——
  // 跨 turn 会变，不适合进 system prompt 的 cache 段；同时跟 action 轨布局一致。
  // renderAgentTurnContext 已经不渲染事件（事件由 renderAgentEventsContext 单独负责），
  // 这里只用现状块即可；working memory 之后的新时间线由下面按 compactedThrough 游标切分。
  const locale = getActiveLocale();

  parts.push(renderAgentTurnContext(context));

  parts.push(`${t("prompt.agent.thinking_track.user.turn_reason_header", locale)}\n${reason}`);

  if (previous && previous.content) {
    const updatedAt = formatGameTime(previous.gameTime) ?? previous.updatedAt;
    parts.push(`${t("prompt.agent.thinking_track.user.previous_memory_header_format", locale, { updatedAt })}\n${previous.content}`);
  } else {
    parts.push(t("prompt.agent.thinking_track.user.previous_memory_empty", locale));
  }

  const toCompactBody = uncompactedEntries.length > 0
    ? renderAgentTimelineEntries(uncompactedEntries, context, locale)
    : t("prompt.agent.thinking_track.user.events_to_compact_empty", locale);
  parts.push(`${t("prompt.agent.thinking_track.user.events_to_compact_header", locale)}\n${toCompactBody}`);

  parts.push(t("prompt.agent.thinking_track.user.closing_instruction", locale));
  return parts.join("\n\n");
}

// stableHash 错峰 1~interval-1，避免所有 NPC 在同一游戏分钟集中跑 thinking turn。
function initialThinkingOffset(characterId: string, intervalGameMinutes: number): number {
  if (intervalGameMinutes <= 1) return 0;
  return 1 + (stableHash(characterId) % (intervalGameMinutes - 1));
}

function stableHash(value: string): number {
  let hash = 0;
  for (let i = 0; i < value.length; i++) {
    hash = (hash * 31 + value.charCodeAt(i)) | 0;
  }
  return Math.abs(hash);
}

// re-export 给 PiAgentRuntime 拼装事件触发器用
export { isSignificantForThinking } from "./semantics/events.js";

// 让 runtime.ts 能引用同一个 RuntimeStorage 类型，避免 cycle 引导写错。
export type { RuntimeStorage };
