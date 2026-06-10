import fp from "fastify-plugin";
import { AgentHost } from "../agent-host/host.js";
import { loadNpcRuntimeConfig, loadNpcRuntimeRouter } from "../agent-host/router.js";
import { createSqliteAgentActionHost, recentWorldEventRecords } from "../agent-host/sqlite-actions.js";
import { SqliteAgentSessionStore } from "../agent-host/sqlite-session-store.js";
import { SqliteRuntimeStorage } from "../agent-host/sqlite-storage.js";
import { SqliteThinkingTurnStore } from "../agent-host/sqlite-thinking-turn-store.js";
import { worldEventRecordToWorldEvent } from "../godot-link/event-adapter.js";
import { assembleAgentContextFromManifest } from "../agent-shared/prompt-context/assemble-from-manifest.js";
import { createTwoTrackAgentRuntime } from "../runtimes/two-track-agent/runtime.js";
import { createNullAgentRuntime } from "../runtimes/null/runtime.js";
import { rowToWorldEvent } from "../db/records.js";
import { getCharacterGroups } from "../services/character-groups-service.js";
import { publishThinkingStatusToBus } from "../services/character-status-bus.js";
import {
  PERCEPTION_MANIFEST_BUS_PATTERN,
  parsePerceptionManifestBusChannel,
  parsePerceptionManifestBusPayload,
} from "../services/perception-manifest-bus.js";
import { GAME_TIME_BUS_PATTERN, parseGameTimeBusChannel, parseGameTimeBusPayload } from "../services/game-time-bus.js";
import { parseWorldEventBusChannel, parseWorldEventBusPayload, WORLD_EVENT_BUS_PATTERN } from "../services/world-event-bus.js";
import {
  getDebugAgentRunFilter,
  isCharacterEnabledByDebugFilter,
  type DebugAgentRunFilter,
} from "../services/debug-agent-run-filter.js";

