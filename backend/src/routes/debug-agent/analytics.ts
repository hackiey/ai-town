import type { FastifyPluginAsync } from "fastify";
import { parseJsonColumn } from "../../db/sqlite.js";
import { getActiveLocale } from "../../i18n/index.js";
import type { GameTimeSnapshot } from "../../godot-link/protocol.js";
import { makeCharacterLookupKey, parseIntOr, translateCatalogName } from "./helpers.js";

const DEFAULT_LIMIT = 5000;
const MAX_LIMIT = 50000;
const ERROR_EXCERPT_LEN = 140;
const CALL_EXCERPT_LEN = 220;
const DEFAULT_CALL_PAGE_SIZE = 50;
const MAX_CALL_PAGE_SIZE = 200;
const TOP_ERROR_LIMIT = 50;

const TOOL_NAME_SQL = "COALESCE(NULLIF(TRIM(json_extract(asm.message, '$.toolName')), ''), NULLIF(TRIM(json_extract(asm.message, '$.name')), ''), 'unknown')";
const TOOL_FAILURE_SQL = "(json_extract(asm.message, '$.isError') = 1 OR json_extract(asm.message, '$.details.status') = 'failed')";

type Bucket = "hour" | "day";

interface ToolAggregate {
  totalCount: number;
  errorCount: number;
  uniqueCharacters: Set<string>;
}

interface ErrorAggregate {
  toolName: string;
  errorExcerpt: string;
  count: number;
  characters: Set<string>;
  lastSessionId: string;
  lastSeq: number;
  lastAt: string;
}

interface CharacterAggregate {
  characterId: string;
  townId: string;
  totalCalls: number;
  errorCalls: number;
  errorToolCounts: Map<string, number>;
}

interface BucketAggregate {
  bucketKey: string;
  gameDay: number | null;
  gameHour: number | null;
  isoStart: string | null;
  totalCalls: number;
  errorCalls: number;
}

function normalizeBucket(value: string | undefined): Bucket {
  return value === "day" ? "day" : "hour";
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function toolNameOf(message: Record<string, unknown>): string {
  const name = stringValue(message.toolName) ?? stringValue(message.name);
  return name && name.trim() ? name.trim() : "unknown";
}

function toolCallIdOf(message: Record<string, unknown>): string | null {
  return stringValue(message.toolCallId)
    ?? stringValue(message.tool_call_id)
    ?? stringValue(message.callId)
    ?? stringValue(message.call_id)
    ?? null;
}

function isToolResultFailure(message: Record<string, unknown> | null | undefined): boolean {
  if (!message) return false;
  if (message.isError) return true;
  const details = message.details;
  if (details && typeof details === "object") {
    return stringValue((details as Record<string, unknown>).status) === "failed";
  }
  return false;
}

function extractText(content: unknown): string {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const parts: string[] = [];
    for (const part of content) {
      if (typeof part === "string") {
        parts.push(part);
      } else if (part && typeof part === "object") {
        const obj = part as Record<string, unknown>;
        if (typeof obj.text === "string") parts.push(obj.text);
      }
    }
    return parts.join("\n");
  }
  if (typeof content === "object") {
    const obj = content as Record<string, unknown>;
    if (typeof obj.text === "string") return obj.text;
    try {
      return JSON.stringify(obj);
    } catch {
      return "";
    }
  }
  return String(content);
}

function normalizeExcerpt(text: string, limit = ERROR_EXCERPT_LEN): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  if (collapsed.length <= limit) return collapsed;
  return collapsed.slice(0, limit) + "…";
}

function gameTimeTotalMinutes(gameTime: GameTimeSnapshot | null | undefined): number | null {
  if (!gameTime) return null;
  if (typeof gameTime.totalGameMinutes === "number" && Number.isFinite(gameTime.totalGameMinutes)) {
    return gameTime.totalGameMinutes;
  }
  if (typeof gameTime.totalGameHours === "number" && Number.isFinite(gameTime.totalGameHours)) {
    const minute = typeof gameTime.minute === "number" ? gameTime.minute : 0;
    return gameTime.totalGameHours * 60 + minute;
  }
  if (typeof gameTime.day === "number") {
    const hour = typeof gameTime.hour === "number" ? gameTime.hour : 0;
    const minute = typeof gameTime.minute === "number" ? gameTime.minute : 0;
    return ((gameTime.day * 24) + hour) * 60 + minute;
  }
  return null;
}

interface ToolResultRow {
  sessionId: string;
  characterId: string;
  townId: string;
  seq: number;
  createdAt: string;
  message: string;
  gameTime: string | null;
}

interface ToolCallDetailRow extends ToolResultRow {
  totalCount?: number;
}

