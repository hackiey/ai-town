import type { AppDb } from "../../db/sqlite.js";
import { getInventoryForContainer } from "./inventory-repo.js";
import type { ShelfView } from "./types.js";

// 货架已统一为无锁容器（Godot ShelfNode extends ContainerNode）。shelves 表只存静态镜像
// （位置 / locationId / 容量），内容物与标价走 item_instances(ownerKind='container', ownerId=shelfId)，
// 标价是槽位 listingPriceCenti aspect。所以读货架内容复用 getInventoryForContainer。

const SHELF_SELECT = `
  SELECT shelfId, ownerGroup, locationId, slotCount, interactionRadius, posX, posY, posZ
  FROM shelves
`;

// 按 shelfId 查货架（静态镜像 + 内容）。空数组入参 → 空结果。perceived shelfIds 走这条。
export function getShelvesByIds(db: AppDb, townId: string, shelfIds: string[]): ShelfView[] {
  if (shelfIds.length === 0) return [];
  const placeholders = shelfIds.map(() => "?").join(",");
  const sql = `${SHELF_SELECT} WHERE townId = ? AND shelfId IN (${placeholders}) ORDER BY shelfId ASC`;
  const rows = safeAll(db, sql, [townId, ...shelfIds]);
  return rows.map((r) => {
    const view = rowToShelfView(r as Record<string, unknown>);
    view.contents = getInventoryForContainer(db, townId, view.shelfId);
    return view;
  });
}

function rowToShelfView(r: Record<string, unknown>): ShelfView {
  return {
    shelfId: String(r.shelfId ?? ""),
    ownerGroup: r.ownerGroup == null || r.ownerGroup === "" ? undefined : String(r.ownerGroup),
    locationId: r.locationId == null || r.locationId === "" ? undefined : String(r.locationId),
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
