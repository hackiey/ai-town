import type { AppDb } from "../../db/sqlite.js";
import { getInventoryForContainer } from "./inventory-repo.js";
import type { ContainerView } from "./types.js";

const SELECT_BY_IDS = `
  SELECT containerId, lockItemId, ownerGroup, slotCount, interactionRadius,
         posX, posY, posZ
  FROM container_states
  WHERE townId = ? AND containerId IN
`;

export function getContainersByIds(db: AppDb, townId: string, containerIds: string[]): ContainerView[] {
  if (containerIds.length === 0) return [];
  const placeholders = containerIds.map(() => "?").join(",");
  const rows = safeAll(db, `${SELECT_BY_IDS} (${placeholders})`, [townId, ...containerIds]);
  return rows.map((r) => {
    const view = rowToContainerView(r as Record<string, unknown>);
    view.contents = getInventoryForContainer(db, townId, view.containerId);
    return view;
  });
}

function rowToContainerView(r: Record<string, unknown>): ContainerView {
  return {
    containerId: String(r.containerId ?? ""),
    lockItemId: r.lockItemId == null || r.lockItemId === "" ? undefined : String(r.lockItemId),
    ownerGroup: r.ownerGroup == null || r.ownerGroup === "" ? undefined : String(r.ownerGroup),
    slotCount: Number(r.slotCount ?? 0),
    interactionRadius: Number(r.interactionRadius ?? 0),
    position: {
      x: Number(r.posX ?? 0),
      y: Number(r.posY ?? 0),
      z: Number(r.posZ ?? 0),
    },
    contents: [],
  };
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
