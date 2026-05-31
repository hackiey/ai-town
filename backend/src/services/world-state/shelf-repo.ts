import type { AppDb } from "../../db/sqlite.js";
import { rowToAspects } from "./inventory-repo.js";
import type { ShelfListingView, ShelfView } from "./types.js";

// shelf_listings 只存 (id, shelfId, slotIndex, ownerCharacterId, priceCenti)。
// 物品真值在 item_instances (ownerKind='shelf', id = listing id)。
// 所有 SELECT 都 LEFT JOIN —— item_instances 缺行（slot 实际为空但 listing 还在）退化为空 quantity。
// item_instances typed-column 全部 SELECT 出来由 rowToAspects 拼成 ItemInstanceAspects，
// 让 shelf listing 与 inventory row 形状对齐（同源 row，相同 aspect set）。
//
// 价格单位是 centi（1 silver = 100 centi），暴露给 LLM/UI 时除 100 得 priceSilver(float)。

const BASE_JOIN = `
  SELECT l.id AS listingId, l.shelfId, l.slotIndex, l.ownerCharacterId, l.priceCenti,
         i.itemDefId, i.stackCount AS quantity, i.quality,
         i.shapeType, i.tags, i.materials, i.physicsProps,
         i.containerAmount, i.containerContent,
         i.freshnessTier, i.freshnessAgeHours,
         i.durability,
         i.baseEffects, i.displayedEffects
  FROM shelf_listings l
  LEFT JOIN item_instances i ON i.id = l.id AND i.townId = l.townId
`;

export function getShelfListingsByShelfIds(db: AppDb, townId: string, shelfIds: string[]): ShelfListingView[] {
  if (shelfIds.length === 0) return [];
  const placeholders = shelfIds.map(() => "?").join(",");
  const sql = `${BASE_JOIN} WHERE l.townId = ? AND l.shelfId IN (${placeholders}) ORDER BY l.shelfId ASC, l.slotIndex ASC`;
  const rows = safeAll(db, sql, [townId, ...shelfIds]);
  return rows.map((r) => rowToListingView(r as Record<string, unknown>));
}

const SHELF_SELECT = `
  SELECT shelfId, ownerGroup, locationId, slotCount, interactionRadius, posX, posY, posZ
  FROM shelves
`;

// 按 shelfId 查货架静态镜像。空数组入参 → 空结果。perceived shelfIds 走这条。
export function getShelvesByIds(db: AppDb, townId: string, shelfIds: string[]): ShelfView[] {
  if (shelfIds.length === 0) return [];
  const placeholders = shelfIds.map(() => "?").join(",");
  const sql = `${SHELF_SELECT} WHERE townId = ? AND shelfId IN (${placeholders}) ORDER BY shelfId ASC`;
  const rows = safeAll(db, sql, [townId, ...shelfIds]);
  return rows.map((r) => rowToShelfView(r as Record<string, unknown>));
}

// 按 ownerGroup 列表查 —— "我管理的货架" 走这条（character_groups 里 character 所属的组 ids）。
// 空数组入参 → 空结果（god 组的处理留给 caller：god 想看全量请另走 getShelvesByIds 或单独查询）。
export function getShelvesByOwnerGroups(db: AppDb, townId: string, ownerGroups: string[]): ShelfView[] {
  if (ownerGroups.length === 0) return [];
  const placeholders = ownerGroups.map(() => "?").join(",");
  const sql = `${SHELF_SELECT} WHERE townId = ? AND ownerGroup IN (${placeholders}) ORDER BY shelfId ASC`;
  const rows = safeAll(db, sql, [townId, ...ownerGroups]);
  return rows.map((r) => rowToShelfView(r as Record<string, unknown>));
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
  };
}

// 把 listings 分组成 {shelfId: ShelfListingView[]}，给 caller 拼 ShelfContext 用。
export function groupListingsByShelfId(listings: ShelfListingView[]): Map<string, ShelfListingView[]> {
  const out = new Map<string, ShelfListingView[]>();
  for (const listing of listings) {
    const list = out.get(listing.shelfId) ?? [];
    list.push(listing);
    out.set(listing.shelfId, list);
  }
  return out;
}

function rowToListingView(r: Record<string, unknown>): ShelfListingView {
  const aspects = rowToAspects(r);
  const priceCenti = Number(r.priceCenti ?? 0);
  return {
    listingId: String(r.listingId ?? ""),
    shelfId: String(r.shelfId ?? ""),
    slotIndex: Number(r.slotIndex ?? -1),
    itemDefId: String(r.itemDefId ?? ""),
    quantity: Number(r.quantity ?? 0),
    priceCenti,
    priceSilver: priceCenti / 100,
    quality: r.quality == null ? undefined : Number(r.quality),
    freshnessTier: aspects.freshness?.tier,
    ...aspects,
  };
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
