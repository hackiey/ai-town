import type { AppDb } from "../../db/sqlite.js";
import type { TradeLine, TradeOfferView } from "./types.js";

// trade_offers: backend 已有 pending_trade_snapshots_for_character 的 Godot-side equivalent;
// 这里走纯 SELECT，给 backend 自己组装时用，避免依赖 Godot 端 _trade_row_to_snapshot。

const SELECT_PENDING_FOR_CHARACTER = `
  SELECT id, fromCharacterId, toCharacterId, offerJson, requestJson,
         shelfListingIdsJson, requestedShelfItemsJson, status,
         createdAt, updatedAt, respondedAt
  FROM trade_offers
  WHERE townId = ? AND status = 'pending'
    AND (fromCharacterId = ? OR toCharacterId = ?)
  ORDER BY createdAt DESC
`;

export function getPendingTradesFor(db: AppDb, townId: string, characterId: string): TradeOfferView[] {
  const rows = safeAll(db, SELECT_PENDING_FOR_CHARACTER, [townId, characterId, characterId]);
  return rows.map((r) => rowToTradeView(r as Record<string, unknown>));
}

function rowToTradeView(r: Record<string, unknown>): TradeOfferView {
  return {
    tradeId: String(r.id ?? ""),
    fromCharacterId: String(r.fromCharacterId ?? ""),
    toCharacterId: String(r.toCharacterId ?? ""),
    offer: parseTradeLineArray(r.offerJson),
    request: parseTradeLineArray(r.requestJson),
    shelfListingIds: parseJsonStringArray(r.shelfListingIdsJson),
    requestedShelfItems: parseJsonArray(r.requestedShelfItemsJson),
    status: String(r.status ?? "pending"),
    createdAt: String(r.createdAt ?? ""),
    updatedAt: String(r.updatedAt ?? ""),
    respondedAt: r.respondedAt == null || r.respondedAt === "" ? undefined : String(r.respondedAt),
  };
}

function parseJsonArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (typeof value !== "string" || value.length === 0) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

// 老数据兼容：旧版 offerJson 是 string[]（"slug xN"），新版是 {item, count}[]。
// 老条目无法可靠 reparse（数量分隔符不唯一），直接丢弃。
// silver_coin / gold_coin 的 count 允许小数（精度 0.01），所以用 Number() 而非 parseInt。
function parseTradeLineArray(value: unknown): TradeLine[] {
  const out: TradeLine[] = [];
  for (const entry of parseJsonArray(value)) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    const item = typeof row.item === "string" ? row.item.trim() : "";
    const count = typeof row.count === "number" ? row.count : Number(row.count ?? Number.NaN);
    if (!item || !Number.isFinite(count) || count <= 0) continue;
    out.push({ item, count });
  }
  return out;
}

function parseJsonStringArray(value: unknown): string[] {
  return parseJsonArray(value).filter((e): e is string => typeof e === "string");
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
