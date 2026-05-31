// Thinking 慢轨每次 LLM call 持久化到 thinking_turns 表的写入入口。
// 一行 = 一次完整 thinking call（不像 agent_session_messages 那样按 message 拆行），
// 因此不需要 enqueue 队列：thinking-track runOnce 末尾一次 INSERT 即可。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { Usage } from "@mariozechner/pi-ai";
import { rowToThinkingTurn, type ThinkingTurnRecord } from "../db/records.js";
import { toJsonColumn, type AppDb } from "../db/sqlite.js";
import type { GameTimeSnapshot } from "../godot-link/protocol.js";
import { createMessageId } from "../services/ids.js";

export type RecordThinkingTurnInput = {
  townId: string;
  characterId: string;
  triggerReason: string;
  intent?: string;
  startedAt: string;
  endedAt: string;
  durationMs: number;
  startGameTime?: GameTimeSnapshot;
  endGameTime?: GameTimeSnapshot;
  modelId?: string;
  systemPrompt: string;
  userPrompt: string;
  assistantMessage?: AgentMessage;
  writtenContent?: string;
  previousMemoryUpdatedAt?: string;
  usage?: Usage;
  totalTokens?: number;
  costUsd?: number;
  error?: string;
};

export interface ThinkingTurnStore {
  record(input: RecordThinkingTurnInput): Promise<ThinkingTurnRecord>;
}

export class SqliteThinkingTurnStore implements ThinkingTurnStore {
  constructor(private readonly db: AppDb) {}

  async record(input: RecordThinkingTurnInput): Promise<ThinkingTurnRecord> {
    const id = createMessageId("thinking");
    this.db.prepare(
      `INSERT INTO thinking_turns
         (id, townId, characterId, triggerReason, intent,
          startedAt, endedAt, durationMs,
          startGameTime, endGameTime, modelId,
          systemPrompt, userPrompt, assistantMessage,
          writtenContent, previousMemoryUpdatedAt,
          usage, totalTokens, costUsd, error)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      id,
      input.townId,
      input.characterId,
      input.triggerReason,
      input.intent ?? null,
      input.startedAt,
      input.endedAt,
      input.durationMs,
      input.startGameTime ? toJsonColumn(input.startGameTime) : null,
      input.endGameTime ? toJsonColumn(input.endGameTime) : null,
      input.modelId ?? null,
      input.systemPrompt,
      input.userPrompt,
      input.assistantMessage ? toJsonColumn(input.assistantMessage) : null,
      input.writtenContent ?? null,
      input.previousMemoryUpdatedAt ?? null,
      input.usage ? toJsonColumn(input.usage) : null,
      input.totalTokens ?? null,
      input.costUsd ?? null,
      input.error ?? null,
    );
    const row = this.db
      .prepare("SELECT * FROM thinking_turns WHERE id = ?")
      .get(id) as Record<string, unknown> | undefined;
    if (!row) {
      throw new Error(`thinking turn not found after insert: ${id}`);
    }
    return rowToThinkingTurn(row);
  }
}
