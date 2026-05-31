import "dotenv/config";
import { Redis } from "ioredis";
import { AgentHost } from "./agent-host/host.js";
import { loadNpcRuntimeConfig, loadNpcRuntimeRouter } from "./agent-host/router.js";
import { createSqliteAgentActionHost, recentWorldEventRecords } from "./agent-host/sqlite-actions.js";
import { SqliteAgentSessionStore } from "./agent-host/sqlite-session-store.js";
import { SqliteRuntimeStorage } from "./agent-host/sqlite-storage.js";
import { SqliteThinkingTurnStore } from "./agent-host/sqlite-thinking-turn-store.js";
import { worldEventRecordToWorldEvent } from "./godot-link/event-adapter.js";
import { assembleAgentContextFromManifest } from "./agent-shared/prompt-context/assemble-from-manifest.js";
import { createTwoTrackAgentRuntime } from "./runtimes/two-track-agent/runtime.js";
import { createNullAgentRuntime } from "./runtimes/null/runtime.js";
import { loadConfig } from "./config/env.js";
import { rowToWorldEvent } from "./db/records.js";
import { openDatabase } from "./db/sqlite.js";
import {
  PERCEPTION_MANIFEST_BUS_PATTERN,
  parsePerceptionManifestBusChannel,
  parsePerceptionManifestBusPayload,
} from "./services/perception-manifest-bus.js";
import { GAME_TIME_BUS_PATTERN, parseGameTimeBusChannel, parseGameTimeBusPayload } from "./services/game-time-bus.js";
import { getCharacterGroups } from "./services/character-groups-service.js";
import { publishThinkingStatusToBus } from "./services/character-status-bus.js";
import { parseWorldEventBusChannel, parseWorldEventBusPayload, WORLD_EVENT_BUS_PATTERN } from "./services/world-event-bus.js";
import {
  getDebugAgentRunFilter,
  isCharacterEnabledByDebugFilter,
  type DebugAgentRunFilter,
} from "./services/debug-agent-run-filter.js";

const config = loadConfig();
const db = openDatabase(config.dbPath);
const redis = new Redis(config.redisUrl);
const subRedis = new Redis(config.redisUrl);
const agentSessionStore = new SqliteAgentSessionStore(db);
const thinkingTurnStore = new SqliteThinkingTurnStore(db);

// agent.enabled=false 时整套 LLM 都关。启动时一次性 load npc 快照传给 two-track
//（用其 agent_models 字段挑双模型）；不做 hot reload，npcs.json 改动需要重启 worker。
const npcRuntimeConfigSnapshot = loadNpcRuntimeConfig();
const twoTrackAgentRuntime = config.agent.enabled
  ? createTwoTrackAgentRuntime({ config: config.agent, logger: console, npcConfigs: npcRuntimeConfigSnapshot })
  : undefined;
const nullRuntime = createNullAgentRuntime();
const agentHosts = new Map<string, AgentHost>();
if (!twoTrackAgentRuntime) {
  console.info({ availableModels: config.agent.availableModels.map((model) => model.raw) }, "character agent runtime disabled");
}

