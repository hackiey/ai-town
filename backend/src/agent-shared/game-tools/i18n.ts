// Tool 描述 / label / prefix 全部经 i18n catalog (data/i18n/<locale>/tools.json) 解析。
// td(key) = "tool description"，是 t() 在 tools 域的简写。

import { getActiveLocale, t } from "../../i18n/index.js";

export function td(key: string, params?: Record<string, string | number>): string {
  return t(`tool.${key}`, getActiveLocale(), params);
}

export function currentLocationParameterValues(): readonly string[] {
  return [td("common.current_location_value")];
}

export function moveToCharacterPrefix(): string {
  return td("common.move_to_character_prefix");
}

export function moveToItemPrefix(): string {
  return td("common.move_to_item_prefix");
}

export function toolReasonDescription(): string {
  return td("common.reason_description");
}
