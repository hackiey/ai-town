import type { FastifyPluginAsync } from "fastify";
import { rowToAgentSession, rowToAgentSessionMessage, rowToThinkingTurn } from "../db/records.js";
import { parseJsonColumn, type AppDb } from "../db/sqlite.js";
import { getActiveLocale } from "../i18n/index.js";
import type { AgentActionHost, AgentRuntimeContext } from "../agent-host/runtime.js";
import { recentWorldEventRecords } from "../agent-host/sqlite-actions.js";
import { SqliteAgentSessionStore } from "../agent-host/sqlite-session-store.js";
import { SqliteRuntimeStorage } from "../agent-host/sqlite-storage.js";
import { AgentRuntimeRouter, loadNpcRuntimeRouter } from "../agent-host/router.js";
import { TwoTrackAgentContextBuilder, renderAgentSystemContext } from "../runtimes/two-track-agent/prompt/index.js";
import { getCharacterGroups } from "../services/character-groups-service.js";
import { getDebugAgentRunFilter, setDebugAgentRunFilter } from "../services/debug-agent-run-filter.js";
import {
  buildBaseSystemPrompt,
  buildEffectiveSystemPrompt,
  isInterruptContinuationMessage,
  makeCharacterLookupKey,
  parseIntOr,
  translateCatalogName,
} from "./debug-agent/helpers.js";
import { registerDebugAgentAssetRoutes } from "./debug-agent/assets.js";
import { toolAnalyticsRoutes } from "./debug-agent/analytics.js";
import { DEBUG_HTML } from "./debug-agent/page.js";
import type { GameTimeSnapshot } from "../godot-link/protocol.js";

const DEFAULT_MESSAGE_LIMIT = 500;
const MAX_MESSAGE_LIMIT = 5000;
const DEFAULT_TURNS_LIMIT = 1000;
const MAX_TURNS_LIMIT = 10000;

interface TurnSummary {
  sessionId: string;
  characterId: string;
  townId: string;
  agentKind: string;
  turnReason: string | null;
  isInterruptContinuation: boolean;
  startSeq: number;
  endSeq: number;
  startedAt: string;
  endedAt: string;
  startGameTime: GameTimeSnapshot | null;
  endGameTime: GameTimeSnapshot | null;
  msgCount: number;
  llmCallCount: number;
  toolCallCount: number;
  toolCallSummary: ToolCallSummary[];
  hasError: boolean;
  totalTokens: number | null;
  tokenUsage: TokenUsageSummary | null;
  totalCostUsd: number | null;
  costUsage: CostUsageSummary | null;
  npcCumulativeTokens: number | null;
  npcCumulativeTokensAtTurn: number | null;
  npcCumulativeCostUsd: number | null;
  npcCumulativeCostUsdAtTurn: number | null;
  npcTurnIndex: number;
  npcTurnCount: number;
}

interface ToolCallSummary {
  name: string;
  count: number;
  errorCount: number;
}

interface TokenUsageSummary {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  totalTokens: number;
}

interface CostUsageSummary {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  total: number;
}

interface NpcTokenStats {
  turnCount: number;
  llmCallCount: number;
  toolCallCount: number;
  totalTokens: number;
  hasTokens: boolean;
  totalCostUsd: number;
  hasCost: boolean;
}

function buildNpcTokenStats(turns: TurnSummary[]): Map<string, NpcTokenStats> {
  const statsByCharacter = new Map<string, NpcTokenStats>();
  const chronologicalTurns = turns.slice().sort(compareTurnChronological);

  for (const turn of chronologicalTurns) {
    const key = makeCharacterStatsKey(turn.townId, turn.characterId);
    let stats = statsByCharacter.get(key);
    if (!stats) {
      stats = {
        turnCount: 0,
        llmCallCount: 0,
        toolCallCount: 0,
        totalTokens: 0,
        hasTokens: false,
        totalCostUsd: 0,
        hasCost: false,
      };
      statsByCharacter.set(key, stats);
    }

    stats.turnCount += 1;
    stats.llmCallCount += turn.llmCallCount;
    stats.toolCallCount += turn.toolCallCount;
    turn.npcTurnIndex = stats.turnCount;

    if (turn.totalTokens != null) {
      stats.totalTokens += turn.totalTokens;
      stats.hasTokens = true;
    }
    turn.npcCumulativeTokensAtTurn = stats.hasTokens ? stats.totalTokens : null;

    if (turn.totalCostUsd != null) {
      stats.totalCostUsd += turn.totalCostUsd;
      stats.hasCost = true;
    }
    turn.npcCumulativeCostUsdAtTurn = stats.hasCost ? stats.totalCostUsd : null;
  }

  for (const turn of turns) {
    const stats = statsByCharacter.get(makeCharacterStatsKey(turn.townId, turn.characterId));
    turn.npcTurnCount = stats?.turnCount ?? 0;
    turn.npcCumulativeTokens = stats?.hasTokens ? stats.totalTokens : null;
    turn.npcCumulativeCostUsd = stats?.hasCost ? stats.totalCostUsd : null;
  }

  return statsByCharacter;
}

