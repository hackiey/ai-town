// Two-track agent runtime：每个 NPC 有 action 轨（这里）+ thinking 轨（thinking-track.ts），
// 共享同一个 working_memory KV（runtime_storage.key="working_memory"）。
//
// 关键约束：
// - Action 轨不做 idle 思考；周期总结和长期记忆维护交给 thinking 轨
// - Action 轨每次 LLM call 前重读 perception + working_memory，新事件可 release/abort 当前 call

import type { AgentRuntime, AgentRuntimeContext } from "../../agent-host/runtime.js";
import type { NpcRuntimeConfig } from "../../agent-host/router.js";
import type { AgentConfig } from "../../config/env.js";
import type { WorldEvent } from "../../godot-link/events.js";
import type { GameTimeSnapshot, WorldEventRecord } from "../../godot-link/protocol.js";
import {
  resolveTwoTrackAgentModels,
  type TwoTrackAgentModels,
  type TwoTrackAgentModelsRaw,
} from "../../agents/model-registry.js";
import { gameTimeTotalMinutes } from "../../agent-shared/utils/game-time.js";
import type { AgentKind } from "../../agents/types.js";
import { ActionTrackSession } from "./action-session/index.js";
import { TwoTrackAgentContextBuilder, resolveCharacterIdByName } from "./prompt/index.js";
import { ThinkingTrackSession } from "./thinking-track.js";
import { isSignificantForThinking, isThinkFirstEvent } from "./semantics/events.js";

const PLAYER_COMMAND_EVENT_TYPE = "player_command";
const AI_TAKEOVER_EVENT_TYPE = "ai_takeover";
const AI_RELEASE_EVENT_TYPE = "ai_release";

export type PiAgentRuntimeLogger = {
  info(data: Record<string, unknown>, message: string): void;
  warn(data: Record<string, unknown>, message: string): void;
  error(data: Record<string, unknown>, message: string): void;
};

export type PiAgentRuntimeOptions = {
  logger?: PiAgentRuntimeLogger;
  // 启动时一次性传入的 NPC 配置快照（characterId → config）。
  // two-track 用其中的 agent_models 字段为每个角色挑 action/thinking 模型。
  // 不持有 router，只持有静态快照——reload-on-change 是 router 的事，本 runtime 不参与。
  npcConfigs: Record<string, NpcRuntimeConfig>;
};

export class PiAgentRuntime {
  // Action 轨 session：按 (agentKind, townId, characterId) keyed，每个 NPC 通常只一个 "npc"，
  // 玩家命令直接打到 "player" 这个并行 session（独立持久化历史）。
  private readonly sessions = new Map<string, ActionTrackSession>();
  // Thinking 轨：每个 NPC 一个，跟 action 轨平行。Keyed by (townId, characterId)。
  private readonly thinkingSessions = new Map<string, ThinkingTrackSession>();
  // 角色模型解析缓存：避免每个 turn 都重复 parse + validate。
  // 出问题（fatal）即抛，不存空缓存；正确解析后存 frozen TwoTrackAgentModels。
  private readonly modelsCache = new Map<string, TwoTrackAgentModels>();
  // 当前被 AI 接管的玩家角色（characterId → 选定模型 + agent 类型）。in-memory，
  // 不跨 worker 重启；登记后 resolveAgentKind 把它当 "npc"，解锁整条 NPC 管线。
  private readonly takeovers = new Map<string, { models: TwoTrackAgentModelsRaw; agentType: string }>();
  private readonly logger?: PiAgentRuntimeLogger;
  private readonly npcConfigs: Record<string, NpcRuntimeConfig>;
  private readonly latestGameMinuteByTown = new Map<string, number>();
  private readonly latestGameTimeByTown = new Map<string, GameTimeSnapshot>();

  constructor(
    private readonly config: AgentConfig,
    options: PiAgentRuntimeOptions,
  ) {
    this.logger = options.logger;
    this.npcConfigs = options.npcConfigs;
  }

  // 解析（并缓存）某角色的 two-track 双模型；缺配置或不在 availableModels 都直接 throw。
  private resolveModels(townId: string, characterId: string): TwoTrackAgentModels {
    const cached = this.modelsCache.get(characterId);
    if (cached) return cached;
    // 被接管的玩家用接管时选的模型；NPC 用 npcs.json 的 agent_models。
    const raw = this.takeovers.get(characterId)?.models ?? this.npcConfigs[characterId]?.agent_models;
    const resolved = resolveTwoTrackAgentModels(
      this.config,
      { townId, characterId },
      raw,
    );
    this.modelsCache.set(characterId, resolved);
    return resolved;
  }

  // 被接管玩家按 "npc" 对待，解锁 thinking 轨 / working-memory wakeup / significant / think-first。
  private resolveAgentKind(characterId: string): AgentKind {
    if (this.takeovers.has(characterId)) return "npc";
    return characterId.startsWith("player_") ? "player" : "npc";
  }

  private registerTakeover(characterId: string, models: TwoTrackAgentModelsRaw, agentType: string): void {
    this.takeovers.set(characterId, { models, agentType });
    // 清缓存：万一之前以别的模型解析过（或重复接管换了模型），下次按新模型重解析。
    this.modelsCache.delete(characterId);
  }

