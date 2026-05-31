// Workstation / Container / Material / Item / Attribute 都长一样：
//   - 名字: t("<kind>.<id>.name", locale)
//   - aliases: ids + 所有 locale 的 name
//   - 反查索引: aliases ∋ key → id
// 唯一变量是 normalize 策略和 i18n namespace。统一这里给个工厂。

import { SOURCE_LOCALE, SUPPORTED_LOCALES, t, type Locale } from "../../i18n/index.js";
import { buildAliasIndex, type AliasIndex, uniqueDisplayStrings } from "./alias-index.js";

export type SimpleEntityResolver = {
  name: (id: string, locale?: Locale) => string;
  aliases: (id: string) => string[];
  resolveByName: (value: unknown) => string | undefined;
};

export function createSimpleEntityResolver(opts: {
  i18nNamespace: string;     // e.g. "workstation" / "item"
  loadIds: () => string[];
  normalize: (value: string) => string;
}): SimpleEntityResolver {
  const name = (id: string, locale: Locale = SOURCE_LOCALE): string => {
    const key = `${opts.i18nNamespace}.${id}.name`;
    const value = t(key, locale);
    return value === key ? id : value;
  };

  const aliases = (id: string): string[] => {
    const out = [id];
    for (const locale of SUPPORTED_LOCALES) {
      out.push(name(id, locale));
    }
    return uniqueDisplayStrings(out);
  };

  let cached: AliasIndex | undefined;
  const index = (): AliasIndex => {
    if (cached) return cached;
    cached = buildAliasIndex(opts.loadIds(), aliases, opts.normalize);
    return cached;
  };

  const resolveByName = (value: unknown): string | undefined => {
    if (typeof value !== "string") return undefined;
    const key = opts.normalize(value);
    if (!key) return undefined;
    return index().get(key);
  };

  return { name, aliases, resolveByName };
}