function parseToolResultMessage(raw: string): Record<string, unknown> {
  try {
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function buildBucketKey(
  bucket: Bucket,
  gameTime: GameTimeSnapshot | null,
  createdAt: string,
): { key: string; gameDay: number | null; gameHour: number | null; isoStart: string | null } {
  const totalMinutes = gameTimeTotalMinutes(gameTime);
  if (totalMinutes != null) {
    const day = Math.floor(totalMinutes / (24 * 60));
    if (bucket === "day") {
      return { key: "g:day:" + day, gameDay: day, gameHour: null, isoStart: null };
    }
    const hour = Math.floor(totalMinutes / 60);
    const hourOfDay = hour % 24;
    return { key: "g:hour:" + hour, gameDay: day, gameHour: hourOfDay, isoStart: null };
  }
  // Fallback：游戏时间缺失（早期 session）用真实时间桶
  const date = new Date(createdAt);
  if (!Number.isFinite(date.getTime())) {
    return { key: "r:unknown", gameDay: null, gameHour: null, isoStart: null };
  }
  date.setUTCMinutes(0, 0, 0);
  if (bucket === "day") date.setUTCHours(0);
  const iso = date.toISOString();
  return { key: "r:" + iso, gameDay: null, gameHour: null, isoStart: iso };
}

export const toolAnalyticsRoutes: FastifyPluginAsync = async (app) => {
  app.get<{
    Querystring: {
      townId?: string;
      characterIds?: string;
      groupIds?: string;
      since?: string;
      until?: string;
      limit?: string;
      bucket?: string;
    };
  }>("/debug/api/tool-analytics", async (request) => {
    const townId = request.query.townId?.trim() || undefined;
    const characterIds = (request.query.characterIds || "")
      .split(",").map((s) => s.trim()).filter(Boolean);
    const groupIds = (request.query.groupIds || "")
      .split(",").map((s) => s.trim()).filter(Boolean);
    const since = request.query.since?.trim() || undefined;
    const until = request.query.until?.trim() || undefined;
    const limit = Math.min(
      MAX_LIMIT,
      Math.max(1, parseIntOr(request.query.limit, DEFAULT_LIMIT)),
    );
    const bucket = normalizeBucket(request.query.bucket);

    const conditions: string[] = ["asm.role = 'toolResult'"];
    const params: unknown[] = [];
    if (townId) {
      conditions.push("asm.townId = ?");
      params.push(townId);
    }
    if (characterIds.length > 0) {
      conditions.push("asm.characterId IN (" + characterIds.map(() => "?").join(",") + ")");
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
    const where = "WHERE " + conditions.join(" AND ");

    const rows = app.db
      .prepare(
        `SELECT asm.sessionId, asm.characterId, asm.townId, asm.seq, asm.createdAt, asm.message, asm.gameTime
         FROM agent_session_messages asm
         ${where}
         ORDER BY asm.createdAt DESC
         LIMIT ?`,
      )
      .all(...params, limit) as ToolResultRow[];

    const perTool = new Map<string, ToolAggregate>();
    const perError = new Map<string, ErrorAggregate>();
    const perCharacter = new Map<string, CharacterAggregate>();
    const perBucket = new Map<string, BucketAggregate>();

    let totalCalls = 0;
    let totalErrors = 0;

    for (const row of rows) {
      const parsed = parseToolResultMessage(row.message);
      const toolName = toolNameOf(parsed);
      const isError = isToolResultFailure(parsed);

      totalCalls += 1;
      if (isError) totalErrors += 1;

      const charKey = makeCharacterLookupKey(row.townId, row.characterId);

      // perTool
      let toolAgg = perTool.get(toolName);
      if (!toolAgg) {
        toolAgg = { totalCount: 0, errorCount: 0, uniqueCharacters: new Set() };
        perTool.set(toolName, toolAgg);
      }
      toolAgg.totalCount += 1;
      if (isError) toolAgg.errorCount += 1;
      toolAgg.uniqueCharacters.add(charKey);

      // perCharacter
      let charAgg = perCharacter.get(charKey);
      if (!charAgg) {
        charAgg = {
          characterId: row.characterId,
          townId: row.townId,
          totalCalls: 0,
          errorCalls: 0,
          errorToolCounts: new Map(),
        };
        perCharacter.set(charKey, charAgg);
      }
      charAgg.totalCalls += 1;
      if (isError) {
        charAgg.errorCalls += 1;
        charAgg.errorToolCounts.set(toolName, (charAgg.errorToolCounts.get(toolName) ?? 0) + 1);
      }

      // perError（只对 isError）
      if (isError) {
        const text = extractText(parsed.content);
        const excerpt = normalizeExcerpt(text) || "(empty)";
        const errKey = toolName + " " + excerpt;
        let errAgg = perError.get(errKey);
        if (!errAgg) {
          errAgg = {
            toolName,
            errorExcerpt: excerpt,
            count: 0,
            characters: new Set(),
            lastSessionId: row.sessionId,
            lastSeq: row.seq,
            lastAt: row.createdAt,
          };
          perError.set(errKey, errAgg);
        }
        errAgg.count += 1;
        errAgg.characters.add(charKey);
        // rows 按 createdAt DESC，第一次见到就是最新（已经记录）
      }

      // bucket
      const gameTimeParsed = parseJsonColumn<GameTimeSnapshot>(row.gameTime) ?? null;
      const bucketInfo = buildBucketKey(bucket, gameTimeParsed, row.createdAt);
      let bucketAgg = perBucket.get(bucketInfo.key);
      if (!bucketAgg) {
        bucketAgg = {
          bucketKey: bucketInfo.key,
          gameDay: bucketInfo.gameDay,
          gameHour: bucketInfo.gameHour,
          isoStart: bucketInfo.isoStart,
          totalCalls: 0,
          errorCalls: 0,
        };
        perBucket.set(bucketInfo.key, bucketAgg);
      }
      bucketAgg.totalCalls += 1;
      if (isError) bucketAgg.errorCalls += 1;
    }

    const locale = getActiveLocale();

    const perToolOut = Array.from(perTool.entries())
      .map(([name, agg]) => ({
        name,
        totalCount: agg.totalCount,
        errorCount: agg.errorCount,
        errorRate: agg.totalCount > 0 ? agg.errorCount / agg.totalCount : 0,
        uniqueCharacters: agg.uniqueCharacters.size,
      }))
      .sort((a, b) => b.totalCount - a.totalCount);

    const perErrorOut = Array.from(perError.values())
      .sort((a, b) => b.count - a.count)
      .slice(0, TOP_ERROR_LIMIT)
      .map((agg) => ({
        toolName: agg.toolName,
        errorExcerpt: agg.errorExcerpt,
        count: agg.count,
        uniqueCharacters: agg.characters.size,
        lastSessionId: agg.lastSessionId,
        lastSeq: agg.lastSeq,
        lastAt: agg.lastAt,
      }));

    const perCharacterOut = Array.from(perCharacter.values())
      .map((agg) => {
        let topErrorTool: string | null = null;
        let topErrorCount = 0;
        for (const [name, count] of agg.errorToolCounts) {
          if (count > topErrorCount) {
            topErrorCount = count;
            topErrorTool = name;
          }
        }
        return {
          characterId: agg.characterId,
          townId: agg.townId,
          displayName: translateCatalogName("npc", agg.characterId, locale),
          totalCalls: agg.totalCalls,
          errorCalls: agg.errorCalls,
          errorRate: agg.totalCalls > 0 ? agg.errorCalls / agg.totalCalls : 0,
          topErrorTool,
          topErrorToolCount: topErrorCount,
        };
      })
      .sort((a, b) => b.totalCalls - a.totalCalls);

    const timeBuckets = Array.from(perBucket.values())
      .sort((a, b) => {
        // 游戏时间桶按 gameDay/gameHour，真实时间桶按 isoStart
        const aKey = a.gameDay != null
          ? a.gameDay * 24 + (a.gameHour ?? 0)
          : a.isoStart ? Date.parse(a.isoStart) / 1000 : Number.NEGATIVE_INFINITY;
        const bKey = b.gameDay != null
          ? b.gameDay * 24 + (b.gameHour ?? 0)
          : b.isoStart ? Date.parse(b.isoStart) / 1000 : Number.NEGATIVE_INFINITY;
        return aKey - bKey;
      });

    return {
      bucket,
      totals: {
        totalCalls,
        totalErrors,
        errorRate: totalCalls > 0 ? totalErrors / totalCalls : 0,
        distinctTools: perTool.size,
        distinctCharacters: perCharacter.size,
      },
      perTool: perToolOut,
      perToolErrors: perErrorOut,
      perCharacter: perCharacterOut,
      timeBuckets,
      truncated: rows.length === limit,
      sampledRows: rows.length,
    };
  });

  app.get<{
    Querystring: {
      townId?: string;
      characterIds?: string;
      groupIds?: string;
      since?: string;
      until?: string;
      tool?: string;
      status?: string;
      characterId?: string;
      page?: string;
      pageSize?: string;
    };
  }>("/debug/api/tool-analytics/calls", async (request, reply) => {
    const tool = request.query.tool?.trim();
    if (!tool) {
      reply.code(400);
      return { error: "tool is required" };
    }

    const townId = request.query.townId?.trim() || undefined;
    const characterIds = (request.query.characterIds || "")
      .split(",").map((s) => s.trim()).filter(Boolean);
    const groupIds = (request.query.groupIds || "")
      .split(",").map((s) => s.trim()).filter(Boolean);
    const since = request.query.since?.trim() || undefined;
    const until = request.query.until?.trim() || undefined;
    const status = request.query.status === "failed" || request.query.status === "success"
      ? request.query.status
      : "all";
    const characterId = request.query.characterId?.trim() || undefined;
    const page = Math.max(1, parseIntOr(request.query.page, 1));
    const pageSize = Math.min(
      MAX_CALL_PAGE_SIZE,
      Math.max(1, parseIntOr(request.query.pageSize, DEFAULT_CALL_PAGE_SIZE)),
    );
    const offset = (page - 1) * pageSize;

    const conditions: string[] = ["asm.role = 'toolResult'", `${TOOL_NAME_SQL} = ?`];
    const params: unknown[] = [tool];
    if (townId) {
      conditions.push("asm.townId = ?");
      params.push(townId);
    }
    if (characterIds.length > 0) {
      conditions.push("asm.characterId IN (" + characterIds.map(() => "?").join(",") + ")");
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
    if (status === "failed") {
      conditions.push(TOOL_FAILURE_SQL);
    } else if (status === "success") {
      conditions.push(`NOT ${TOOL_FAILURE_SQL}`);
    }

    const characterConditions = conditions.slice();
    const characterParams = params.slice();

    if (characterId) {
      conditions.push("asm.characterId = ?");
      params.push(characterId);
    }

    const where = "WHERE " + conditions.join(" AND ");
    const totalRow = app.db
      .prepare(`SELECT COUNT(*) AS total FROM agent_session_messages asm ${where}`)
      .get(...params) as { total?: number } | undefined;
    const total = Number(totalRow?.total ?? 0);

    const rows = app.db
      .prepare(
        `SELECT asm.sessionId, asm.characterId, asm.townId, asm.seq, asm.createdAt, asm.message, asm.gameTime
         FROM agent_session_messages asm
         ${where}
         ORDER BY asm.createdAt DESC, asm.sessionId DESC, asm.seq DESC
         LIMIT ? OFFSET ?`,
      )
      .all(...params, pageSize, offset) as ToolCallDetailRow[];

    const characterWhere = "WHERE " + characterConditions.join(" AND ");
    const characterRows = app.db
      .prepare(
        `SELECT asm.townId, asm.characterId,
                COUNT(*) AS totalCalls,
                SUM(CASE WHEN ${TOOL_FAILURE_SQL} THEN 1 ELSE 0 END) AS errorCalls
         FROM agent_session_messages asm
         ${characterWhere}
         GROUP BY asm.townId, asm.characterId
         ORDER BY totalCalls DESC, asm.characterId ASC
         LIMIT 500`,
      )
      .all(...characterParams) as Array<{
        townId: string;
        characterId: string;
        totalCalls: number;
        errorCalls: number | null;
      }>;

    const locale = getActiveLocale();
    return {
      tool,
      status,
      characterId: characterId ?? null,
      page,
      pageSize,
      total,
      hasPrev: page > 1,
      hasNext: offset + rows.length < total,
      characters: characterRows.map((row) => ({
        townId: row.townId,
        characterId: row.characterId,
        displayName: translateCatalogName("npc", row.characterId, locale),
        totalCalls: row.totalCalls,
        errorCalls: row.errorCalls ?? 0,
      })),
      calls: rows.map((row) => {
        const parsed = parseToolResultMessage(row.message);
        const details = parsed.details && typeof parsed.details === "object"
          ? parsed.details as Record<string, unknown>
          : null;
        const text = extractText(parsed.content);
        const fallbackText = parsed.content !== undefined ? safeJsonText(parsed.content) : "";
        const failed = isToolResultFailure(parsed);
        return {
          sessionId: row.sessionId,
          characterId: row.characterId,
          townId: row.townId,
          displayName: translateCatalogName("npc", row.characterId, locale),
          seq: row.seq,
          createdAt: row.createdAt,
          gameTime: parseJsonColumn<GameTimeSnapshot>(row.gameTime) ?? null,
          toolName: toolNameOf(parsed),
          toolCallId: toolCallIdOf(parsed),
          failed,
          status: stringValue(details?.status) ?? (failed ? "failed" : "ok"),
          excerpt: normalizeExcerpt(text || fallbackText, CALL_EXCERPT_LEN) || "(empty)",
        };
      }),
    };
  });
};

function safeJsonText(value: unknown): string {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}
