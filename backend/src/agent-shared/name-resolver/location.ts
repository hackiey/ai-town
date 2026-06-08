// Location name resolver。location 的 displayName 通过 i18n key location.<id>.alias 解析；
// description 通过 location.<id>.description（可能不存在 → undefined）。

import { SOURCE_LOCALE, t, type Locale } from "../../i18n/index.js";
import { buildAliasIndex, normalizeSlugKey, uniqueDisplayStrings, type AliasIndex } from "./alias-index.js";
import { locationDescriptors } from "./source-data.js";
import { siteCatalogVersion } from "./site-catalog.js";
import { workstationName } from "./workstation.js";
import { ownerSuffixedSiteName } from "../entity-descriptions/site-naming.js";

// 有主工作台的逻辑地点 id 约定为 "<def>@<group>"（Godot _register_workstations 生成、随
// location_markers 落进 DB；id 自带 def 和 owner group）。其显示名"铁砧（巴克利铁匠铺）"
// 在运行时拼，不落生成文件：locationName 见 "@" 拆出 def+group，用与 interactive-sites
// 同一个 ownerSuffixedSiteName 算出。Godot 端（town_world.location_alias）同样在自己运行时
// 拼一份（GDScript/TS 没法共享代码，但都读同一份 workstations/groups catalog、同格式）——
// 与"每个名字本就在两端各 t()/tr() 一遍"的常态一致。非此形态返回 undefined。
function ownedWorkstationDisplayName(id: string, locale: Locale): string | undefined {
  const at = id.indexOf("@");
  if (at <= 0) return undefined;
  const def = id.slice(0, at);
  const group = id.slice(at + 1);
  return ownerSuffixedSiteName(workstationName(def, locale), group, locale);
}

// 任何"地点 id"→ 显示名的唯一解析器。覆盖三类 id：
//   1. 有主工作台组合 id "<def>@<group>" → ownerSuffixedSiteName 拼"铁砧（巴克利铁匠铺）"
//   2. 普通地点 id → location.<id>.alias
//   3. 工作台当地点用（公共水井等） / 容器型 → workstation.<id>.name 兜底
// 调用方解析地点 id 时一律走这里（或 names.location），**不要**自己按 isWorkstation 分流去
// 调 workstationName —— 那对组合 id 会吐原始 id，正是漏 "gold_mine_workstation@gold_mine"
// 进 prompt 的根因。aliasOverride 仅用于真正的 per-instance 自定义名；等于 id 本身的
// 脏 override 一律忽略（防御上游传错）。
export function locationName(id: string, aliasOverride?: string, locale: Locale = SOURCE_LOCALE): string {
  const override = aliasOverride?.trim();
  if (override && override !== id) return override;
  const owned = ownedWorkstationDisplayName(id, locale);
  if (owned) return owned;
  const aliasKey = `location.${id}.alias`;
  const alias = t(aliasKey, locale);
  if (alias && alias !== aliasKey) return alias;
  const ws = workstationName(id, locale);
  if (ws && ws !== id) return ws;
  return id === "unknown" ? t("error.location_unknown", locale) : id;
}

export function locationDescription(id: string, locale: Locale = SOURCE_LOCALE): string | undefined {
  const key = `location.${id}.description`;
  const value = t(key, locale);
  return value === key ? undefined : value;
}

// 城镇地图用：方位短语（"集市东侧"）。无则 undefined。
export function locationDirection(id: string, locale: Locale = SOURCE_LOCALE): string | undefined {
  const key = `location.${id}.direction`;
  const value = t(key, locale);
  return value === key ? undefined : value;
}

// 城镇地图用：使用限制叙述（"需主人同意"）。无则 undefined（公共地点不写）。
export function locationAccess(id: string, locale: Locale = SOURCE_LOCALE): string | undefined {
  const key = `location.${id}.access`;
  const value = t(key, locale);
  return value === key ? undefined : value;
}

export function locationNameAliases(id: string): string[] {
  return uniqueDisplayStrings([id, locationName(id)]);
}

export function resolveLocationIdByName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const key = normalizeSlugKey(value);
  if (!key) return undefined;
  return locationAliasIndex().get(key);
}

let cachedIndex: AliasIndex | undefined;
let cachedIndexVersion = -1;

function locationAliasIndex(): AliasIndex {
  // sites catalog 刷新后（version 变）重建索引——地点结构真值来自 Godot，不能一次性缓存。
  if (cachedIndex && cachedIndexVersion === siteCatalogVersion()) return cachedIndex;
  const descriptors = locationDescriptors();
  // 顶层 / 子地点 id（locations.json 的键）+ children 里出现的有主工作台组合 id（含 "@"）。
  // 后者不是 locations.json 的键，但 move_to_location 要能按"铁砧（巴克利铁匠铺）"反查到组合 id。
  const ids = new Set<string>(Object.keys(descriptors));
  for (const descriptor of Object.values(descriptors)) {
    for (const child of descriptor.children ?? []) {
      if (child.includes("@")) ids.add(child);
    }
  }
  cachedIndex = buildAliasIndex([...ids], locationNameAliases, normalizeSlugKey);
  cachedIndexVersion = siteCatalogVersion();
  return cachedIndex;
}
