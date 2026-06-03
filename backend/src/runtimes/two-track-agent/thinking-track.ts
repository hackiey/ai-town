// Thinking 慢轨：定时（默认每 15 游戏分钟）+ 关键事件触发，跑一次 LLM call
// 写出 working_memory 到 runtime_storage，供 action 快轨下一轮 turn 读。
//
// 设计取舍：
// - 不持久化 session message 历史（agent_sessions 不写）。每次 turn 重建 Agent，
//   上下文靠 perception manifest + 上一份 working_memory 自带，不需要 LLM 自己记。
//   这样能避免和 action 轨在 (townId, characterId, agentKind) 唯一键上冲突。
// - 只暴露 1 个 tool：write_working_memory。LLM 调它就把内容存进 runtime_storage，
//   tool 自己 return 结束信号；我们读到 store 完成后 abort 当前 turn，省 token。
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
  renderAgentMemoryPinnedUserMessage,
  renderAgentSystemContext,
  renderAgentTurnContext,
  renderEventTimeline,
  splitEventsAtCutoff,
} from "./prompt/context/renderer.js";
import { formatGameTime, gameTimeSortValue, normalizeGameTime } from "../../agent-shared/prompt-context/time.js";
import { getActiveLocale } from "../../i18n/index.js";
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
  onReflectionWritten?: () => void;
};

type WriteWorkingMemoryParams = Static<ReturnType<typeof createWriteWorkingMemorySchema>>;

