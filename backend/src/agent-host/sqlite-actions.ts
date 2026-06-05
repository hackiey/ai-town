import type { MessageBus } from "../plugins/message-bus.js";
import { rowToActionLog, rowToWorldEvent } from "../db/records.js";
import { toJsonColumn, type AppDb } from "../db/sqlite.js";
import type { ActionLogRecord, WorldEventRecord } from "../godot-link/protocol.js";
import {
  recordFailedAction,
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
  bus: MessageBus,
  townId: string,
): AgentActionHost {
  return {
    submit: (input: SubmitGameActionInput, options?: SubmitGameActionOptions) => submitAction(db, bus, {
      townId,
      characterId: input.characterId,
      action: input.action,
      target: input.target,
      reason: input.reason,
      priority: input.priority,
      expiresAt: input.expiresAt,
      gameTime: input.gameTime,
    }, options),
    recordFailed: (input: SubmitGameActionInput, error: string) => recordFailedAction(db, {
      townId,
      characterId: input.characterId,
      action: input.action,
      target: input.target,
      reason: input.reason,
      priority: input.priority,
      expiresAt: input.expiresAt,
      gameTime: input.gameTime,
    }, error),
    get: async (actionId: string) => findAction(db, townId, actionId),
    recentForCharacter: async (characterId: string, limit: number) => recentActionsForCharacter(db, townId, characterId, limit),
    cancel: (action: ActionLogRecord, reason: string) => requestCancelAction(db, bus, action, reason),
    waitForTerminal: (action: ActionLogRecord, options?: WaitForGameActionOptions) => waitForActionTerminalStatus(db, action, options),
    emitWorldEvent: (input: EmitWorldEventInput) => emitWorldEvent(db, bus, townId, input),
  };
}

export function recentWorldEventRecords(
  db: AppDb,
  townId: string,
  opts: RecentEventRecordsOptions = {},
): WorldEventRecord[] {
  const limit = Math.max(1, Math.floor(opts.limit ?? 100));
  const since = opts.sinceMs == null ? undefined : new Date(Date.now() - opts.sinceMs).toISOString();

  // 历史 bug：原来按"全局最新 N 条"取，再 JS 按角色过滤。全镇几十个 NPC 事件率高，
  // N=160 只覆盖 ~25 game-min，导致 action 轨"历史事件（1–8小时前）"段饿死。
  // 给了 characterId 就在 SQL 层先按角色相关过滤，再 LIMIT，这样 LIMIT 条都是本角色相关的，
  // 足够覆盖整个游戏时间窗。相关判定与 isEventRelevantToCharacter（events.ts）口径一致的超集：
  //   actor 自己 ∪ 事件 data 里出现该角色 id（affected/target/visible…）∪ 全局事件。
  // data LIKE 用带引号的 id 片段，避免子串误匹配；精确再判由 builder 的 JS 过滤兜。
  const clauses: string[] = ["townId = ?"];
  const params: unknown[] = [townId];
  if (opts.type) {
    clauses.push("type = ?");
    params.push(opts.type);
  }
  if (since) {
    clauses.push("createdAt >= ?");
    params.push(since);
  }
  if (opts.characterId) {
    clauses.push(`(actorId = ? OR data LIKE ? OR data LIKE '%"scope":"global"%' OR data LIKE '%"global":true%')`);
    params.push(opts.characterId, `%"${opts.characterId}"%`);
  }
  params.push(limit);
  const rows = db.prepare(
    `SELECT * FROM world_events
     WHERE ${clauses.join(" AND ")}
     ORDER BY createdAt DESC, id DESC LIMIT ?`,
  ).all(...params);
  return (rows as Record<string, unknown>[]).map(rowToWorldEvent);
}

function findAction(db: AppDb, townId: string, actionId: string): ActionLogRecord | undefined {
  const row = db
    .prepare("SELECT * FROM action_log WHERE townId = ? AND actionId = ?")
    .get(townId, actionId) as Record<string, unknown> | undefined;
  return row ? rowToActionLog(row) : undefined;
}

export function recentActionsForCharacter(db: AppDb, townId: string, characterId: string, limit: number): ActionLogRecord[] {
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
  bus: MessageBus,
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
  publishWorldEventToBus(bus, townId, eventId);
  const row = db
    .prepare("SELECT * FROM world_events WHERE townId = ? AND id = ?")
    .get(townId, eventId) as Record<string, unknown> | undefined;
  if (!row) {
    throw new Error(`world event not found after insert: ${eventId}`);
  }
  return rowToWorldEvent(row);
}
