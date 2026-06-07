import type { AppDb } from "../../db/sqlite.js";
import type { LocationMarkerView } from "./types.js";

const SELECT_BY_IDS = `
  SELECT locationId, parentLocationId, ownerGroup,
         posX, posY, posZ, isWorkstation
  FROM location_markers
  WHERE townId = ? AND locationId IN
`;

const SELECT_ALL = `
  SELECT locationId, parentLocationId, ownerGroup,
         posX, posY, posZ, isWorkstation
  FROM location_markers
  WHERE townId = ?
`;

// 按 id 列表批量取。Manifest 已确定可见 id；ownerGroup 只作为归属元数据返回。
export function getLocationsByIds(db: AppDb, townId: string, locationIds: string[]): LocationMarkerView[] {
  if (locationIds.length === 0) return [];
  const placeholders = locationIds.map(() => "?").join(",");
  const rows = safeAll(db, `${SELECT_BY_IDS} (${placeholders})`, [townId, ...locationIds]);
  return rows.map((r) => rowToLocationView(r as Record<string, unknown>));
}

// 整张表 dump。给某些不依赖 perception 的旁路调试用。
export function getAllLocations(db: AppDb, townId: string): LocationMarkerView[] {
  const rows = safeAll(db, SELECT_ALL, [townId]);
  return rows.map((r) => rowToLocationView(r as Record<string, unknown>));
}

function rowToLocationView(r: Record<string, unknown>): LocationMarkerView {
  return {
    locationId: String(r.locationId ?? ""),
    parentLocationId: r.parentLocationId == null || r.parentLocationId === "" ? undefined : String(r.parentLocationId),
    ownerGroup: r.ownerGroup == null || r.ownerGroup === "" ? undefined : String(r.ownerGroup),
    position: {
      x: Number(r.posX ?? 0),
      y: Number(r.posY ?? 0),
      z: Number(r.posZ ?? 0),
    },
    isWorkstation: Number(r.isWorkstation ?? 0) !== 0,
  };
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
