import type { AppDb } from "../../db/sqlite.js";
import type { InventoryItemRow, ItemInstanceAspects } from "./types.js";

// item_instances 已切 typed columns（Godot src/autoload/db.gd 是 schema owner）。
// 这里只 SELECT，需要的列逐个列出；JSON 列（tags / materials / physicsProps /
// baseEffects / displayedEffects）由 parseJsonObject / parseJsonArray 安全解析，
// 空字符串/损坏全部退化为 null（aspect 列）或空容器（必填列）。
const SELECT_BY_OWNER = `
  SELECT slotIndex, itemDefId, stackCount, quality,
         shapeType, tags, materials, physicsProps,
         containerAmount, containerContent,
         freshnessTier, freshnessAgeHours,
         durability,
         baseEffects, displayedEffects,
         listingPriceCenti
  FROM item_instances
  WHERE townId = ? AND ownerKind = ? AND ownerId = ?
  ORDER BY slotIndex ASC
`;

export function getInventoryForCharacter(db: AppDb, townId: string, characterId: string): InventoryItemRow[] {
  return selectInventory(db, townId, "character", characterId);
}

export function getInventoryForContainer(db: AppDb, townId: string, containerId: string): InventoryItemRow[] {
  return selectInventory(db, townId, "container", containerId);
}

function selectInventory(db: AppDb, townId: string, ownerKind: string, ownerId: string): InventoryItemRow[] {
  const rows = safeAll(db, SELECT_BY_OWNER, [townId, ownerKind, ownerId]);
  return rows.map((r) => rowToInventoryItem(r as Record<string, unknown>));
}

function rowToInventoryItem(r: Record<string, unknown>): InventoryItemRow {
  return {
    slotIndex: Number(r.slotIndex ?? -1),
    itemDefId: String(r.itemDefId ?? ""),
    stackCount: Number(r.stackCount ?? 0),
    quality: r.quality == null ? undefined : Number(r.quality),
    listingPriceCenti: r.listingPriceCenti == null ? undefined : Number(r.listingPriceCenti),
    ...rowToAspects(r),
  };
}

// 把 item_instances 一行里的 typed-column 子集映射成 ItemInstanceAspects。
// 与 shelf-repo 共用，确保 instance 形状一致。
export function rowToAspects(r: Record<string, unknown>): ItemInstanceAspects {
  const aspects: ItemInstanceAspects = {
    shapeType: r.shapeType == null ? "" : String(r.shapeType),
    tags: parseJsonStringArray(r.tags),
    materials: parseJsonStringRecord(r.materials),
  };
  const physics = parseJsonObject(r.physicsProps);
  if (physics) aspects.physicsProps = physics;
  if (r.containerAmount != null) {
    aspects.container = {
      amount: Number(r.containerAmount),
      content: r.containerContent == null || r.containerContent === ""
        ? null
        : String(r.containerContent),
    };
  }
  if (r.freshnessTier != null) {
    aspects.freshness = {
      tier: Number(r.freshnessTier),
      ageHours: r.freshnessAgeHours == null ? null : Number(r.freshnessAgeHours),
    };
  }
  if (r.durability != null) aspects.durability = Number(r.durability);
  const baseEffects = parseJsonNumberRecord(r.baseEffects);
  if (baseEffects) aspects.baseEffects = baseEffects;
  const displayedEffects = parseJsonNumberRecord(r.displayedEffects);
  if (displayedEffects) aspects.displayedEffects = displayedEffects;
  return aspects;
}

function parseJsonObject(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "string" || value.length === 0) return undefined;
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : undefined;
  } catch {
    return undefined;
  }
}

function parseJsonStringArray(value: unknown): string[] {
  if (typeof value !== "string" || value.length === 0) return [];
  try {
    const parsed = JSON.parse(value);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((s): s is string => typeof s === "string");
  } catch {
    return [];
  }
}

function parseJsonStringRecord(value: unknown): Record<string, string> {
  const obj = parseJsonObject(value);
  if (!obj) return {};
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === "string") out[k] = v;
  }
  return out;
}

function parseJsonNumberRecord(value: unknown): Record<string, number> | undefined {
  const obj = parseJsonObject(value);
  if (!obj) return undefined;
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === "number" && Number.isFinite(v)) out[k] = v;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
