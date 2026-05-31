import type { Redis } from "ioredis";
import { rowToActionLog } from "../db/records.js";
import { toJsonColumn, type AppDb } from "../db/sqlite.js";
import {
  SERVER_MESSAGE,
  type ActionSubmission,
  type ActionCancelPayload,
  type ActionLogRecord,
  type GameTimeSnapshot,
  type ActionAckPayload,
} from "../godot-link/protocol.js";
import type { AgentConnectionRegistry } from "../godot-link/agent-connection-registry.js";
import { publishActionCancelToBus, publishActionToBus } from "./action-bus.js";
import { createMessageId } from "./ids.js";

export type SubmitActionInput = {
  townId: string;
  characterId: string;
  action: ActionSubmission["action"];
  target?: Record<string, unknown>;
  reason?: string;
  priority?: number;
  expiresAt?: string;
  gameTime?: GameTimeSnapshot;
};

export type SubmitActionOptions = {
  preempt?: boolean;
};

export type WaitForActionTerminalStatusOptions = {
  signal?: AbortSignal;
  pollIntervalMs?: number;
  timeoutMs?: number;
  failOnTimeout?: boolean;
  timeoutError?: string;
};

const TERMINAL_STATUSES = new Set(["completed", "failed", "cancelled"]);
const POLL_INTERVAL_MS = 250;
const RESULT_TIMEOUT_MS = 180_000;

export async function submitAction(
  db: AppDb,
  redis: Redis,
  input: SubmitActionInput,
  options: SubmitActionOptions = {},
): Promise<ActionLogRecord> {
  const now = new Date().toISOString();
  const characterId = normalizeCharacterId(input.characterId);
  const target = input.target ?? {};
  const record: ActionLogRecord = {
    id: createMessageId("action"),
    townId: input.townId,
    characterId,
    action: input.action,
    target,
    reason: input.reason,
    priority: clampPriority(input.priority ?? 0.5),
    expiresAt: input.expiresAt,
    createdAt: now,
    gameTime: input.gameTime,
    status: "submitted",
  };

  insertActionLog(db, record);
  if (options.preempt) {
    await requestCancelOpenActionForCharacter(db, redis, record.townId, record.characterId, record.id);
  }
  await publishActionToBus(redis, record.townId, record.id);
  return record;
}

export async function handleActionDelivery(
  db: AppDb,
  _redis: Redis,
  registry: AgentConnectionRegistry,
  townId: string,
  actionId: string,
): Promise<{ delivered: boolean; reason?: string }> {
  if (!registry.hasConnection(townId)) {
    return { delivered: false, reason: "no-godot-agent-connection" };
  }

  const action = findAction(db, townId, actionId);
  if (!action) {
    return { delivered: false, reason: "action-not-found" };
  }
  if (TERMINAL_STATUSES.has(action.status)) {
    return { delivered: false, reason: "action-terminal" };
  }

  const envelope = registry.send(action.townId, SERVER_MESSAGE.actionSubmit, toActionSubmissionPayload(action));
  if (!envelope) {
    return { delivered: false, reason: "send-failed" };
  }

  db.prepare(
    `UPDATE action_log SET status = 'pushed', pushedAt = COALESCE(pushedAt, ?), pushedMessageId = ?
     WHERE townId = ? AND actionId = ? AND status IN ('submitted', 'pushed', 'accepted', 'cancelling')`,
  ).run(envelope.createdAt, envelope.id, townId, actionId);
  return { delivered: true };
}

export async function handleActionCancelDelivery(
  db: AppDb,
  registry: AgentConnectionRegistry,
  townId: string,
  actionId: string,
): Promise<{ delivered: boolean; reason?: string }> {
  if (!registry.hasConnection(townId)) {
    return { delivered: false, reason: "no-godot-agent-connection" };
  }
  const action = findAction(db, townId, actionId);
  if (!action || TERMINAL_STATUSES.has(action.status)) {
    return { delivered: false, reason: "action-not-cancellable" };
  }
  const payload: ActionCancelPayload = {
    actionId: action.id,
    characterId: action.characterId,
    reason: action.error ?? "interrupted",
    requestedAt: new Date().toISOString(),
  };
  return registry.send(action.townId, SERVER_MESSAGE.actionCancel, payload)
    ? { delivered: true }
    : { delivered: false, reason: "send-failed" };
}