// 原 worker.ts 进程整体并入网关进程后的 agent runtime 插件。删 Redis 后，原先经 Redis pub/sub
// 跨进程订阅的 world-event / perception-manifest / game-time 三条 bus 改走进程内 app.bus；
// action / character-status 由各自插件订阅。受 config.agent.enabled 门控：关掉则不构建 LLM
// runtime，backend 退化为纯网关（行为同原先 AGENT_ENABLED=false）。
export const agentRuntimePlugin = fp(async (app) => {
  const config = app.config;
  const db = app.db;
  const bus = app.bus;

  const agentSessionStore = new SqliteAgentSessionStore(db);
  const thinkingTurnStore = new SqliteThinkingTurnStore(db);

  // 启动时一次性 load npc 快照传给 two-track（用其 agent_models 字段挑双模型）；
  // 不做 hot reload，npcs.json 改动需要重启进程。
  const npcRuntimeConfigSnapshot = loadNpcRuntimeConfig();
  const twoTrackAgentRuntime = config.agent.enabled
    ? createTwoTrackAgentRuntime({ config: config.agent, logger: console, npcConfigs: npcRuntimeConfigSnapshot })
    : undefined;
  const nullRuntime = createNullAgentRuntime();
  const agentHosts = new Map<string, AgentHost>();
  if (!twoTrackAgentRuntime) {
    app.log.info({ availableModels: config.agent.availableModels.map((model) => model.raw) }, "character agent runtime disabled");
  }

  function enabledCharacterIdsForRuntime(filter: DebugAgentRunFilter): Set<string> | null {
    return filter.configured ? filter.enabledCharacterIds : null;
  }

  function agentHostForTown(townId: string): AgentHost | undefined {
    if (!twoTrackAgentRuntime) {
      return undefined;
    }
    const existing = agentHosts.get(townId);
    if (existing) {
      return existing;
    }

    const host = new AgentHost({
      townId,
      // 所有角色默认走 two-track-agent；个别 NPC 可在 npcs.json 用 agent_runtime 字段
      // 显式指定别的 runtime（目前只有 null 可选）。
      router: loadNpcRuntimeRouter(),
      runtimes: {
        "two-track-agent": twoTrackAgentRuntime,
        null: nullRuntime,
      },
      characterEnabled: (characterId) => (
        isCharacterEnabledByDebugFilter(getDebugAgentRunFilter(db), characterId)
      ),
      storage: (ctx) => new SqliteRuntimeStorage(db, ctx),
      actions: (ctx) => createSqliteAgentActionHost(db, bus, ctx.townId),
      sessions: agentSessionStore,
      thinkingTurns: thinkingTurnStore,
      recentEventRecords: (ctx, opts) => recentWorldEventRecords(db, ctx.townId, { ...opts, characterId: ctx.characterId }),
      characterGroups: (ctx) => getCharacterGroups(db, ctx.townId, ctx.characterId),
      currentContext: ({ townId: t, manifest }) => assembleAgentContextFromManifest(db, t, manifest),
      setThinkingStatus: (ctx) => {
        publishThinkingStatusToBus(
          bus,
          ctx.townId,
          ctx.characterId,
          ctx.active,
          ctx.reason,
          ctx.agentKind,
          ctx.source,
        );
      },
    });
    agentHosts.set(townId, host);
    return host;
  }

  async function handleWorldEventBusMessage(townId: string, raw: unknown): Promise<void> {
    let payload: ReturnType<typeof parseWorldEventBusPayload>;
    try {
      payload = parseWorldEventBusPayload(raw);
    } catch (error) {
      app.log.warn({ error, townId, raw }, "received malformed world event bus payload");
      return;
    }
    const { eventId, perception } = payload;

    const row = db
      .prepare("SELECT * FROM world_events WHERE townId = ? AND id = ?")
      .get(townId, eventId) as Record<string, unknown> | undefined;
    if (!row) {
      app.log.warn({ townId, eventId }, "world event bus payload referenced missing event");
      return;
    }

    const event = rowToWorldEvent(row);
    const typedEvent = worldEventRecordToWorldEvent(event);
    if (!typedEvent) {
      app.log.warn({ townId, eventId, type: event.type }, "ignored unknown world event type");
      return;
    }
    // 因果同步：在触发 turn 之前，先把事件自带的 target perception 写入缓存。同一 handler 内
    // 顺序 await 保证 manifest 严格先于 onEvent，彻底消除两条 channel 的 race。
    const host = agentHostForTown(event.townId);
    if (host && perception) {
      for (const manifest of Object.values(perception)) {
        host.ingestManifest(manifest);
      }
    }
    await host?.onEvent(typedEvent);
    if (event.gameTime) {
      const filter = getDebugAgentRunFilter(db);
      const enabled = enabledCharacterIdsForRuntime(filter);
      await twoTrackAgentRuntime?.onGameTime(event.townId, event.gameTime, enabled);
    }
  }

  function handlePerceptionManifestBusMessage(townId: string, raw: unknown): void {
    let payload: ReturnType<typeof parsePerceptionManifestBusPayload>;
    try {
      payload = parsePerceptionManifestBusPayload(raw);
    } catch (error) {
      app.log.warn({ error, townId, raw }, "received malformed perception manifest bus payload");
      return;
    }
    agentHostForTown(townId)?.ingestManifest(payload.manifest);
  }

  async function handleGameTimeBusMessage(townId: string, raw: unknown): Promise<void> {
    const payload = parseGameTimeBusPayload(raw);
    const filter = getDebugAgentRunFilter(db);
    const enabled = enabledCharacterIdsForRuntime(filter);
    await twoTrackAgentRuntime?.onGameTime(townId, payload.gameTime, enabled);
  }

  const onWorldEvent = (channel: string, raw: unknown) => {
    const townId = parseWorldEventBusChannel(channel);
    if (!townId) {
      app.log.warn({ channel }, "world event bus message on malformed channel");
      return;
    }
    handleWorldEventBusMessage(townId, raw).catch((error) => {
      app.log.error({ error, channel }, "failed to handle world event bus message");
    });
  };

  const onPerceptionManifest = (channel: string, raw: unknown) => {
    const townId = parsePerceptionManifestBusChannel(channel);
    if (!townId) {
      app.log.warn({ channel }, "perception manifest bus message on malformed channel");
      return;
    }
    handlePerceptionManifestBusMessage(townId, raw);
  };

  const onGameTime = (channel: string, raw: unknown) => {
    const townId = parseGameTimeBusChannel(channel);
    if (!townId) {
      app.log.warn({ channel }, "game time bus message on malformed channel");
      return;
    }
    handleGameTimeBusMessage(townId, raw).catch((error) => {
      app.log.error({ error, channel }, "failed to handle game time bus message");
    });
  };

  bus.psubscribe(WORLD_EVENT_BUS_PATTERN, onWorldEvent);
  bus.psubscribe(PERCEPTION_MANIFEST_BUS_PATTERN, onPerceptionManifest);
  bus.psubscribe(GAME_TIME_BUS_PATTERN, onGameTime);

  app.addHook("onClose", async () => {
    bus.punsubscribe(WORLD_EVENT_BUS_PATTERN, onWorldEvent);
    bus.punsubscribe(PERCEPTION_MANIFEST_BUS_PATTERN, onPerceptionManifest);
    bus.punsubscribe(GAME_TIME_BUS_PATTERN, onGameTime);
    twoTrackAgentRuntime?.stop();
  });
});