subRedis.on("pmessage", (_pattern, channel, raw) => {
  const worldEventTownId = parseWorldEventBusChannel(channel);
  if (worldEventTownId) {
    handleWorldEventBusMessage(worldEventTownId, channel, raw).catch((error) => {
      console.error({ error, channel, raw }, "failed to handle world event bus message");
    });
    return;
  }

  const manifestTownId = parsePerceptionManifestBusChannel(channel);
  if (manifestTownId) {
    handlePerceptionManifestBusMessage(manifestTownId, channel, raw).catch((error) => {
      console.error({ error, channel, raw }, "failed to handle perception manifest bus message");
    });
    return;
  }

  const gameTimeTownId = parseGameTimeBusChannel(channel);
  if (gameTimeTownId) {
    handleGameTimeBusMessage(gameTimeTownId, raw).catch((error) => {
      console.error({ error, channel, raw }, "failed to handle game time bus message");
    });
    return;
  }

  console.warn({ channel, raw }, "received message on unknown worker channel");
});
await subRedis.psubscribe(WORLD_EVENT_BUS_PATTERN, PERCEPTION_MANIFEST_BUS_PATTERN, GAME_TIME_BUS_PATTERN);

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
    characterEnabled: async (characterId) => (
      isCharacterEnabledByDebugFilter(await getDebugAgentRunFilter(redis), characterId)
    ),
    storage: (ctx) => new SqliteRuntimeStorage(db, ctx),
    actions: (ctx) => createSqliteAgentActionHost(db, redis, ctx.townId),
    sessions: agentSessionStore,
    thinkingTurns: thinkingTurnStore,
    recentEventRecords: (ctx, opts) => recentWorldEventRecords(db, ctx.townId, opts),
    characterGroups: (ctx) => getCharacterGroups(db, ctx.townId, ctx.characterId),
    currentContext: ({ townId: t, manifest }) => assembleAgentContextFromManifest(db, t, manifest),
    setThinkingStatus: async (ctx) => {
      await publishThinkingStatusToBus(
        redis,
        ctx.townId,
        ctx.characterId,
        ctx.active,
        ctx.reason,
        ctx.agentKind,
      );
    },
  });
  agentHosts.set(townId, host);
  return host;
}

async function handleWorldEventBusMessage(townId: string, channel: string, raw: string): Promise<void> {
  let payload: ReturnType<typeof parseWorldEventBusPayload>;
  try {
    payload = parseWorldEventBusPayload(raw);
  } catch (error) {
    console.warn({ error, channel, raw }, "received malformed world event bus payload");
    return;
  }
  const { eventId, perception } = payload;

  const row = db
    .prepare("SELECT * FROM world_events WHERE townId = ? AND id = ?")
    .get(townId, eventId) as Record<string, unknown> | undefined;
  if (!row) {
    console.warn({ townId, eventId }, "world event bus payload referenced missing event");
    return;
  }

  const event = rowToWorldEvent(row);
  const typedEvent = worldEventRecordToWorldEvent(event);
  if (!typedEvent) {
    console.warn({ townId, eventId, type: event.type }, "ignored unknown world event type");
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
    const filter = await getDebugAgentRunFilter(redis);
    const enabled = enabledCharacterIdsForRuntime(filter);
    await twoTrackAgentRuntime?.onGameTime(event.townId, event.gameTime, enabled);
  }
}

async function handlePerceptionManifestBusMessage(townId: string, channel: string, raw: string): Promise<void> {
  let payload: ReturnType<typeof parsePerceptionManifestBusPayload>;
  try {
    payload = parsePerceptionManifestBusPayload(raw);
  } catch (error) {
    console.warn({ error, channel, raw }, "received malformed perception manifest bus payload");
    return;
  }
  agentHostForTown(townId)?.ingestManifest(payload.manifest);
}

async function handleGameTimeBusMessage(townId: string, raw: string): Promise<void> {
  const payload = parseGameTimeBusPayload(raw);
  const filter = await getDebugAgentRunFilter(redis);
  const enabled = enabledCharacterIdsForRuntime(filter);
  await twoTrackAgentRuntime?.onGameTime(townId, payload.gameTime, enabled);
}

function enabledCharacterIdsForRuntime(filter: DebugAgentRunFilter): Set<string> | null {
  return filter.configured ? filter.enabledCharacterIds : null;
}

const shutdown = async () => {
  twoTrackAgentRuntime?.stop();
  await subRedis.punsubscribe(WORLD_EVENT_BUS_PATTERN, PERCEPTION_MANIFEST_BUS_PATTERN, GAME_TIME_BUS_PATTERN);
  await subRedis.quit();
  await redis.quit();
  db.close();
  process.exit(0);
};

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
