import type { AppDb } from "../../db/sqlite.js";

// item_defs 表由 Godot Items.all_ids() boot 时 dump：
//   - kind 单列：常做 WHERE 过滤
//   - baseEffects：typed JSON dict（如 {"hunger":30,"stamina":5}），template-level
//     默认效果；instance 自己也可能写一份覆盖（reaction generate 时定）
//   - staticJson：Item template 渲染需要的模板级数值（capacity / serving_liters / max_durability /
//     max_stack 等）。schema 不固化，加字段不用改表。
// displayName 不在这里——source-of-truth 是 data/i18n/<locale>/items.json，
// 调用方走 DisplayNameResolver.item(id)。

export type ItemDefView = {
  itemDefId: string;
  kind: string;
  // 模板级"基础效果"dict，instance 没自己写时作 fallback；NULL = 无固定效果。
  baseEffects: Record<string, number> | null;
  // 模板级静态属性袋：capacity / serving_liters / max_durability / max_stack 等都塞这里。
  // schema 不固化，调用方按需 narrow。NULL = Godot 没 dump 静态信息。
  staticJson: Record<string, unknown> | null;
};

const SELECT_BY_IDS = `
  SELECT itemDefId, kind, baseEffects, staticJson
  FROM item_defs
  WHERE townId = ? AND itemDefId IN
`;

export function getItemDefsByIds(db: AppDb, townId: string, itemDefIds: string[]): Map<string, ItemDefView> {
  const out = new Map<string, ItemDefView>();
  const ids = [...new Set(itemDefIds.filter((s) => typeof s === "string" && s.length > 0))];
  if (ids.length === 0) return out;
  const placeholders = ids.map(() => "?").join(",");
  const rows = safeAll(db, `${SELECT_BY_IDS} (${placeholders})`, [townId, ...ids]);
  for (const raw of rows) {
    const row = raw as Record<string, unknown>;
    const id = String(row.itemDefId ?? "");
    if (!id) continue;
    out.set(id, parseItemDef(id, row));
  }
  return out;
}

function parseItemDef(id: string, row: Record<string, unknown>): ItemDefView {
  return {
    itemDefId: id,
    kind: String(row.kind ?? ""),
    baseEffects: parseJsonNumberRecord(row.baseEffects),
    staticJson: parseJsonObject(row.staticJson),
  };
}

function parseJsonObject(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "string" || value.length === 0) return null;
  try {
    const parsed = JSON.parse(value);
    // staticJson 应当永远是 Godot JSON.stringify 写的 object；损坏当 null 忽略，不抛
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function parseJsonNumberRecord(value: unknown): Record<string, number> | null {
  const obj = parseJsonObject(value);
  if (!obj) return null;
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === "number" && Number.isFinite(v)) out[k] = v;
  }
  return Object.keys(out).length > 0 ? out : null;
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