function compareTurnChronological(a: TurnSummary, b: TurnSummary): number {
  const aMs = Date.parse(a.startedAt);
  const bMs = Date.parse(b.startedAt);
  if (Number.isFinite(aMs) && Number.isFinite(bMs) && aMs !== bMs) {
    return aMs - bMs;
  }
  const timeCompare = a.startedAt.localeCompare(b.startedAt);
  if (timeCompare !== 0) return timeCompare;
  const sessionCompare = a.sessionId.localeCompare(b.sessionId);
  if (sessionCompare !== 0) return sessionCompare;
  return a.startSeq - b.startSeq;
}

function makeCharacterStatsKey(townId: string, characterId: string): string {
  return `${townId}\u0000${characterId}`;
}

function addTokenUsage(current: TokenUsageSummary | null, next: TokenUsageSummary): TokenUsageSummary {
  return {
    input: (current?.input ?? 0) + next.input,
    output: (current?.output ?? 0) + next.output,
    cacheRead: (current?.cacheRead ?? 0) + next.cacheRead,
    cacheWrite: (current?.cacheWrite ?? 0) + next.cacheWrite,
    totalTokens: (current?.totalTokens ?? 0) + next.totalTokens,
  };
}

function addCostUsage(current: CostUsageSummary | null, next: CostUsageSummary): CostUsageSummary {
  return {
    input: (current?.input ?? 0) + next.input,
    output: (current?.output ?? 0) + next.output,
    cacheRead: (current?.cacheRead ?? 0) + next.cacheRead,
    cacheWrite: (current?.cacheWrite ?? 0) + next.cacheWrite,
    total: (current?.total ?? 0) + next.total,
  };
}

function addToolCallSummary(turn: TurnSummary, message: Record<string, unknown>): void {
  const name = toolResultName(message);
  let summary = turn.toolCallSummary.find((item) => item.name === name);
  if (!summary) {
    summary = { name, count: 0, errorCount: 0 };
    turn.toolCallSummary.push(summary);
  }
  summary.count += 1;
  if (message.isError) summary.errorCount += 1;
}

function toolResultName(message: Record<string, unknown>): string {
  const name = stringValue(message.toolName) ?? stringValue(message.name);
  return name && name.trim() ? name.trim() : "unknown";
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function tokenUsageSummary(value: unknown): TokenUsageSummary | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const usage = value as Record<string, unknown>;
  const input = firstTokenNumber(usage, ["input", "inputTokens", "promptTokens", "prompt_tokens", "input_tokens"]);
  const output = firstTokenNumber(usage, ["output", "outputTokens", "completionTokens", "completion_tokens", "output_tokens"]);
  const cacheRead = firstTokenNumber(usage, ["cacheRead", "cache_read", "cacheReadTokens", "cache_read_tokens"]);
  const cacheWrite = firstTokenNumber(usage, ["cacheWrite", "cache_write", "cacheWriteTokens", "cache_write_tokens"]);
  const totalTokens = firstTokenNumber(usage, ["totalTokens", "total_tokens", "total"]);

  if (input == null && output == null && cacheRead == null && cacheWrite == null && totalTokens == null) {
    return null;
  }

  const computedTotal = (input ?? 0) + (output ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0);
  return {
    input: input ?? 0,
    output: output ?? 0,
    cacheRead: cacheRead ?? 0,
    cacheWrite: cacheWrite ?? 0,
    totalTokens: totalTokens ?? computedTotal,
  };
}

function firstTokenNumber(record: Record<string, unknown>, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value)) {
      return Math.max(0, Math.round(value));
    }
  }
  return undefined;
}

