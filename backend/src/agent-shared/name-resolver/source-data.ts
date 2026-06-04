// 加载 entity ids 的源数据。npcs/locations 走 data/town/，其它走 data/i18n/zh/
// （这些 i18n 文件本身就是 entity catalog 的 source of truth，name 字段同时供 LLM 看）。
//
// 路径相对 import.meta.url 的"目录"算（不是文件本身）。
// 本文件位于 backend/src/agent-shared/name-resolver/，所以：
//   - 3× ".." → backend/      （town/npcs.json / town/locations.json）
//   - 4× ".." → ai-games/      （仓库根 data/i18n/<locale>/*.json，共享给 Godot）
//
// readJson 出错直接 throw（含路径写错 / JSON 语法错 / 权限）——entity catalog 是启动必备，
// 静默空 catalog 会让所有 LLM 工具的 name resolution 全失败但 backend 看似启动正常，
// 表现为 LLM 任何中文名都"无法识别"，调起来很痛苦。

import { readFileSync } from "node:fs";

export type LocationDescriptor = {
  category?: string;
  primaryNpcs?: string[];
  // 城镇地图分区（上城/下城/外城/城堡/南郊）。只有顶层地点标 zone；子地点（摊位/农田/
  // 工作台）靠 parent 的 children 列表渲染，自身不带 zone。见 [[project_town_map_zones]]。
  zone?: string;
  // 该地点下挂的子项，有序：可混 workstation 类型 id（forge/stove…，跨铺子共享）与
  // 子地点 id（农田 / 集市摊位）。工作台类型合并成单一逻辑地点，无法从 DB 父子关系推导，
  // 故在此显式编排。
  children?: string[];
};

type CharacterDescriptor = {
  name?: string;
  aliases?: string[];
};

let cachedLocations: Record<string, LocationDescriptor> | undefined;
let cachedCharacters: Record<string, CharacterDescriptor> | undefined;
let cachedItemIds: string[] | undefined;
let cachedWorkstationIds: string[] | undefined;
let cachedContainerIds: string[] | undefined;
let cachedMaterialIds: string[] | undefined;
let cachedAttributeIds: string[] | undefined;
let cachedGroupIds: string[] | undefined;

export function characterDescriptors(): Record<string, CharacterDescriptor> {
  if (cachedCharacters) return cachedCharacters;
  cachedCharacters = readJson("../../../data/town/npcs.json") as Record<string, CharacterDescriptor>;
  return cachedCharacters;
}

export function characterDescriptor(id: string): CharacterDescriptor | undefined {
  return characterDescriptors()[id];
}

export function locationDescriptors(): Record<string, LocationDescriptor> {
  if (cachedLocations) return cachedLocations;
  cachedLocations = readJson("../../../data/town/locations.json") as Record<string, LocationDescriptor>;
  return cachedLocations;
}

export function locationDescriptor(id: string): LocationDescriptor | undefined {
  return locationDescriptors()[id];
}

export function itemIds(): string[] {
  if (cachedItemIds) return cachedItemIds;
  cachedItemIds = readEntityIds("items.json", "item");
  return cachedItemIds;
}

export function workstationIds(): string[] {
  if (cachedWorkstationIds) return cachedWorkstationIds;
  cachedWorkstationIds = readEntityIds("workstations.json", "workstation");
  return cachedWorkstationIds;
}

export function containerIds(): string[] {
  if (cachedContainerIds) return cachedContainerIds;
  cachedContainerIds = readEntityIds("containers.json", "container");
  return cachedContainerIds;
}

export function materialIds(): string[] {
  if (cachedMaterialIds) return cachedMaterialIds;
  cachedMaterialIds = readEntityIds("materials.json", "material");
  return cachedMaterialIds;
}

export function attributeIds(): string[] {
  if (cachedAttributeIds) return cachedAttributeIds;
  cachedAttributeIds = readEntityIds("attributes.json", "attribute");
  return cachedAttributeIds;
}

export function groupIds(): string[] {
  if (cachedGroupIds) return cachedGroupIds;
  cachedGroupIds = readEntityIds("groups.json", "group");
  return cachedGroupIds;
}

function readEntityIds(file: string, rootKey: string): string[] {
  const raw = readJson(`../../../../data/i18n/zh/${file}`) as Record<string, Record<string, unknown>>;
  return Object.keys(raw[rootKey] ?? {});
}

function readJson(relativePath: string): unknown {
  const url = new URL(relativePath, import.meta.url);
  let raw: string;
  try {
    raw = readFileSync(url, "utf8");
  } catch (err) {
    throw new Error(`[name-resolver] failed to read entity source ${url.pathname}: ${(err as Error).message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`[name-resolver] failed to parse entity source ${url.pathname} as JSON: ${(err as Error).message}`);
  }
}
