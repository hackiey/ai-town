import type { FastifyInstance } from "fastify";
import { toJsonColumn } from "../db/sqlite.js";
import { isActionAckStatus, isKnownActionName } from "../godot-link/actions.js";
import { normalizeWorldEventPayload } from "../godot-link/event-adapter.js";
import { normalizeManifestPayload, type PerceptionManifestPayload } from "../godot-link/perception-manifest.js";
import {
  RUNTIME_MESSAGE,
  SERVER_MESSAGE,
  assertCompatibleEnvelopeVersion,
  type ActionAckPayload,
  type ActionRequestPayload,
  type CharacterRegisterPayload,
  type CharacterUnregisterPayload,
  type MessageEnvelope,
  type PlayerCommandPayload,
  type ProtocolAckPayload,
  type ReactionCatalogSyncPayload,
  type RuntimeHeartbeatPayload,
  type WorldEventPayload,
  type WorldEventRecord,
} from "../godot-link/protocol.js";
import { createMessageId } from "../services/ids.js";
import { recordActionAck, submitAction } from "../services/action-log-service.js";
import { publishGameTimeToBus } from "../services/game-time-bus.js";
import { publishPerceptionManifestToBus } from "../services/perception-manifest-bus.js";
import { auditCraftSkillConsistency, setReactionCatalog } from "../services/world-state/reaction-catalog.js";
import { registerRuntimeCharacter, unregisterRuntimeCharacter } from "../services/runtime-character-registry.js";
import { publishWorldEventToBus } from "../services/world-event-bus.js";
import { seedPlayerTakeoverMemories } from "../services/memory-service.js";
import { loadNpcRuntimeRouter } from "./router.js";

export async function handleGodotMessage(app: FastifyInstance, townId: string, raw: string): Promise<void> {
  const message = JSON.parse(raw) as MessageEnvelope;
  assertCompatibleEnvelopeVersion(message);
  if (message.townId !== townId) {
    throw new Error("message townId does not match connection townId");
  }

  app.agentConnections.touch(townId);

  switch (message.type) {
    case RUNTIME_MESSAGE.heartbeat:
      {
        const payload = message.payload as RuntimeHeartbeatPayload;
        app.log.debug({ townId, payload }, "runtime heartbeat");
        if (payload.gameTime) {
          await publishGameTimeToBus(app.redis, townId, payload.gameTime);
        }
      }
      app.agentConnections.send(townId, SERVER_MESSAGE.pong, { serverTime: new Date().toISOString() });
      return;

    case RUNTIME_MESSAGE.perceptionManifest:
      await handlePerceptionManifest(app, townId, message.payload as Record<string, unknown>);
      return;

    case RUNTIME_MESSAGE.characterRegister:
      handleCharacterRegister(app, townId, message.payload as CharacterRegisterPayload);
      return;

    case RUNTIME_MESSAGE.characterUnregister:
      handleCharacterUnregister(app, townId, message.payload as CharacterUnregisterPayload);
      return;

    case RUNTIME_MESSAGE.actionAck:
      await handleActionAck(app, townId, message.payload as ActionAckPayload);
      return;

    case RUNTIME_MESSAGE.actionRequest:
      await handleActionRequest(app, townId, message.payload as ActionRequestPayload);
      return;

    case RUNTIME_MESSAGE.playerCommand:
      await handlePlayerCommand(app, townId, message.payload as PlayerCommandPayload);
      return;

    case RUNTIME_MESSAGE.worldEvent:
      await handleWorldEvent(app, townId, message.payload as WorldEventPayload);
      return;

    case RUNTIME_MESSAGE.requestAvailableModels:
      handleRequestAvailableModels(app, townId);
      return;

    case RUNTIME_MESSAGE.ping:
      app.agentConnections.send(townId, SERVER_MESSAGE.pong, { serverTime: new Date().toISOString() });
      return;

    case RUNTIME_MESSAGE.protocolAck:
      handleProtocolAck(app, townId, message.payload as ProtocolAckPayload);
      return;

    case RUNTIME_MESSAGE.reactionCatalog:
      handleReactionCatalogSync(app, message.payload as ReactionCatalogSyncPayload);
      return;

    default:
      throw new Error(`unsupported runtime message type: ${message.type}`);
  }
}

