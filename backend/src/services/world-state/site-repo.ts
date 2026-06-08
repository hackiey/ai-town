import type { AppDb } from "../../db/sqlite.js";
import type { SiteRecordView } from "./types.js";

// sites 表由 Godot SiteRegistry 建表 + seed（game-world 表，backend 只读）。
// 见 docs/architecture/site-system-refactor-plan.md §9 / §11。

const COLUMNS = `
  siteId, entityKind, entityId, defId, mapRegistration, parentSiteId, spaceId,
  capabilities, anchorsJson, posX, posY, posZ,
  arrivalRadius, visibleNearRadius, visibleFarRadius, directInteractionRadius,
  ownerGroup, lockItemId, groupGatedCapabilities,
  zone, category, sortOrder, nameKey, descriptionKey
`;

const SELECT_ALL = `SELECT ${COLUMNS} FROM sites WHERE townId = ?`;
const SELECT_BY_IDS = `SELECT ${COLUMNS} FROM sites WHERE townId = ? AND siteId IN`;
const SELECT_GLOBAL = `SELECT ${COLUMNS} FROM sites WHERE townId = ? AND mapRegistration = 'global'`;

// 整张表。用于建 resolver 索引 / 城镇地图全量遍历。
export function getAllSites(db: AppDb, townId: string): SiteRecordView[] {
  return safeAll(db, SELECT_ALL, [townId]).map(rowToSite);
}

// 按 id 批量取。Manifest 已确定可见 / 可交互的 site id。
export function getSitesByIds(db: AppDb, townId: string, siteIds: string[]): SiteRecordView[] {
  if (siteIds.length === 0) return [];
  const placeholders = siteIds.map(() => "?").join(",");
  return safeAll(db, `${SELECT_BY_IDS} (${placeholders})`, [townId, ...siteIds]).map(rowToSite);
}

// 城镇地图只遍历 mapRegistration=global。
export function getGlobalMapSites(db: AppDb, townId: string): SiteRecordView[] {
  return safeAll(db, SELECT_GLOBAL, [townId]).map(rowToSite);
}

function rowToSite(raw: unknown): SiteRecordView {
  const r = raw as Record<string, unknown>;
  const position = { x: Number(r.posX ?? 0), y: Number(r.posY ?? 0), z: Number(r.posZ ?? 0) };
  const anchors = parseAnchors(r.anchorsJson);
  return {
    siteId: String(r.siteId ?? ""),
    entityKind: String(r.entityKind ?? "location") as SiteRecordView["entityKind"],
    entityId: String(r.entityId ?? r.siteId ?? ""),
    defId: emptyToUndef(r.defId),
    mapRegistration: String(r.mapRegistration ?? "global") as SiteRecordView["mapRegistration"],
    parentSiteId: emptyToUndef(r.parentSiteId),
    spaceId: String(r.spaceId ?? "town_outdoor"),
    capabilities: parseStringArray(r.capabilities),
    position,
    anchors: anchors.length > 0 ? anchors : [position],
    arrivalRadius: Number(r.arrivalRadius ?? 1),
    visibleNearRadius: Number(r.visibleNearRadius ?? 0),
    visibleFarRadius: Number(r.visibleFarRadius ?? 0),
    directInteractionRadius: Number(r.directInteractionRadius ?? 0),
    ownerGroup: emptyToUndef(r.ownerGroup),
    lockItemId: emptyToUndef(r.lockItemId),
    groupGatedCapabilities: parseStringArray(r.groupGatedCapabilities),
    zone: emptyToUndef(r.zone),
    category: emptyToUndef(r.category),
    sortOrder: Number(r.sortOrder ?? 0),
    nameKey: emptyToUndef(r.nameKey),
    descriptionKey: emptyToUndef(r.descriptionKey),
  };
}

function emptyToUndef(v: unknown): string | undefined {
  return v == null || v === "" ? undefined : String(v);
}

function parseStringArray(v: unknown): string[] {
  if (typeof v !== "string" || v === "") return [];
  try {
    const parsed = JSON.parse(v);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

function parseAnchors(v: unknown): { x: number; y: number; z: number }[] {
  if (typeof v !== "string" || v === "") return [];
  try {
    const parsed = JSON.parse(v);
    if (!Array.isArray(parsed)) return [];
    return parsed.map((a) => ({
      x: Number((a as Record<string, unknown>)?.x ?? 0),
      y: Number((a as Record<string, unknown>)?.y ?? 0),
      z: Number((a as Record<string, unknown>)?.z ?? 0),
    }));
  } catch {
    return [];
  }
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
