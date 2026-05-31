// 别名 → id 的反查索引：所有 entity 类型共用一套构造法和 normalize 策略。
// per-entity 文件提供 ids + aliasesForId + normalize，alias-index 负责构造和缓存 Map。

export type AliasIndex = Map<string, string>;

export function buildAliasIndex(
  ids: string[],
  aliasesForId: (id: string) => string[],
  normalize: (value: string) => string,
): AliasIndex {
  const map: AliasIndex = new Map();
  for (const id of ids) {
    for (const alias of aliasesForId(id)) {
      const key = normalize(alias);
      if (key && !map.has(key)) {
        map.set(key, id);
      }
    }
  }
  return map;
}

export function uniqueDisplayStrings(values: Array<string | undefined>): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    const trimmed = value?.trim();
    if (!trimmed || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    out.push(trimmed);
  }
  return out;
}

// 通用 normalize：去首尾空格 / 小写 / 把 dash 和 space 统一成 underscore。
// 物品/工作台/容器/材料/属性都吃这个；character 和 location 有自己的更宽松版本。
export function normalizeSlugKey(value: string): string {
  return value.trim().toLowerCase().replaceAll("-", "_").replaceAll(" ", "_");
}

// 角色名 normalize：剥掉 displayName 后缀的状态标记（如 "Oren Vale (睡着)" 中的括号），再小写。
export function normalizeCharacterAliasKey(value: string): string {
  return stripCharacterDisplayStatusSuffix(value).trim().toLowerCase();
}

function stripCharacterDisplayStatusSuffix(value: string): string {
  const trimmed = value.trim();
  const stripped = trimmed.replace(/\s*[（(][^()（）]+[)）]\s*$/u, "");
  return stripped.length > 0 ? stripped : trimmed;
}

// Item normalize 比较宽松：保留空格、不替换 dash，只 trim + lower + collapse 空白
// （这是因为物品名常有多词组合，"Iron Ore" 应能匹配 "iron ore" 但也能匹配 "Iron  Ore"）。
export function normalizeItemAliasKey(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

// 属性 normalize：完全去 underscore 和空白，让 "饱食度" / "satiation" / "satiation_level" 都能命中。
export function normalizeAttributeAliasKey(value: string): string {
  return value.trim().toLowerCase().replaceAll("_", "").replace(/\s+/g, "");
}