function createWriteWorkingMemorySchema() {
  return Type.Object({
    content: Type.String({
      minLength: 1,
      maxLength: WORKING_MEMORY_MAX_LENGTH,
      description:
        "你给行动模块（另一个你）看的工作备忘。写当前局势、目标、值得注意的人事、未完成的承诺、可能的下一步打算。中文自然语言，可以分段，不需要结构化。",
    }),
    intent: Type.Optional(Type.String({
      maxLength: 200,
      description: "可选：本次更新的主要意图或最大变化，一句话。",
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

    const systemPrompt = renderThinkingSystemPrompt(context);
    const userPrompt = renderThinkingUserPrompt(reason, previousMemory, context);
    // 长期 Memory 抽到 system 之外，作为消息序列里第一条 pinned user message。
    // 与 action 轨同样的理由：update_memory 改它只让 messages 段 cache 失效，
    // 不连累 system/tools。空时跳过这条预置。
    const memoryPin = renderAgentMemoryPinnedUserMessage(context);
    const initialMessages: AgentMessage[] = memoryPin ? [userMessage(memoryPin)] : [];

    let writtenContent: string | undefined;
    let writtenIntent: string | undefined;
    let assistantMessage: AgentMessage | undefined;
    const startGameTime = this.latestObservedGameTime;
    const startedAtIso = new Date().toISOString();
    const startedAtMs = Date.now();

    const writeTool: AgentTool<ReturnType<typeof createWriteWorkingMemorySchema>> = {
      label: "Write Working Memory",
      name: WRITE_WORKING_MEMORY_TOOL_NAME,
      description:
        "把你最新整理的工作记忆写下来，给行动模块（另一个你）看。每次思考只调一次本工具，写完就结束本次思考。如果还要 update_memory 写长期记忆，请先写完再调这个。",
      parameters: createWriteWorkingMemorySchema(),
      execute: async (_id: string, args: WriteWorkingMemoryParams): Promise<AgentToolResult<{ ok: true }>> => {
        writtenContent = args.content.trim();
        writtenIntent = typeof args.intent === "string" ? args.intent.trim() || undefined : undefined;
        return {
          content: [{ type: "text", text: "working_memory 已写入。本次思考结束。" }],
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
      if (this.latestObservedGameTime) {
        snapshot.gameTime = this.latestObservedGameTime as unknown as Record<string, unknown>;
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
        this.options.onReflectionWritten?.();
      } catch (callbackError) {
        this.options.logger?.warn({
          error: callbackError,
          townId: this.options.townId,
          characterId: this.options.characterId,
        }, "onReflectionWritten callback threw");
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

// System prompt：把模型角色从"行动者"切到"反思者"。
// 这里只放完全静态的背景（世界设定、常识、事实边界）。
// 长期 Memory → 已抽到一条 pinned user message（见 runOnce 里的 memoryPin），
// 角色感知 / 周围环境 / 属性 / 背包 / 当前时间 / 事件 → 全部在 turn user prompt 里，
// 这样 system prompt 跨 turn 可以稳定走 prompt cache（update_memory 也不污染）。
function renderThinkingSystemPrompt(context: ReturnType<AgentContextBuilder["build"]> extends Promise<infer T> ? T : never): string {
  const header = [
    "你是 NPC 的「慢思考模块」。你和另一个负责行动的「你」分开运作：",
    "- 你看到所有感知和近期事件，但你不直接行动、不说话、不动手。",
    "- 你比行动模块有更多 thinking budget。你的核心职责有两件，缺一不可：",
    "  1. 维护长期 Memory（跨思考周期一直在），把会持续影响判断的内容沉淀下来；",
    "  2. 把当前局势整理成一段「工作记忆」给行动模块用（短期，每次思考覆写）。",
    "",
    "════════════════════════════════════",
    "一、长期 Memory 维护（重要职责，主动调用 update_memory）",
    "════════════════════════════════════",
    "update_memory 写的内容会进入消息序列里的置顶 Memory 块，跨多个思考周期一直存在。",
    "下面三件事你必须主动沉淀进 Memory，不要只盯着「眼前发生了什么」：",
    "",
    "1. **中长期目标**：你希望几小时 / 几天 / 几周后达成什么？此刻在朝向哪个方向？",
    "   - 没有的话，结合身份、处境、近况主动定一个；目标变了 edit 旧的、add 新的。",
    "   - 目标要可执行（「攒够 50 银买把好镐」而不是「过得好」）。",
    "",
    "2. **行为反思**：复盘最近的行动 —— 哪些是徒劳的、低效的、违背自己处境的、与目标方向不符的？",
    "   - 把结论写下来供下次决策参考，例如：「上次试图 X 没成功，原因是 Y，下次别再这么做」、",
    "     「连续 N 次 do_nothing 但目标没推进，需要换个思路」。",
    "   - 这不是日记 —— 只写「会改变下次行为」的判断。",
    "",
    "3. **环境与规则理解**：对所处地点、周围人、可用资源、社会关系、社会规则的判断。",
    "   - **特别要重视工具使用规律的沉淀**：行动模块每轮发的 tool call、收到的 tool result / 错误信号、",
    "     完成或被拒的反应事件，是你最重要的反思素材。把以下这类判断稳定地 add 进 Memory：",
    "     · 哪些 tool 在什么前置条件下才会成功（距离/所有权/背包内容/group 权限/手艺门槛）",
    "     · 哪些 tool 反复失败、失败信号说明什么 —— 不要让行动模块下一轮再撞同一堵墙",
    "     · 多个 tool 之间的因果链（要先 A 才能 B；C 失败后通常需要走 D 兜底）",
    "   - 是规律性认识，不是一次性观察。",
    "",
    "操作规则：",
    "- 同一思考里可以连续多次 update_memory（add / edit / remove）。过时的 edit/remove，新沉淀的 add。",
    "- 严格基于上下文中已明示的信息，不要编造或扩写；无明确新事实不要改 self_knowledge。",
    "- kind=self_knowledge 只装稳定自我认知（姓名/职业/性格/重要关系），上面三件事一般归 kind=other。",
    "",
    "════════════════════════════════════",
    "二、工作记忆 write_working_memory（一次性收尾）",
    "════════════════════════════════════",
    "工作记忆是给行动模块下一轮决策看的「此刻脑内状态」，每次思考覆写，篇幅几段以内：",
    "- 此刻最该关注的人或事是什么、为什么；",
    "- 最近关键事件给你留下什么印象、改变了什么打算；",
    "- 未完成的承诺、欠下的人情、约定要做的事；",
    "- 当下情绪、身体状态、临时挂着的牵挂；",
    "- 短期下一步打算（不要写成命令清单 —— 给行动模块判断空间）。",
    "",
    "写作原则：",
    "- 中文第一人称，像在脑子里跟自己说话；",
    "- 不复述上下文里已有的事实，只写经过你「消化」后值得保留的判断；",
    "- 不要写成行动清单或时间表 —— 那是行动模块的事；",
    "- 跨思考周期还成立的判断写 Memory，几分钟就过期的状态写工作记忆。",
    "",
    "════════════════════════════════════",
    "流程",
    "════════════════════════════════════",
    "先（按需）多次 update_memory 整理长期 Memory（中长期目标 / 行为反思 / 环境理解）",
    "→ 最后调用 write_working_memory 提交本次工作记忆，思考即结束。每次思考只调一次 write_working_memory。",
  ].join("\n");
  return `${header}\n\n${renderAgentSystemContext(context)}`;
}

function renderThinkingUserPrompt(
  reason: string,
  previous: WorkingMemorySnapshot | undefined,
  context: ReturnType<AgentContextBuilder["build"]> extends Promise<infer T> ? T : never,
): string {
  const parts: string[] = [];

  // 角色感知（位置 / 属性 / 周围 / 背包 / 当前时间）放进 user message——
  // 跨 turn 会变，不适合进 system prompt 的 cache 段；同时跟 action 轨布局一致。
  // renderAgentTurnContext 已经不渲染事件（事件由 renderAgentEventsContext 单独负责），
  // 这里只用现状块即可；事件由下面按"上次思考以来"自己切段。
  parts.push(renderAgentTurnContext(context));

  parts.push(`# 思考触发原因\n${reason}`);

  if (previous && previous.content) {
    const updatedAt = formatGameTime(previous.gameTime) ?? previous.updatedAt;
    parts.push(`# 上一份工作记忆（更新于 ${updatedAt}）\n${previous.content}`);
  } else {
    parts.push("# 上一份工作记忆\n（尚无。本次是首次思考。）");
  }

  const cutoffMinutes = previousMemoryCutoffMinutes(previous);
  const { since, before } = splitEventsAtCutoff(context.relevantEvents, cutoffMinutes);

  const locale = getActiveLocale();
  const viewerId = context.characterId;
  const selfActions = context.selfActionResults;
  if (cutoffMinutes != null) {
    const sinceBody = since.length > 0 ? renderEventTimeline(since, viewerId, locale, selfActions) : "（这段时间内没有相关事件。）";
    parts.push(`# 自上次思考以来发生的事\n${sinceBody}`);
    if (before.length > 0) {
      parts.push(`# 更早的背景事件（上次思考之前，仅供回顾）\n${renderEventTimeline(before, viewerId, locale, selfActions)}`);
    }
  } else {
    const allBody = since.length > 0 ? renderEventTimeline(since, viewerId, locale, selfActions) : "（没有相关事件。）";
    parts.push(`# 近期事件（首次思考，没有 cutoff，全量给出）\n${allBody}`);
  }

  parts.push("基于以上当前感知 + 上一份工作记忆 + 自上次思考以来发生的事，更新或重写工作记忆并调用 write_working_memory 提交。可以保留仍成立的内容，也可以彻底改写。");
  return parts.join("\n\n");
}

function previousMemoryCutoffMinutes(previous: WorkingMemorySnapshot | undefined): number | undefined {
  if (!previous) return undefined;
  const normalized = normalizeGameTime(previous.gameTime);
  if (!normalized) return undefined;
  return gameTimeSortValue(normalized);
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