  // 收回控制：abort 并丢弃两条轨的 session，从登记表移除——之后 resolveAgentKind 回落 "player"，
  // game-time tick 不再驱动它，玩家恢复手操。memory/属性都在 DB，不受影响。
  private releaseTakeover(townId: string, characterId: string): void {
    const actionKey = `npc:${townId}:${characterId}`;
    this.sessions.get(actionKey)?.abort();
    this.sessions.delete(actionKey);
    const thinkingKey = `${townId}:${characterId}`;
    this.thinkingSessions.get(thinkingKey)?.abort();
    this.thinkingSessions.delete(thinkingKey);
    this.takeovers.delete(characterId);
    this.modelsCache.delete(characterId);
  }

  start(): void {
    this.logger?.info({}, "two-track agent runtime started");
  }

  stop(): void {
    for (const session of this.sessions.values()) session.abort();
    for (const thinking of this.thinkingSessions.values()) thinking.abort();
  }

  async handleCharacterWorldEvent(event: WorldEventRecord, ctx: AgentRuntimeContext): Promise<void> {
    const characterId = ctx.characterId;
    this.observeGameTime(event.townId, event.gameTime);

    // AI 接管控制事件：像 player_command 一样在顶部特殊处理，绝不进 perception。
    if (event.type === AI_TAKEOVER_EVENT_TYPE) {
      this.registerTakeover(characterId, takeoverModelsFromEvent(event), takeoverAgentTypeFromEvent(event));
      // 登记后 resolveAgentKind 已返回 "npc"：建 action+thinking session 并踢一轮初始 turn 起步。
      this.session(ctx, "npc").enqueueWorkingMemoryTurn();
      return;
    }
    if (event.type === AI_RELEASE_EVENT_TYPE) {
      this.releaseTakeover(ctx.townId, characterId);
      return;
    }

    if (isPlayerCommandEvent(event)) {
      const commandCharacterId = resolvePlayerCommandCharacterId(event);
      if (!commandCharacterId || commandCharacterId !== characterId) return;
      await this.session(ctx, "player").onPlayerCommand(event);
      return;
    }

    const kind = this.resolveAgentKind(characterId);

    // "先想再行动"路径：把事件先放进 pendingEvents（不触发 turn），await thinking 写完
    // working_memory，再走正常 onEvent —— 那次 turn 入口就能读到刚写的 brief。
    // 此后两条轨道恢复各自节奏（thinking 的 15-min tick / action 的事件触发）。
    if (kind === "npc" && isThinkFirstEvent(event)) {
      await this.session(ctx, kind).appendEventToHistoryOnly(event);
      await this.thinkingSession(ctx).runThinkBlocking(`event:${event.type}:think-first`);
      await this.session(ctx, kind).onEvent(event);
      return;
    }

    await this.session(ctx, kind).onEvent(event);

    // 把 significant 事件提前递给 thinking 轨，让它马上重写 working_memory，
    // 这样下次 action turn 能用上最新 brief。fire-and-forget，不阻 action。
    if (kind === "npc") {
      const thinking = this.thinkingSession(ctx);
      if (isSignificantForThinking(event, characterId)) {
        void thinking.requestThink(`event:${event.type}`);
      } else {
        void thinking.requestThinkIfTimelineBacklog();
      }
    }
  }

  async handleGameTime(townId: string, gameTime: GameTimeSnapshot, enabledCharacterIds?: Set<string> | null): Promise<void> {
    const gameMinute = this.observeGameTime(townId, gameTime);
    if (gameMinute == null) return;
    const filter = (sessionTownId: string, sessionCharacterId: string) =>
      sessionTownId === townId && (!enabledCharacterIds || enabledCharacterIds.has(sessionCharacterId));
    await Promise.all([
      ...[...this.sessions.values()]
        .filter((session) => filter(session.townId, session.characterId))
        .map((session) => session.thinkIfGameTimeDue(gameMinute, gameTime)),
      ...[...this.thinkingSessions.values()]
        .filter((thinking) => filter(thinking.townId, thinking.characterId))
        .map((thinking) => thinking.onGameTime(gameMinute, gameTime)),
    ]);
  }

  private thinkingSession(ctx: AgentRuntimeContext): ThinkingTrackSession {
    const key = `${ctx.townId}:${ctx.characterId}`;
    const existing = this.thinkingSessions.get(key);
    if (existing) return existing;
    const models = this.resolveModels(ctx.townId, ctx.characterId);
    const session = new ThinkingTrackSession({
      ctx,
      config: this.config,
      townId: ctx.townId,
      characterId: ctx.characterId,
      modelSelection: models.thinking,
      logger: this.logger,
      // Thinking 写完 working_memory → 踢一脚 action，让没事件时也能被周期唤醒。
      // Lazy lookup：action session 可能此刻还没建，就放过（NPC 还没 attach 就没必要 fire）。
      onWorkingMemoryWritten: () => {
        this.sessions.get(`npc:${ctx.townId}:${ctx.characterId}`)?.enqueueWorkingMemoryTurn();
      },
    });
    const latest = this.latestGameTimeByTown.get(ctx.townId);
    if (latest) session.observeGameTime(latest);
    this.thinkingSessions.set(key, session);
    return session;
  }

