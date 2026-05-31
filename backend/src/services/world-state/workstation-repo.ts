import type { AppDb } from "../../db/sqlite.js";
import type { WorkstationView } from "./types.js";

const SELECT_BY_IDS = `
  SELECT workstationNodeId, workstationDefId, locationId, ownerGroup,
         posX, posY, posZ, interactionMode, slotCount, verbs,
         currentOperatorId, currentVerb, busy
  FROM workstation_states
  WHERE townId = ? AND workstationNodeId IN
`;

export function getWorkstationsByIds(db: AppDb, townId: string, nodeIds: string[]): WorkstationView[] {
  if (nodeIds.length === 0) return [];
  const placeholders = nodeIds.map(() => "?").join(",");
  const rows = safeAll(db, `${SELECT_BY_IDS} (${placeholders})`, [townId, ...nodeIds]);
  return rows.map((r) => rowToWorkstationView(r as Record<string, unknown>));
}

function rowToWorkstationView(r: Record<string, unknown>): WorkstationView {
  return {
    workstationNodeId: String(r.workstationNodeId ?? ""),
    workstationDefId: String(r.workstationDefId ?? ""),
    locationId: r.locationId == null ? undefined : String(r.locationId),
    ownerGroup: r.ownerGroup == null ? undefined : String(r.ownerGroup),
    position: {
      x: Number(r.posX ?? 0),
      y: Number(r.posY ?? 0),
      z: Number(r.posZ ?? 0),
    },
    interactionMode: r.interactionMode == null ? undefined : String(r.interactionMode),
    slotCount: Number(r.slotCount ?? 0),
    verbs: parseStringArray(r.verbs),
    currentOperatorId: r.currentOperatorId == null ? undefined : String(r.currentOperatorId),
    currentVerb: r.currentVerb == null ? undefined : String(r.currentVerb),
    busy: Number(r.busy ?? 0) !== 0,
  };
}

function parseStringArray(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.filter((entry): entry is string => typeof entry === "string");
  }
  if (typeof value !== "string" || value.length === 0) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((e): e is string => typeof e === "string") : [];
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