function costUsageSummary(value: unknown): CostUsageSummary | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const usage = value as Record<string, unknown>;
  const costValue = usage.cost;
  if (typeof costValue === "number" && Number.isFinite(costValue)) {
    return {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      total: Math.max(0, costValue),
    };
  }

  if (!costValue || typeof costValue !== "object" || Array.isArray(costValue)) {
    const total = firstCostNumber(usage, ["totalCost", "total_cost", "costUsd", "cost_usd"]);
    return total == null
      ? null
      : {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          total,
        };
  }

  const cost = costValue as Record<string, unknown>;
  const input = firstCostNumber(cost, ["input", "inputCost", "input_cost"]);
  const output = firstCostNumber(cost, ["output", "outputCost", "output_cost"]);
  const cacheRead = firstCostNumber(cost, ["cacheRead", "cache_read", "cacheReadCost", "cache_read_cost"]);
  const cacheWrite = firstCostNumber(cost, ["cacheWrite", "cache_write", "cacheWriteCost", "cache_write_cost"]);
  const total = firstCostNumber(cost, ["total", "totalCost", "total_cost", "costUsd", "cost_usd"]);

  if (input == null && output == null && cacheRead == null && cacheWrite == null && total == null) {
    return null;
  }

  const computedTotal = (input ?? 0) + (output ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0);
  return {
    input: input ?? 0,
    output: output ?? 0,
    cacheRead: cacheRead ?? 0,
    cacheWrite: cacheWrite ?? 0,
    total: total ?? computedTotal,
  };
}

function firstCostNumber(record: Record<string, unknown>, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value)) {
      return Math.max(0, value);
    }
  }
  return undefined;
}

