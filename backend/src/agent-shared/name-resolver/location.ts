// Location name resolver。location 的 displayName 通过 i18n key location.<id>.alias 解析；
// description 通过 location.<id>.description（可能不存在 → undefined）。

import { SOURCE_LOCALE, t, type Locale } from "../../i18n/index.js";
import { buildAliasIndex, normalizeSlugKey, uniqueDisplayStrings, type AliasIndex } from "./alias-index.js";
import { locationDescriptors } from "./source-data.js";

export function locationName(id: string, aliasOverride?: string, locale: Locale = SOURCE_LOCALE): string {
  const override = aliasOverride?.trim();
  if (override) return override;
  const aliasKey = `location.${id}.alias`;
  const alias = t(aliasKey, locale);
  if (alias && alias !== aliasKey) return alias;
  return id === "unknown" ? t("error.location_unknown", locale) : id;
}

export function locationDescription(id: string, locale: Locale = SOURCE_LOCALE): string | undefined {
  const key = `location.${id}.description`;
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

function locationAliasIndex(): AliasIndex {
  if (cachedIndex) return cachedIndex;
  cachedIndex = buildAliasIndex(
    Object.keys(locationDescriptors()),
    locationNameAliases,
    normalizeSlugKey,
  );
  return cachedIndex;
}
