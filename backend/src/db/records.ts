// Row → typed Record 转换器。每个 SQL 查询读出来的 row 是 Record<string, unknown>，
// 这里集中处理 NULL → undefined、JSON 列 parse、字段命名一致性。
//
// 目的：让 service 层和 agent prompt builder 共用同一套转换，避免每处自己处理 nulls。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { Usage } from "@mariozechner/pi-ai";
import { parseJsonColumn } from "./sqlite.js";
import type {
  AgentInventorySnapshot,
  AgentSessionMessageRecord,
  AgentSessionRecord,
  AgentToolSnapshot,
} from "../agents/types.js";
import type { ActionLogRecord, GameTimeSnapshot, RuntimeSessionRecord, WorldEventRecord } from "../godot-link/protocol.js";

type Row = Record<string, unknown>;

const str = (v: unknown): string | undefined => (typeof v === "string" && v.length > 0 ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" ? v : undefined);

export function rowToActionLog(row: Row): ActionLogRecord {
  const targetRaw = row.target;
  let target: Record<string, unknown> | undefined;
  if (targetRaw == null) {
    target = undefined;
  } else if (typeof targetRaw === "string") {
    target = parseJsonColumn<Record<string, unknown>>(targetRaw) ?? {};
  } else {
    target = targetRaw as Record<string, unknown>;
  }

  const status = String(row.status ?? row.terminalStatus ?? "submitted") as ActionLogRecord["status"];
  const terminalAt = str(row.terminalAt);

  return {
    id: String(row.actionId ?? row.id),
    townId: row.townId as string,
    characterId: row.characterId as string,
    action: row.action as ActionLogRecord["action"],
    target,
    reason: str(row.reason),
    priority: typeof row.priority === "number" ? row.priority : Number(row.priority ?? 0.5),
    expiresAt: str(row.expiresAt),
    createdAt: String(row.submittedAt ?? row.createdAt),
    gameTime: parseJsonColumn(row.gameTime),
    status,
    pushedAt: str(row.pushedAt),
    pushedMessageId: str(row.pushedMessageId),
    acceptedAt: str(row.acceptedAt),
    acceptedGameTime: parseJsonColumn(row.acceptedGameTime),
    completedAt: status === "completed" ? terminalAt : undefined,
    completedGameTime: status === "completed" ? parseJsonColumn(row.terminalGameTime) : undefined,
    failedAt: status === "failed" ? terminalAt : undefined,
    failedGameTime: status === "failed" ? parseJsonColumn(row.terminalGameTime) : undefined,
    cancelledAt: status === "cancelled" ? terminalAt : undefined,
    error: str(row.error),
    result: parseJsonColumn(row.result),
  };
}

export function rowToWorldEvent(row: Row): WorldEventRecord {
  return {
    id: row.id as string,
    townId: row.townId as string,
    type: row.type as string,
    actorId: str(row.actorId),
    spokenText: str(row.spokenText),
    data: parseJsonColumn<Record<string, unknown>>(row.data),
    occurredAt: row.occurredAt as string,
    createdAt: row.createdAt as string,
    gameTime: parseJsonColumn(row.gameTime),
  };
}

export function rowToAgentSession(row: Row): AgentSessionRecord {
  return {
    id: row.id as string,
    townId: row.townId as string,
    characterId: row.characterId as string,
    agentKind: row.agentKind as AgentSessionRecord["agentKind"],
    createdAt: row.createdAt as string,
    updatedAt: row.updatedAt as string,
    messageSeq: row.messageSeq as number,
    lastUsage: parseJsonColumn(row.lastUsage),
    lastUsageTokenCount: num(row.lastUsageTokenCount),
    lastUsageCostUsd: num(row.lastUsageCostUsd),
    lastUsageUpdatedAt: str(row.lastUsageUpdatedAt),
  };
}

export function rowToAgentSessionMessage(row: Row): AgentSessionMessageRecord {
  return {
    id: row.id as string,
    sessionId: row.sessionId as string,
    townId: row.townId as string,
    characterId: row.characterId as string,
    agentKind: row.agentKind as AgentSessionMessageRecord["agentKind"],
    seq: row.seq as number,
    role: row.role as string,
    message: parseJsonColumn(row.message)!,
    createdAt: row.createdAt as string,
    gameTime: parseJsonColumn(row.gameTime),
    turnReason: str(row.turnReason),
    toolsSnapshot: parseJsonColumn<AgentToolSnapshot[]>(row.toolsSnapshot),
    llmMessages: parseJsonColumn<AgentSessionMessageRecord["message"][]>(row.llmMessages),
    llmSystemPrompt: str(row.llmSystemPrompt),
    inventorySnapshot: parseJsonColumn<AgentInventorySnapshot>(row.inventorySnapshot),
  };
}

export interface ThinkingTurnRecord {
  id: string;
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
}

export function rowToThinkingTurn(row: Row): ThinkingTurnRecord {
  return {
    id: row.id as string,
    townId: row.townId as string,
    characterId: row.characterId as string,
    triggerReason: row.triggerReason as string,
    intent: str(row.intent),
    startedAt: row.startedAt as string,
    endedAt: row.endedAt as string,
    durationMs: row.durationMs as number,
    startGameTime: parseJsonColumn<GameTimeSnapshot>(row.startGameTime),
    endGameTime: parseJsonColumn<GameTimeSnapshot>(row.endGameTime),
    modelId: str(row.modelId),
    systemPrompt: row.systemPrompt as string,
    userPrompt: row.userPrompt as string,
    assistantMessage: parseJsonColumn<AgentMessage>(row.assistantMessage),
    writtenContent: str(row.writtenContent),
    previousMemoryUpdatedAt: str(row.previousMemoryUpdatedAt),
    usage: parseJsonColumn<Usage>(row.usage),
    totalTokens: num(row.totalTokens),
    costUsd: num(row.costUsd),
    error: str(row.error),
  };
}

export function rowToRuntimeSession(row: Row): RuntimeSessionRecord {
  return {
    townId: row.townId as string,
    instanceId: row.instanceId as string,
    connectedAt: row.connectedAt as string,
    disconnectedAt: str(row.disconnectedAt),
    lastSeenAt: row.lastSeenAt as string,
    lastAckSeq: row.lastAckSeq as number,
  };
}
