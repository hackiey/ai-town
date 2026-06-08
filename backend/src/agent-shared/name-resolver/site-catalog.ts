// Site catalog：地点结构的唯一真值来源 = Godot 灌进 sites 表的数据（不再读 locations.json）。
// backend 只「渲染 + 解析」：本模块把 sites 表快照成内存 catalog，供 db-less 的 resolver /
// localize / renderTownMap 读取（它们运行在没有 db handle 的路径里）。
//
// 刷新时机：每次 assembleAgentContextFromManifest（持有 db+townId）调一次 refreshSiteCatalog。
// sites 表 Godot boot 时 seed、之后静态，所以一个 backend 进程内基本不变；version 计数让
// 下游 alias 索引能在刷新后失效重建。consumer 全在 turn 内（assemble 之后）跑，故读到的是
// 已填充的快照。空 catalog（Godot 尚未 seed）= 渲染/解析降级为空，不静默兜造假数据。

import type { AppDb } from "../../db/sqlite.js";
import { getAllSites } from "../../services/world-state/site-repo.js";
import type { SiteRecordView } from "../../services/world-state/types.js";

// 地点结构描述（取代旧 locations.json 的 LocationDescriptor）。zone/category 直接来自 site；
// children 从 sites 的层级（parentSiteId）+ 归属（ownerGroup）推导，按 sortOrder 排。
export type SiteDescriptor = {
  zone?: string;
  category?: string;
  children: string[];
};

let records: SiteRecordView[] = [];
let version = 0;
let descriptorsCache: Record<string, SiteDescriptor> | undefined;
let descriptorsCacheVersion = -1;

export function refreshSiteCatalog(db: AppDb, townId: string): void {
  records = getAllSites(db, townId);
  version++;
  descriptorsCache = undefined;
}

export function siteCatalogVersion(): number {
  return version;
}

export function siteCatalogRecords(): SiteRecordView[] {
  return records;
}

export function siteById(id: string): SiteRecordView | undefined {
  return records.find((r) => r.siteId === id);
}

// 城镇地图遍历用：mapRegistration=global 的顶层 site（按 zone 分组在 renderTownMap 里做）。
export function globalMapSiteIds(): string[] {
  return records.filter((r) => r.mapRegistration === "global").map((r) => r.siteId);
}

// 取代 locations.json：从 sites 派生 {id → {zone, category, children}}。每个 site 一条目，
// 故 resolver / localize 遍历 keys 即覆盖全部地点。children = 子 site（parentSiteId 指向它）
// 或归属它的机制 site（ownerGroup == 该 id，且自身没父没 zone，典型：anvil@blacksmith_shop
// 归到 blacksmith_shop 下），按 sortOrder→id 排。
export function siteDescriptors(): Record<string, SiteDescriptor> {
  if (descriptorsCache && descriptorsCacheVersion === version) return descriptorsCache;
  const map: Record<string, SiteDescriptor> = {};
  for (const r of records) {
    map[r.siteId] = { zone: r.zone, category: r.category, children: [] };
  }
  const childOrder = new Map<string, { id: string; sortOrder: number }[]>();
  for (const r of records) {
    const parent = resolveParentId(r, map);
    if (!parent || parent === r.siteId || !map[parent]) continue;
    const list = childOrder.get(parent) ?? [];
    list.push({ id: r.siteId, sortOrder: r.sortOrder });
    childOrder.set(parent, list);
  }
  for (const [parent, list] of childOrder) {
    list.sort((a, b) => a.sortOrder - b.sortOrder || a.id.localeCompare(b.id));
    map[parent].children = list.map((e) => e.id);
  }
  descriptorsCache = map;
  descriptorsCacheVersion = version;
  return map;
}

// 父 site：优先显式 parentSiteId；否则归属 ownerGroup（当 ownerGroup 是某个 site 且本 site
// 自身不是顶层 zoned 地点时——把工作台/货架挂到它所属的店铺下）。
function resolveParentId(r: SiteRecordView, map: Record<string, SiteDescriptor>): string | undefined {
  if (r.parentSiteId && map[r.parentSiteId]) return r.parentSiteId;
  if (!r.zone && r.ownerGroup && map[r.ownerGroup]) return r.ownerGroup;
  return undefined;
}