export async function requestCancelAction(
  db: AppDb,
  redis: Redis,
  action: ActionLogRecord,
  reason: string,
): Promise<ActionLogRecord> {
  if (TERMINAL_STATUSES.has(action.status)) {
    return action;
  }
  const now = new Date().toISOString();
  if (action.status === "submitted") {
    db.prepare(
      `UPDATE action_log SET status = 'cancelled', terminalAt = ?, terminalStatus = 'cancelled', error = ?
       WHERE townId = ? AND actionId = ? AND status = 'submitted'`,
    ).run(now, reason, action.townId, action.id);
    return findAction(db, action.townId, action.id) ?? { ...action, status: "cancelled", cancelledAt: now, error: reason };
  }

  db.prepare(
    `UPDATE action_log SET status = 'cancelling', error = ?
     WHERE townId = ? AND actionId = ? AND status IN ('pushed', 'accepted', 'cancelling')`,
  ).run(reason, action.townId, action.id);
  await publishActionCancelToBus(redis, action.townId, action.id);
  return findAction(db, action.townId, action.id) ?? { ...action, status: "cancelling", error: reason };
}

export async function recordActionAck(
  db: AppDb,
  _redis: Redis,
  townId: string,
  payload: ActionAckPayload,
): Promise<void> {
  const actionId = payload.actionId ?? payload.messageId;
  if (!actionId || !payload.status) {
    return;
  }
  const current = findAction(db, townId, actionId);
  if (!current || TERMINAL_STATUSES.has(current.status)) {
    return;
  }
  const now = new Date().toISOString();
  const result = payload.result;

  if (payload.status === "accepted") {
    db.prepare(
      `UPDATE action_log SET status = 'accepted', acceptedAt = COALESCE(acceptedAt, ?), acceptedGameTime = COALESCE(acceptedGameTime, ?), result = COALESCE(?, result)
       WHERE townId = ? AND actionId = ? AND status IN ('submitted', 'pushed', 'accepted')`,
    ).run(now, toJsonColumn(payload.gameTime), toJsonColumn(result), townId, actionId);
    return;
  }

  const terminalStatus = payload.status === "interrupted" ? "cancelled" : payload.status;
  const terminalError = payload.error
    ?? current.error
    ?? (payload.status === "interrupted" ? "runtime interrupted action" : undefined);
  db.prepare(
    `UPDATE action_log SET status = ?, terminalAt = ?, terminalStatus = ?, terminalGameTime = COALESCE(?, terminalGameTime), error = ?, result = COALESCE(?, result)
     WHERE townId = ? AND actionId = ? AND status IN ('submitted', 'pushed', 'accepted', 'cancelling')`,
  ).run(
    terminalStatus,
    now,
    payload.status,
    toJsonColumn(payload.gameTime),
    terminalError ?? null,
    toJsonColumn(result),
    townId,
    actionId,
  );
}

export async function waitForActionTerminalStatus(
  db: AppDb,
  _redis: Redis,
  action: ActionLogRecord,
  options: WaitForActionTerminalStatusOptions = {},
): Promise<ActionLogRecord> {
  const pollIntervalMs = options.pollIntervalMs ?? POLL_INTERVAL_MS;
  const timeoutMs = options.timeoutMs ?? RESULT_TIMEOUT_MS;
  const failOnTimeout = options.failOnTimeout ?? true;
  const timeoutError = options.timeoutError ?? "godot_action_timeout";
  const waitStart = Date.now();
  let current = action;

  const describe = (): string => abortDescription(current, waitStart);

  while (!TERMINAL_STATUSES.has(current.status)) {
    throwIfAborted(options.signal, describe);
    // timeoutMs 是「调用方愿意等多久」的预算（max-wait budget），从本次调用进入开始算，
    // 不是 action 创建至今的年龄。否则对早就提交、还没完成的 action（如长跑的 plan_farm_work）
    // 会立即返回 pending，cancel/wait 路径都拿不到 Godot 真实回执。
    if (Date.now() - waitStart > timeoutMs) {
      if (failOnTimeout) {
        const now = new Date().toISOString();
        db.prepare(
          `UPDATE action_log SET status = 'failed', terminalAt = ?, terminalStatus = 'failed', error = ?
           WHERE townId = ? AND actionId = ? AND status IN ('submitted', 'pushed', 'accepted', 'cancelling')`,
        ).run(now, timeoutError, current.townId, current.id);
        return findAction(db, current.townId, current.id) ?? { ...current, status: "failed", failedAt: now, error: timeoutError };
      }
      return current;
    }
    await delay(pollIntervalMs, options.signal, describe);
    const latest = findAction(db, current.townId, current.id);
    if (!latest) {
      throw new Error(`action disappeared before completion: ${current.id}`);
    }
    current = latest;
  }

  return current;
}