function handleReactionCatalogSync(app: FastifyInstance, payload: ReactionCatalogSyncPayload): void {
  const rows = Array.isArray(payload?.reactions) ? payload.reactions : [];
  setReactionCatalog(rows);
  app.log.info({ count: rows.length }, "reaction catalog synced from godot");
  // craft-registry.[axis].skillId 与 lua reaction.skill_id 的二次对账。
  // 不一致 = 数据维护漂移（craft-registry 改了名但 lua 没跟上 / 反之），早期就 warn 出来。
  const issues = auditCraftSkillConsistency();
  if (issues.length > 0) {
    app.log.warn({ issues }, "axis ↔ skill_id mismatch detected; check craft-registry.ts vs crafting.lua");
  }
}

function handleRequestAvailableModels(app: FastifyInstance, townId: string): void {
  // AI-takeover pickers need the model whitelist; backend is the single source
  // of truth (AGENT_AVAILABLE_MODELS). Mirror worker.ts's `.map((m) => m.raw)`.
  const models = app.config.agent.availableModels.map((model) => model.raw);
  app.agentConnections.send(townId, SERVER_MESSAGE.availableModels, { models });
}

function handleProtocolAck(app: FastifyInstance, townId: string, payload: ProtocolAckPayload): void {
  if (!Number.isInteger(payload.ackSeq) || payload.ackSeq < 0) {
    throw new Error("protocol ack missing valid ackSeq");
  }
  app.agentConnections.markAck(townId, payload.ackSeq);
}

function handleCharacterRegister(app: FastifyInstance, townId: string, payload: CharacterRegisterPayload): void {
  const characterId = payload?.characterId?.trim();
  if (!characterId) {
    throw new Error("character.register missing characterId");
  }
  const entry = registerRuntimeCharacter({
    characterId,
    displayName: payload.displayName,
    kind: payload.kind,
    aliases: payload.aliases,
  });
  app.log.debug({ townId, entry }, "character registered");
}

function handleCharacterUnregister(app: FastifyInstance, townId: string, payload: CharacterUnregisterPayload): void {
  const characterId = payload?.characterId?.trim();
  if (!characterId) {
    throw new Error("character.unregister missing characterId");
  }
  unregisterRuntimeCharacter(characterId);
  app.log.debug({ townId, characterId }, "character unregistered");
}

async function handlePerceptionManifest(app: FastifyInstance, townId: string, payload: Record<string, unknown>): Promise<void> {
  const normalized = normalizeManifestPayload(payload);
  if (!normalized.ok) {
    throw new Error(normalized.error);
  }
  await publishPerceptionManifestToBus(app.redis, townId, normalized.manifest);
}

async function handleActionRequest(app: FastifyInstance, townId: string, payload: ActionRequestPayload): Promise<void> {
  const characterId = payload?.characterId?.trim();
  const action = typeof payload?.action === "string" ? payload.action : "";
  if (!characterId || !action) {
    throw new Error("action request missing characterId or action");
  }
  if (!isKnownActionName(action)) {
    throw new Error(`unsupported action: ${action}`);
  }
  await submitAction(app.db, app.redis, {
    townId,
    characterId,
    action,
    target: payload.target,
    reason: payload.reason,
    priority: payload.priority,
    expiresAt: payload.expiresAt,
    gameTime: payload.gameTime,
  }, { preempt: payload.preempt });
}

async function handleActionAck(app: FastifyInstance, townId: string, payload: ActionAckPayload): Promise<void> {
  if (payload.status && !isActionAckStatus(payload.status)) {
    throw new Error(`unsupported action ack status: ${payload.status}`);
  }
  app.agentConnections.markAck(townId, payload.ackSeq);
  await recordActionAck(app.db, app.redis, townId, payload);
}

