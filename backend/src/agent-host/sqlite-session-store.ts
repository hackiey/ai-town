import { rowToAgentSession, rowToAgentSessionMessage } from "../db/records.js";
import { toJsonColumn, type AppDb } from "../db/sqlite.js";
import type { AgentSessionMessageRecord, AgentSessionRecord } from "../agents/types.js";
import type {
  AgentSessionStore,
  AppendAgentSessionMessageInput,
  EnsureAgentSessionInput,
  UpdateAgentSessionMessageInput,
  UpdateAgentSessionUsageInput,
} from "./runtime.js";

export class SqliteAgentSessionStore implements AgentSessionStore {
  constructor(private readonly db: AppDb) {}

  async ensure(input: EnsureAgentSessionInput): Promise<AgentSessionRecord> {
    const now = new Date().toISOString();
    this.db.prepare(
      `INSERT INTO agent_sessions (id, townId, characterId, agentKind, createdAt, updatedAt, messageSeq)
       VALUES (?, ?, ?, ?, ?, ?, 0)
       ON CONFLICT(id) DO UPDATE SET updatedAt = excluded.updatedAt`,
    ).run(input.id, input.townId, input.characterId, input.agentKind, now, now);
    const row = this.db
      .prepare("SELECT * FROM agent_sessions WHERE id = ?")
      .get(input.id) as Record<string, unknown> | undefined;
    if (!row) {
      throw new Error(`agent session not found after upsert: ${input.id}`);
    }
    return rowToAgentSession(row);
  }

  async listMessages(
    sessionId: string,
    opts: { afterSeq?: number; limit?: number; order?: "asc" | "desc" } = {},
  ): Promise<AgentSessionMessageRecord[]> {
    const afterSeq = opts.afterSeq ?? 0;
    const order = opts.order ?? "asc";
    const limit = opts.limit == null ? undefined : Math.max(1, Math.floor(opts.limit));
    const sql = [
      `SELECT * FROM agent_session_messages WHERE sessionId = ? AND seq > ?`,
      `ORDER BY seq ${order === "desc" ? "DESC" : "ASC"}`,
      limit == null ? "" : "LIMIT ?",
    ].filter(Boolean).join(" ");
    const rows = limit == null
      ? this.db.prepare(sql).all(sessionId, afterSeq)
      : this.db.prepare(sql).all(sessionId, afterSeq, limit);
    return (rows as Record<string, unknown>[]).map(rowToAgentSessionMessage);
  }

  async appendMessage(input: AppendAgentSessionMessageInput): Promise<AgentSessionRecord> {
    const now = new Date().toISOString();
    const updatedRow = this.db
      .prepare(
        `UPDATE agent_sessions SET messageSeq = messageSeq + 1, updatedAt = ?
         WHERE id = ? RETURNING *`,
      )
      .get(now, input.sessionId) as Record<string, unknown> | undefined;
    if (!updatedRow) {
      throw new Error(`agent session disappeared while persisting message: ${input.sessionId}`);
    }
    const updated = rowToAgentSession(updatedRow);
    this.db.prepare(
      `INSERT INTO agent_session_messages
         (id, sessionId, townId, characterId, agentKind, seq, role, message, createdAt, gameTime, turnReason, toolsSnapshot, llmMessages, llmSystemPrompt, inventorySnapshot)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      input.id,
      input.sessionId,
      input.townId,
      input.characterId,
      input.agentKind,
      updated.messageSeq,
      input.role,
      toJsonColumn(input.message),
      now,
      toJsonColumn(input.gameTime),
      input.turnReason ?? null,
      input.toolsSnapshot ? toJsonColumn(input.toolsSnapshot) : null,
      input.llmMessages ? toJsonColumn(input.llmMessages) : null,
      input.llmSystemPrompt ?? null,
      input.inventorySnapshot ? toJsonColumn(input.inventorySnapshot) : null,
    );
    return updated;
  }

  async updateMessage(input: UpdateAgentSessionMessageInput): Promise<void> {
    const result = this.db.prepare(
      "UPDATE agent_session_messages SET message = ? WHERE id = ?",
    ).run(toJsonColumn(input.message), input.id);
    if (result.changes === 0) {
      throw new Error(`agent session message not found: ${input.id}`);
    }
  }

  async updateUsage(input: UpdateAgentSessionUsageInput): Promise<AgentSessionRecord> {
    const now = new Date().toISOString();
    this.db.prepare(
      `UPDATE agent_sessions SET
         lastUsage = ?,
         lastUsageTokenCount = ?,
         lastUsageCostUsd = ?,
         lastUsageUpdatedAt = ?,
         updatedAt = ?
       WHERE id = ?`,
    ).run(
      toJsonColumn(input.usage),
      input.tokenCount,
      input.costUsd ?? null,
      now,
      now,
      input.sessionId,
    );
    return this.requireSession(input.sessionId);
  }

  private requireSession(sessionId: string): AgentSessionRecord {
    const row = this.db
      .prepare("SELECT * FROM agent_sessions WHERE id = ?")
      .get(sessionId) as Record<string, unknown> | undefined;
    if (!row) {
      throw new Error(`agent session not found: ${sessionId}`);
    }
    return rowToAgentSession(row);
  }
}