  private observeGameTime(townId: string, gameTime: GameTimeSnapshot | undefined): number | undefined {
    const minute = gameTimeTotalMinutes(gameTime);
    if (minute == null) return undefined;
    const previous = this.latestGameMinuteByTown.get(townId);
    if (previous != null && minute < previous) return undefined;
    this.latestGameMinuteByTown.set(townId, minute);
    if (gameTime) this.latestGameTimeByTown.set(townId, gameTime);
    return minute;
  }

  private session(ctx: AgentRuntimeContext, agentKind: AgentKind): ActionTrackSession {
    const key = `${agentKind}:${ctx.townId}:${ctx.characterId}`;
    const existing = this.sessions.get(key);
    if (existing) return existing;

    const models = this.resolveModels(ctx.townId, ctx.characterId);
    const session = new ActionTrackSession({
      ctx,
      contextBuilder: new TwoTrackAgentContextBuilder(),
      config: this.config,
      initialGameMinute: this.latestGameMinuteByTown.get(ctx.townId),
      initialGameTime: this.latestGameTimeByTown.get(ctx.townId),
      modelSelection: models.action,
      townId: ctx.townId,
      characterId: ctx.characterId,
      agentKind,
      logger: this.logger,
      requestTimelineBacklogThink: agentKind === "npc"
        ? () => { void this.thinkingSession(ctx).requestThinkIfTimelineBacklog(); }
        : undefined,
    });
    this.sessions.set(key, session);
    // Eager 建 thinking session，让 onGameTime 即便没有 significant 事件也能驱动定时 fire。
    if (agentKind === "npc") this.thinkingSession(ctx);
    return session;
  }
}

export type CreateTwoTrackAgentRuntimeOptions = {
  config: AgentConfig;
  logger?: PiAgentRuntimeLogger;
  npcConfigs: Record<string, NpcRuntimeConfig>;
};

export class TwoTrackAgentRuntime implements AgentRuntime {
  readonly name = "two-track-agent";
  private started = false;

  constructor(private readonly runtime: PiAgentRuntime) {}

  attach(_ctx: AgentRuntimeContext): void {
    if (this.started) return;
    this.runtime.start();
    this.started = true;
  }

  async onEvent(event: WorldEvent, ctx: AgentRuntimeContext): Promise<void> {
    await this.runtime.handleCharacterWorldEvent(worldEventToRecord(ctx.townId, event), ctx);
  }

  async onGameTime(townId: string, gameTime: GameTimeSnapshot, enabledCharacterIds?: Set<string> | null): Promise<void> {
    await this.runtime.handleGameTime(townId, gameTime, enabledCharacterIds);
  }

  async detach(_ctx: AgentRuntimeContext): Promise<void> {}

  stop(): void {
    this.runtime.stop();
    this.started = false;
  }
}

export function createTwoTrackAgentRuntime(options: CreateTwoTrackAgentRuntimeOptions): TwoTrackAgentRuntime {
  return new TwoTrackAgentRuntime(new PiAgentRuntime(options.config, {
    logger: options.logger,
    npcConfigs: options.npcConfigs,
  }));
}

export { readWorkingMemoryFromStorage, WORKING_MEMORY_STORAGE_KEY } from "./action-session/index.js";

function worldEventToRecord(townId: string, event: WorldEvent): WorldEventRecord {
  return {
    id: event.eventId,
    townId,
    type: event.type,
    actorId: event.actorId,
    spokenText: event.spokenText,
    data: event.data,
    occurredAt: event.occurredAt,
    createdAt: new Date().toISOString(),
    gameTime: event.gameTime ?? event.data.gameTime,
  };
}

function isPlayerCommandEvent(event: WorldEventRecord): boolean {
  return event.type === PLAYER_COMMAND_EVENT_TYPE;
}

function resolvePlayerCommandCharacterId(event: WorldEventRecord): string | undefined {
  // Wire contract: backend godot-message-handler.ts sets event.actorId to the
  // player's character id. See world-events.ts PlayerCommandEventData.
  return event.actorId ? normalizeCharacterId(event.actorId) : undefined;
}

function normalizeCharacterId(value: string): string {
  return resolveCharacterIdByName(value) ?? value;
}

// ai_takeover 事件在 data 上携带选定模型：{ actionModel, thinkingModel }（raw `provider:model[/level]`）。
function takeoverModelsFromEvent(event: WorldEventRecord): TwoTrackAgentModelsRaw {
  const data = event.data ?? {};
  return {
    action: typeof data.actionModel === "string" ? data.actionModel : undefined,
    thinking: typeof data.thinkingModel === "string" ? data.thinkingModel : undefined,
  };
}

function takeoverAgentTypeFromEvent(event: WorldEventRecord): string {
  const data = event.data ?? {};
  return typeof data.agentType === "string" && data.agentType.trim() ? data.agentType.trim() : "two-track";
}
