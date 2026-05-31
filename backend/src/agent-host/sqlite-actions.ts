import type { Redis } from "ioredis";
import { rowToActionLog, rowToWorldEvent } from "../db/records.js";
import { toJsonColumn, type AppDb } from "../db/sqlite.js";
import type { ActionLogRecord, WorldEventRecord } from "../godot-link/protocol.js";
import {
  requestCancelAction,
  submitAction,
  waitForActionTerminalStatus,
} from "../services/action-log-service.js";
import { createMessageId } from "../services/ids.js";
import { publishWorldEventToBus } from "../services/world-event-bus.js";
import type {
  AgentActionHost,
  EmitWorldEventInput,
  RecentEventRecordsOptions,
  SubmitGameActionInput,
  SubmitGameActionOptions,
  WaitForGameActionOptions,
} from "./runtime.js";

export function createSqliteAgentActionHost(
  db: AppDb,
  redis: Redis,
  townId: string,
): AgentActionHost {
  return {
    submit: (input: SubmitGameActionInput, options?: SubmitGameActionOptions) => submitAction(db, redis, {
      townId,
      characterId: input.characterId,
      action: input.action,
      target: input.target,
      reason: input.reason,
      priority: input.priority,
      expiresAt: input.expiresAt,
      gameTime: input.gameTime,
    }, options),
    get: async (actionId: string) => findAction(db, townId, actionId),
    recentForCharacter: async (characterId: string, limit: number) => recentActionsForCharacter(db, townId, characterId, limit),
    cancel: (action: ActionLogRecord, reason: string) => requestCancelAction(db, redis, action, reason),
    waitForTerminal: (action: ActionLogRecord, options?: WaitForGameActionOptions) => waitForActionTerminalStatus(db, redis, action, options),
    emitWorldEvent: (input: EmitWorldEventInput) => emitWorldEvent(db, redis, townId, input),
  };
}

export function recentWorldEventRecords(
  db: AppDb,
  townId: string,
  opts: RecentEventRecordsOptions = {},
): WorldEventRecord[] {
  const limit = Math.max(1, Math.floor(opts.limit ?? 100));
  const since = opts.sinceMs == null ? undefined : new Date(Date.now() - opts.sinceMs).toISOString();
  const rows = opts.type
    ? since
      ? db.prepare(
        `SELECT * FROM world_events
         WHERE townId = ? AND type = ? AND createdAt >= ?
         ORDER BY createdAt DESC, id DESC LIMIT ?`,
      ).all(townId, opts.type, since, limit)
      : db.prepare(
        `SELECT * FROM world_events
         WHERE townId = ? AND type = ?
         ORDER BY createdAt DESC, id DESC LIMIT ?`,
      ).all(townId, opts.type, limit)
    : since
      ? db.prepare(
        `SELECT * FROM world_events
         WHERE townId = ? AND createdAt >= ?
         ORDER BY createdAt DESC, id DESC LIMIT ?`,
      ).all(townId, since, limit)
      : db.prepare(
        `SELECT * FROM world_events
         WHERE townId = ?
         ORDER BY createdAt DESC, id DESC LIMIT ?`,
      ).all(townId, limit);
  return (rows as Record<string, unknown>[]).map(rowToWorldEvent);
}

function findAction(db: AppDb, townId: string, actionId: string): ActionLogRecord | undefined {
  const row = db
    .prepare("SELECT * FROM action_log WHERE townId = ? AND actionId = ?")
    .get(townId, actionId) as Record<string, unknown> | undefined;
  return row ? rowToActionLog(row) : undefined;
}

function recentActionsForCharacter(db: AppDb, townId: string, characterId: string, limit: number): ActionLogRecord[] {
  const rows = db
    .prepare(
      `SELECT * FROM action_log
       WHERE townId = ? AND characterId = ?
       ORDER BY submittedAt DESC
       LIMIT ?`,
    )
    .all(townId, characterId, Math.max(1, Math.floor(limit))) as Record<string, unknown>[];
  return rows.map(rowToActionLog);
}

async function emitWorldEvent(
  db: AppDb,
  redis: Redis,
  townId: string,
  input: EmitWorldEventInput,
): Promise<WorldEventRecord> {
  const now = new Date().toISOString();
  const eventId = createMessageId("event");
  db.prepare(
    `INSERT INTO world_events (id, townId, type, actorId, text, data, occurredAt, createdAt, gameTime)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    eventId,
    townId,
    input.type,
    input.actorId ?? null,
    input.text ?? null,
    toJsonColumn(input.data ?? {}),
    input.occurredAt ?? now,
    now,
    toJsonColumn(input.gameTime),
  );
  await publishWorldEventToBus(redis, townId, eventId);
  const row = db
    .prepare("SELECT * FROM world_events WHERE townId = ? AND id = ?")
    .get(townId, eventId) as Record<string, unknown> | undefined;
  if (!row) {
    throw new Error(`world event not found after insert: ${eventId}`);
  }
  return rowToWorldEvent(row);
}