export const debugAgentRoutes: FastifyPluginAsync = async (app) => {
  registerDebugAgentAssetRoutes(app);
  await app.register(toolAnalyticsRoutes);

  app.get("/debug", async (_request, reply) => {
    reply.type("text/html; charset=utf-8");
    return DEBUG_HTML;
  });

  app.get("/debug/api/agent-run-filter", async () => {
    const filter = await getDebugAgentRunFilter(app.redis);
    return {
      configured: filter.configured,
      characterIds: Array.from(filter.enabledCharacterIds).sort(),
    };
  });

  app.post<{ Body: { characterIds?: unknown } }>(
    "/debug/api/agent-run-filter",
    async (request) => {
      const rawIds = Array.isArray(request.body?.characterIds) ? request.body.characterIds : [];
      const characterIds = rawIds.filter((id): id is string => typeof id === "string");
      const saved = await setDebugAgentRunFilter(app.redis, characterIds);
      return { ok: true, configured: true, characterIds: saved };
    },
  );

  app.get<{ Querystring: { townId?: string } }>(
    "/debug/api/sessions",
    async (request) => {
      const townId = request.query.townId;
      const rows = townId
        ? app.db
            .prepare(
              `SELECT * FROM agent_sessions WHERE townId = ? ORDER BY updatedAt DESC`,
            )
            .all(townId)
        : app.db
            .prepare(`SELECT * FROM agent_sessions ORDER BY updatedAt DESC`)
            .all();
      return {
        sessions: (rows as Record<string, unknown>[])
          .map(rowToAgentSession)
          .map((session) => ({
            id: session.id,
            townId: session.townId,
            characterId: session.characterId,
            agentKind: session.agentKind,
            updatedAt: session.updatedAt,
            createdAt: session.createdAt,
            messageSeq: session.messageSeq,
            lastUsageTokenCount: session.lastUsageTokenCount,
            lastUsageCostUsd: session.lastUsageCostUsd,
            lastUsageUpdatedAt: session.lastUsageUpdatedAt,
          })),
      };
    },
  );

  app.get<{
    Querystring: {
      townId?: string;
      characterIds?: string;
      groupIds?: string;
      since?: string;
      until?: string;
      limit?: string;
    };
  }>("/debug/api/turns", async (request) => {
    const townId = request.query.townId?.trim() || undefined;
    const characterIds = (request.query.characterIds || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    const groupIds = (request.query.groupIds || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    const since = request.query.since?.trim() || undefined;
    const until = request.query.until?.trim() || undefined;
    const limit = Math.min(
      MAX_TURNS_LIMIT,
      Math.max(1, parseIntOr(request.query.limit, DEFAULT_TURNS_LIMIT)),
    );

    const conditions: string[] = [];
    const params: unknown[] = [];
    if (townId) {
      conditions.push("townId = ?");
      params.push(townId);
    }
    if (characterIds.length > 0) {
      conditions.push(
        "asm.characterId IN (" + characterIds.map(() => "?").join(",") + ")",
      );
      params.push(...characterIds);
    }
    if (groupIds.length > 0) {
      conditions.push(
        "EXISTS (SELECT 1 FROM character_groups cg"
          + " WHERE cg.townId = asm.townId"
          + " AND cg.characterId = asm.characterId"
          + " AND cg.groupId IN (" + groupIds.map(() => "?").join(",") + "))",
      );
      params.push(...groupIds);
    }
    if (since) {
      conditions.push("asm.createdAt >= ?");
      params.push(since);
    }
    if (until) {
      conditions.push("asm.createdAt <= ?");
      params.push(until);
    }
    const where = conditions.length > 0 ? "WHERE " + conditions.join(" AND ") : "";

    const rows = app.db
      .prepare(
        `SELECT asm.id, asm.sessionId, asm.townId, asm.characterId, asm.agentKind, asm.seq, asm.role, asm.message, asm.createdAt, asm.gameTime, asm.turnReason
         FROM agent_session_messages asm
         ${where}
         ORDER BY asm.sessionId ASC, asm.seq ASC`,
      )
      .all(...params) as Record<string, unknown>[];

    const turns: TurnSummary[] = [];
    const openTurns = new Map<string, TurnSummary>();

    const closeTurn = (turn: TurnSummary) => {
      turns.push(turn);
    };

    for (const row of rows) {
      const sessionId = row.sessionId as string;
      const role = row.role as string;
      const seq = row.seq as number;
      const createdAt = row.createdAt as string;
      const gameTime = parseJsonColumn<GameTimeSnapshot>(row.gameTime) ?? null;

      let parsedMessage: Record<string, unknown> | null = null;
      const tryParse = () => {
        if (parsedMessage !== null) return parsedMessage;
        try {
          parsedMessage = JSON.parse(row.message as string) as Record<string, unknown>;
        } catch {
          parsedMessage = {};
        }
        return parsedMessage;
      };

      if (role === "user") {
        const existing = openTurns.get(sessionId);
        if (existing) closeTurn(existing);
        const parsed = tryParse();
        const fresh: TurnSummary = {
          sessionId,
          characterId: row.characterId as string,
          townId: row.townId as string,
          agentKind: row.agentKind as string,
          turnReason: (row.turnReason as string | null) ?? null,
          isInterruptContinuation: isInterruptContinuationMessage(parsed),
          startSeq: seq,
          endSeq: seq,
          startedAt: createdAt,
          endedAt: createdAt,
          startGameTime: gameTime,
          endGameTime: gameTime,
          msgCount: 1,
          llmCallCount: 0,
          toolCallCount: 0,
          toolCallSummary: [],
          hasError: false,
          totalTokens: null,
          tokenUsage: null,
          totalCostUsd: null,
          costUsage: null,
          npcCumulativeTokens: null,
          npcCumulativeTokensAtTurn: null,
          npcCumulativeCostUsd: null,
          npcCumulativeCostUsdAtTurn: null,
          npcTurnIndex: 0,
          npcTurnCount: 0,
        };
        openTurns.set(sessionId, fresh);
        continue;
      }

      const turn = openTurns.get(sessionId);
      if (!turn) continue;

      turn.endSeq = seq;
      turn.endedAt = createdAt;
      if (gameTime) turn.endGameTime = gameTime;
      turn.msgCount += 1;

      if (role === "assistant") {
        turn.llmCallCount += 1;
        const message = tryParse();
        if (message && typeof message === "object") {
          if (message.errorMessage) turn.hasError = true;
          const usage = tokenUsageSummary(message.usage);
          if (usage) {
            turn.tokenUsage = addTokenUsage(turn.tokenUsage, usage);
            turn.totalTokens = turn.tokenUsage.totalTokens;
          }
          const cost = costUsageSummary(message.usage);
          if (cost) {
            turn.costUsage = addCostUsage(turn.costUsage, cost);
            turn.totalCostUsd = turn.costUsage.total;
          }
        }
      } else if (role === "toolResult") {
        turn.toolCallCount += 1;
        const message = tryParse();
        addToolCallSummary(turn, message);
        if (message && message.isError) turn.hasError = true;
      }
    }
    for (const turn of openTurns.values()) closeTurn(turn);

    const tokenStatsByCharacter = buildNpcTokenStats(turns);

    turns.sort((a, b) => (a.startedAt < b.startedAt ? 1 : a.startedAt > b.startedAt ? -1 : 0));
    const trimmed = turns.slice(0, limit);

    const locale = getActiveLocale();
    const charRows = townId
      ? app.db
          .prepare(
            `SELECT characterId, townId, agentKind
             FROM (
               SELECT DISTINCT characterId, townId, agentKind
                FROM agent_sessions
                WHERE townId = ?
                UNION
                SELECT DISTINCT characterId, townId,
                  CASE WHEN characterId LIKE 'player_%' THEN 'player' ELSE 'npc' END AS agentKind
                FROM character_groups
                WHERE townId = ?
             )
             ORDER BY characterId ASC`,
          )
          .all(townId, townId) as Record<string, unknown>[]
      : app.db
          .prepare(
            `SELECT characterId, townId, agentKind
             FROM (
               SELECT DISTINCT characterId, townId, agentKind
                FROM agent_sessions
                UNION
                SELECT DISTINCT characterId, townId,
                  CASE WHEN characterId LIKE 'player_%' THEN 'player' ELSE 'npc' END AS agentKind
                FROM character_groups
             )
             ORDER BY characterId ASC`,
          )
          .all() as Record<string, unknown>[];
    const characterGroupRows = app.db
      .prepare(
        `SELECT townId, characterId, groupId
         FROM character_groups
         ${townId ? "WHERE townId = ?" : ""}
         ORDER BY characterId ASC, groupId ASC`,
      )
      .all(...(townId ? [townId] : [])) as Record<string, unknown>[];

    const groupsByCharacter = new Map<string, Array<{ groupId: string; displayName: string }>>();
    const groupsById = new Map<string, { groupId: string; displayName: string }>();
    for (const row of characterGroupRows) {
      const rowTownId = String(row.townId ?? "");
      const characterId = String(row.characterId ?? "");
      const groupId = String(row.groupId ?? "");
      if (!rowTownId || !characterId || !groupId) continue;
      const displayName = translateCatalogName("group", groupId, locale);
      if (!groupsById.has(groupId)) {
        groupsById.set(groupId, { groupId, displayName });
      }
      const key = makeCharacterLookupKey(rowTownId, characterId);
      const list = groupsByCharacter.get(key) ?? [];
      list.push({ groupId, displayName });
      groupsByCharacter.set(key, list);
    }

    return {
      turns: trimmed,
      characters: charRows.map((row) => {
        const rowTownId = row.townId as string;
        const characterId = row.characterId as string;
        const stats = tokenStatsByCharacter.get(makeCharacterStatsKey(rowTownId, characterId));
        return {
          characterId,
          townId: rowTownId,
          agentKind: row.agentKind as string,
          displayName: translateCatalogName("npc", characterId, locale),
          turnCount: stats?.turnCount ?? 0,
          llmCallCount: stats?.llmCallCount ?? 0,
          toolCallCount: stats?.toolCallCount ?? 0,
          totalTokens: stats?.hasTokens ? stats.totalTokens : null,
          totalCostUsd: stats?.hasCost ? stats.totalCostUsd : null,
          groups: groupsByCharacter.get(
            makeCharacterLookupKey(rowTownId, characterId),
          ) ?? [],
        };
      }),
      groups: Array.from(groupsById.values()).sort((a, b) => (
        a.displayName.localeCompare(b.displayName, locale)
      )),
      truncated: turns.length > trimmed.length,
    };
  });

  app.get<{ Params: { id: string } }>(
    "/debug/api/sessions/:id",
    async (request, reply) => {
      const row = app.db
        .prepare(`SELECT * FROM agent_sessions WHERE id = ?`)
        .get(request.params.id) as Record<string, unknown> | undefined;
      if (!row) {
        reply.code(404);
        return { error: "session not found" };
      }
      return { session: rowToAgentSession(row) };
    },
  );

  app.get<{ Params: { id: string } }>(
    "/debug/api/sessions/:id/prompt-memory",
    async (request, reply) => {
      const row = app.db
        .prepare(`SELECT * FROM agent_sessions WHERE id = ?`)
        .get(request.params.id) as Record<string, unknown> | undefined;
      if (!row) {
        reply.code(404);
        return { error: "session not found" };
      }

      const session = rowToAgentSession(row);
      // 历史架构在这里 pull 一份 live snapshot；manifest-based 路径下 backend 是被动的（无 pull
      // 通道）。debug context 改成基于已有 sqlite + null current 拼出来——current 字段会缺，
      // 但 memory / system prompt / 历史事件全可见，调试用足够。
      const contextBuilder = new TwoTrackAgentContextBuilder();
      const ctx = debugAgentRuntimeContext(app.db, session.townId, session.characterId);
      const current = await ctx.getCurrentContext();
      if (!current) {
        // 没有任何 cached manifest（worker 进程没在跑 / 角色没活过） → 返回 stub context。
        // 之前会 503，但这里 prompt-memory 只看 memory + system prompt，没 current 也凑合。
        reply.code(503);
        return { error: "no cached perception manifest for character" };
      }
      const context = await contextBuilder.build({
        ctx,
        current,
      });
      // 与 worker.ts 起 host 时同一份路由一致：按 character 真实路由的 runtimeName 读 memory，
      // 否则会读到错的命名空间显示成空。
      const runtimeName = debugAgentRouter().runtimeFor(session.characterId);
      const storedMemoryRows = app.db
        .prepare(
          `SELECT key, value FROM runtime_storage
           WHERE runtimeName = ? AND townId = ? AND characterId = ? AND key LIKE 'memory:%'
           ORDER BY updatedAt DESC, key DESC`,
        )
        .all(runtimeName, session.townId, session.characterId) as Record<string, unknown>[];

      return {
        promptMemory: {
          baseSystemPrompt: buildBaseSystemPrompt(),
          effectiveSystemPrompt: buildEffectiveSystemPrompt(context),
          promptSelectedMemories: context.memory.all,
          storedMemories: storedMemoryRows.map((row) => parseJsonColumn(row.value) ?? {}),
          renderedStableContext: renderAgentSystemContext(context),
        },
      };
    },
  );

  // working_memory + 最新 thinking_turn 给 debug 用：直接读 sqlite，不依赖 live manifest，
  // /prompt-memory 路径有 manifest 时才返回 → 老 session 看不见，这里补一份纯 DB 视图。
  app.get<{ Params: { id: string } }>(
    "/debug/api/sessions/:id/memory",
    async (request, reply) => {
      const row = app.db
        .prepare(`SELECT * FROM agent_sessions WHERE id = ?`)
        .get(request.params.id) as Record<string, unknown> | undefined;
      if (!row) {
        reply.code(404);
        return { error: "session not found" };
      }
      const session = rowToAgentSession(row);
      const runtimeName = debugAgentRouter().runtimeFor(session.characterId);

      const workingRow = app.db
        .prepare(
          `SELECT value, updatedAt FROM runtime_storage
           WHERE runtimeName = ? AND townId = ? AND characterId = ? AND key = 'working_memory'`,
        )
        .get(runtimeName, session.townId, session.characterId) as
          | { value?: string; updatedAt?: string }
          | undefined;

      const latestThinkingRow = app.db
        .prepare(
          `SELECT * FROM thinking_turns
           WHERE townId = ? AND characterId = ?
           ORDER BY startedAt DESC
           LIMIT 1`,
        )
        .get(session.townId, session.characterId) as Record<string, unknown> | undefined;

      const workingMemory = workingRow?.value ? parseJsonColumn<Record<string, unknown>>(workingRow.value) : undefined;
      const latestThinking = latestThinkingRow ? rowToThinkingTurn(latestThinkingRow) : null;

      return {
        workingMemory: workingMemory
          ? {
              content: typeof workingMemory.content === "string" ? workingMemory.content : "",
              updatedAt: typeof workingMemory.updatedAt === "string"
                ? workingMemory.updatedAt
                : (workingRow?.updatedAt ?? null),
              triggerReason: typeof workingMemory.triggerReason === "string" ? workingMemory.triggerReason : null,
              gameTime: (workingMemory.gameTime as GameTimeSnapshot | undefined) ?? null,
            }
          : null,
        latestThinkingTurn: latestThinking
          ? {
              id: latestThinking.id,
              triggerReason: latestThinking.triggerReason,
              intent: latestThinking.intent ?? null,
              startedAt: latestThinking.startedAt,
              endedAt: latestThinking.endedAt,
              startGameTime: latestThinking.startGameTime ?? null,
              endGameTime: latestThinking.endGameTime ?? null,
              writtenContent: latestThinking.writtenContent ?? null,
              totalTokens: latestThinking.totalTokens ?? null,
              costUsd: latestThinking.costUsd ?? null,
              modelId: latestThinking.modelId ?? null,
              error: latestThinking.error ?? null,
            }
          : null,
        runtimeName,
      };
    },
  );

  app.get<{
    Params: { id: string };
    Querystring: { limit?: string; beforeSeq?: string; fromSeq?: string };
  }>("/debug/api/sessions/:id/messages", async (request, reply) => {
    const sessionRow = app.db
      .prepare(`SELECT id FROM agent_sessions WHERE id = ?`)
      .get(request.params.id);
    if (!sessionRow) {
      reply.code(404);
      return { error: "session not found" };
    }

    const requestedLimit = parseIntOr(request.query.limit, DEFAULT_MESSAGE_LIMIT);
    const limit = Math.min(MAX_MESSAGE_LIMIT, Math.max(1, requestedLimit));
    const beforeSeq = parseIntOr(request.query.beforeSeq, Number.MAX_SAFE_INTEGER);
    const fromSeq = parseIntOr(request.query.fromSeq, Number.MIN_SAFE_INTEGER);

    const rows = app.db
      .prepare(
        `SELECT * FROM agent_session_messages
         WHERE sessionId = ? AND seq < ? AND seq >= ?
         ORDER BY seq DESC
         LIMIT ?`,
      )
      .all(request.params.id, beforeSeq, fromSeq, limit) as Record<string, unknown>[];

    const messages = rows.map(rowToAgentSessionMessage).reverse();
    const minSeq = messages.length > 0 ? messages[0].seq : undefined;

    return {
      messages,
      minSeq,
      hasMore: rows.length === limit,
    };
  });

  app.post<{ Params: { id: string } }>(
    "/debug/api/sessions/:id/delete",
    async (request, reply) => {
      const id = request.params.id;
      const tx = app.db.transaction(() => {
        const messages = app.db
          .prepare(`DELETE FROM agent_session_messages WHERE sessionId = ?`)
          .run(id);
        const session = app.db
          .prepare(`DELETE FROM agent_sessions WHERE id = ?`)
          .run(id);
        return {
          deletedMessages: messages.changes,
          deletedSession: session.changes,
        };
      });
      const result = tx();
      if (result.deletedSession === 0) {
        reply.code(404);
        return { error: "session not found", ...result };
      }
      app.log.warn({ sessionId: id, ...result }, "debug deleted agent session");
      return { ok: true, ...result };
    },
  );

  app.post("/debug/api/agent-data/clear", async () => {
    const tx = app.db.transaction(() => {
      const messages = app.db.prepare(`DELETE FROM agent_session_messages`).run();
      const sessions = app.db.prepare(`DELETE FROM agent_sessions`).run();
      const memories = app.db.prepare(`DELETE FROM runtime_storage WHERE key LIKE 'memory:%'`).run();
      const thinking = app.db.prepare(`DELETE FROM thinking_turns`).run();
      return {
        deletedMessages: messages.changes,
        deletedSessions: sessions.changes,
        deletedMemories: memories.changes,
        deletedThinkingTurns: thinking.changes,
      };
    });
    const result = tx();
    app.log.warn(result, "debug cleared all agent data");
    return { ok: true, ...result };
  });

  app.get<{
    Querystring: {
      townId?: string;
      characterIds?: string;
      groupIds?: string;
      since?: string;
      until?: string;
      limit?: string;
    };
  }>("/debug/api/thinking-turns", async (request) => {
    const townId = request.query.townId?.trim() || undefined;
    const characterIds = (request.query.characterIds || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    const groupIds = (request.query.groupIds || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    const since = request.query.since?.trim() || undefined;
    const until = request.query.until?.trim() || undefined;
    const limit = Math.min(
      MAX_TURNS_LIMIT,
      Math.max(1, parseIntOr(request.query.limit, DEFAULT_TURNS_LIMIT)),
    );

    const conditions: string[] = [];
    const params: unknown[] = [];
    if (townId) {
      conditions.push("tt.townId = ?");
      params.push(townId);
    }
    if (characterIds.length > 0) {
      conditions.push(
        "tt.characterId IN (" + characterIds.map(() => "?").join(",") + ")",
      );
      params.push(...characterIds);
    }
    if (groupIds.length > 0) {
      conditions.push(
        "EXISTS (SELECT 1 FROM character_groups cg"
          + " WHERE cg.townId = tt.townId"
          + " AND cg.characterId = tt.characterId"
          + " AND cg.groupId IN (" + groupIds.map(() => "?").join(",") + "))",
      );
      params.push(...groupIds);
    }
    if (since) {
      conditions.push("tt.startedAt >= ?");
      params.push(since);
    }
    if (until) {
      conditions.push("tt.startedAt <= ?");
      params.push(until);
    }
    const where = conditions.length > 0 ? "WHERE " + conditions.join(" AND ") : "";

    // 列表请求只回 summary 字段（system/userPrompt + assistantMessage 体积大，详情才查）。
    const rows = app.db
      .prepare(
        `SELECT tt.id, tt.townId, tt.characterId, tt.triggerReason, tt.intent,
                tt.startedAt, tt.endedAt, tt.durationMs,
                tt.startGameTime, tt.endGameTime, tt.modelId,
                tt.totalTokens, tt.costUsd,
                tt.error,
                (tt.writtenContent IS NOT NULL) AS hasWritten
         FROM thinking_turns tt
         ${where}
         ORDER BY tt.startedAt DESC
         LIMIT ?`,
      )
      .all(...params, limit) as Record<string, unknown>[];

    return {
      thinkingTurns: rows.map((row) => ({
        id: row.id as string,
        townId: row.townId as string,
        characterId: row.characterId as string,
        triggerReason: row.triggerReason as string,
        intent: (row.intent as string | null) ?? undefined,
        startedAt: row.startedAt as string,
        endedAt: row.endedAt as string,
        durationMs: row.durationMs as number,
        startGameTime: parseJsonColumn<GameTimeSnapshot>(row.startGameTime) ?? null,
        endGameTime: parseJsonColumn<GameTimeSnapshot>(row.endGameTime) ?? null,
        modelId: (row.modelId as string | null) ?? undefined,
        totalTokens: row.totalTokens == null ? null : (row.totalTokens as number),
        costUsd: row.costUsd == null ? null : (row.costUsd as number),
        hasError: !!row.error,
        hasWritten: !!row.hasWritten,
      })),
      truncated: rows.length === limit,
    };
  });

  app.get<{ Params: { id: string } }>(
    "/debug/api/thinking-turns/:id",
    async (request, reply) => {
      const row = app.db
        .prepare("SELECT * FROM thinking_turns WHERE id = ?")
        .get(request.params.id) as Record<string, unknown> | undefined;
      if (!row) {
        reply.code(404);
        return { error: "thinking turn not found" };
      }
      return { thinkingTurn: rowToThinkingTurn(row) };
    },
  );
};

// Debug 用懒构造 router 单例：避免每次请求都解析 npcs.json。
// npcs.json 更新后需重启 backend 才能反映——debug 路径不参与 hot-reload，可接受。
let _debugAgentRouter: AgentRuntimeRouter | undefined;
function debugAgentRouter(): AgentRuntimeRouter {
  if (!_debugAgentRouter) {
    _debugAgentRouter = loadNpcRuntimeRouter();
  }
  return _debugAgentRouter;
}

function debugAgentRuntimeContext(db: AppDb, townId: string, characterId: string): AgentRuntimeContext {
  return {
    townId,
    characterId,
    gameTools: () => [],
    getManifest: async () => null,
    getCurrentContext: async () => null,
    recentEvents: () => [],
    recentEventRecords: (opts) => Promise.resolve(recentWorldEventRecords(db, townId, opts)),
    characterGroups: () => Promise.resolve(getCharacterGroups(db, townId, characterId)),
    resolveCharacterName: (id) => id,
    resolveItemName: (id) => id,
    resolveLocationName: (id) => id,
    storage: () => new SqliteRuntimeStorage(db, { runtimeName: debugAgentRouter().runtimeFor(characterId), townId, characterId }),
    actions: () => unavailableDebugActionHost(),
    sessions: () => new SqliteAgentSessionStore(db),
    thinkingTurns: () => ({
      record: async () => {
        throw new Error("debug prompt context cannot record thinking turns");
      },
    }),
    setThinkingStatus: async () => undefined,
  };
}

function unavailableDebugActionHost(): AgentActionHost {
  const unavailable = async () => {
    throw new Error("debug prompt context cannot execute actions");
  };
  return {
    submit: unavailable,
    get: unavailable,
    recentForCharacter: unavailable,
    cancel: unavailable,
    waitForTerminal: unavailable,
    emitWorldEvent: unavailable,
  };
}