function insertActionLog(db: AppDb, record: ActionLogRecord): void {
  db.prepare(
    `INSERT INTO action_log (
       actionId, townId, characterId, action, target, reason, priority, expiresAt, gameTime, submittedAt, status
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'submitted')`,
  ).run(
    record.id,
    record.townId,
    record.characterId,
    record.action,
    JSON.stringify(record.target ?? {}),
    record.reason ?? null,
    record.priority,
    record.expiresAt ?? null,
    toJsonColumn(record.gameTime),
    record.createdAt,
  );
}

function findAction(db: AppDb, townId: string, actionId: string): ActionLogRecord | null {
  const row = db
    .prepare("SELECT * FROM action_log WHERE townId = ? AND actionId = ?")
    .get(townId, actionId) as Record<string, unknown> | undefined;
  return row ? rowToActionLog(row) : null;
}

async function requestCancelOpenActionForCharacter(
  db: AppDb,
  redis: Redis,
  townId: string,
  characterId: string,
  replacementId: string,
): Promise<void> {
  const rows = db.prepare(
    `SELECT actionId FROM action_log
     WHERE townId = ? AND characterId = ? AND status IN ('pushed', 'accepted')`,
  ).all(townId, characterId) as Array<{ actionId: string }>;
  for (const row of rows) {
    db.prepare(
      `UPDATE action_log SET status = 'cancelling', error = ? WHERE townId = ? AND actionId = ?`,
    ).run(`preempted by ${replacementId}`, townId, row.actionId);
    await publishActionCancelToBus(redis, townId, row.actionId);
  }
}

function normalizeCharacterId(value: string): string {
  return value;
}

function toActionSubmissionPayload(record: ActionLogRecord): ActionSubmission {
  return {
    id: record.id,
    townId: record.townId,
    characterId: normalizeCharacterId(record.characterId),
    action: record.action,
    target: record.target,
    reason: record.reason,
    priority: record.priority,
    expiresAt: record.expiresAt,
    createdAt: record.createdAt,
    gameTime: record.gameTime,
  };
}

function clampPriority(priority: number): number {
  return Number.isFinite(priority) ? Math.min(1, Math.max(0, priority)) : 0.5;
}

function abortDescription(record: ActionLogRecord, waitStart: number): string {
  const elapsedMs = Math.max(0, Date.now() - waitStart);
  return `action=${record.action} id=${record.id} status=${record.status} elapsed=${elapsedMs}ms`;
}

function abortReasonText(signal: AbortSignal | undefined): string {
  const reason = signal?.reason as unknown;
  if (reason instanceof Error) return reason.message;
  if (typeof reason === "string" && reason.length > 0) return reason;
  return "unknown";
}

function throwIfAborted(signal: AbortSignal | undefined, describe: () => string): void {
  if (signal?.aborted) {
    throw new Error(`action wait aborted (${describe()}, reason=${abortReasonText(signal)})`);
  }
}

function delay(ms: number, signal: AbortSignal | undefined, describe: () => string): Promise<void> {
  if (ms <= 0) {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new Error(`action wait aborted (${describe()}, reason=${abortReasonText(signal)})`));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}