async function handlePlayerCommand(app: FastifyInstance, townId: string, payload: PlayerCommandPayload): Promise<void> {
  const playerId = payload?.playerId;
  const text = payload?.text?.trim();
  if (!playerId || !text) {
    throw new Error("player command missing playerId or text");
  }

  const characterId = payload.characterId?.trim() || playerId;
  const occurredAt = payload.issuedAt ?? new Date().toISOString();
  await recordAndPublishWorldEvent(app, townId, {
    eventId: payload.commandId,
    actorId: characterId,
    type: "player_command",
    // Wire contract: typed command words live on WorldEventRecord.spokenText.
    // See world-events.ts PlayerCommandEventData.
    spokenText: text,
    data: {
      actorId: characterId,
      affectedCharacterIds: [characterId],
      gameTime: payload.gameTime,
    },
    occurredAt,
    gameTime: payload.gameTime,
  });
}

async function handleWorldEvent(app: FastifyInstance, townId: string, payload: WorldEventPayload): Promise<void> {
  // AI 接管控制事件：在 record/publish 前先把玩家 seed 成 NPC 等价 memory（写 runtime_storage，
  // 与 worker 进程经共享 SQLite 通信），这样 worker 收到 ai_takeover 起首轮 turn 时 memory 已就位。
  if (payload.type === AI_TAKEOVER_EVENT_TYPE) {
    const characterId = payload.actorId?.trim() || stringFromData(payload.data, "actorId");
    if (characterId) {
      const router = loadNpcRuntimeRouter();
      seedPlayerTakeoverMemories(app.db, townId, characterId, (id) => router.runtimeFor(id));
      app.log.info({ townId, characterId }, "seeded player takeover memories");
    }
  }
  await recordAndPublishWorldEvent(app, townId, payload);
}

const AI_TAKEOVER_EVENT_TYPE = "ai_takeover";

function stringFromData(data: WorldEventPayload["data"], key: string): string | undefined {
  const value = data?.[key];
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

async function recordAndPublishWorldEvent(app: FastifyInstance, townId: string, payload: WorldEventPayload): Promise<boolean> {
  const now = new Date().toISOString();
  const normalized = normalizeWorldEventPayload(payload, {
    id: createMessageId("event"),
    townId,
    now,
  });
  if (!normalized.ok) {
    app.log.warn({ townId, type: normalized.type, reason: normalized.reason }, "ignored unsupported world event");
    return false;
  }
  const record: WorldEventRecord = normalized.record;

  // DB column name stays `spokenText` to match the schema in
  // src/autoload/db.gd (Godot owns the world_events table per
  // [feedback_backend_not_game_db_owner]).
  app.db.prepare(
    `INSERT INTO world_events (id, townId, type, actorId, spokenText, data, occurredAt, createdAt, gameTime)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    record.id,
    record.townId,
    record.type,
    record.actorId ?? null,
    record.spokenText ?? null,
    toJsonColumn(record.data),
    record.occurredAt,
    record.createdAt,
    toJsonColumn(record.gameTime),
  );
  await publishWorldEventToBus(app.redis, townId, record.id, normalizeEventPerception(payload.perception, now));
  return true;
}

// 把事件自带的 { cid: rawManifest } 逐个归一成 { cid: PerceptionManifestPayload }。
// 跳过缺 characterId 等非法项；空/缺失返回 undefined（worker 退回缓存行为）。
function normalizeEventPerception(
  perception: WorldEventPayload["perception"],
  now: string,
): Record<string, PerceptionManifestPayload> | undefined {
  if (!perception || typeof perception !== "object") {
    return undefined;
  }
  const out: Record<string, PerceptionManifestPayload> = {};
  for (const [characterId, raw] of Object.entries(perception)) {
    if (!raw || typeof raw !== "object") {
      continue;
    }
    const normalized = normalizeManifestPayload(raw as Record<string, unknown>, now);
    if (normalized.ok) {
      out[characterId] = normalized.manifest;
    }
  }
  return Object.keys(out).length > 0 ? out : undefined;
}
