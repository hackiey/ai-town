import { SOURCE_LOCALE, t, type Locale } from "../../i18n/index.js";
import { normalizeSlugKey } from "./alias-index.js";
import { createSimpleEntityResolver } from "./_simple-entity.js";
import { workstationIds } from "./source-data.js";

const resolver = createSimpleEntityResolver({
  i18nNamespace: "workstation",
  loadIds: workstationIds,
  normalize: normalizeSlugKey,
});

export const workstationName = resolver.name;
export const workstationNameAliases = resolver.aliases;
export const resolveWorkstationIdByName = resolver.resolveByName;

// 城镇地图用：工作台的 agent 视角描述（功能 + 技能/工具门槛）。无则 undefined。
export function workstationDescription(id: string, locale: Locale = SOURCE_LOCALE): string | undefined {
  const key = `workstation.${id}.description`;
  const value = t(key, locale);
  return value === key ? undefined : value;
}
