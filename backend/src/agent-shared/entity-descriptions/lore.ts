// World lore / fact boundary / common sense / reign era 等"世界基本设定"文本。
// 这些是游戏世界的共同认知，不是某个 agent 的策略；放共享。
// 文本本身存在 backend i18n（prompts.json），这里只是把多行 string 切成数组方便 prompt 拼装。

import { getActiveLocale, t } from "../../i18n/index.js";

// "人人默认懂"的 skill book —— 这些条目以 common_sense 形式注入 prompt，
// 不进 NPC 个体 skill seed（即使在某个 skill_id 的 books 列表里也会被 memory-service 过滤掉）。
// 判定原则：i18n description 里写"所有角色都默认懂"/"任何人都默认懂"的归这里。
export const COMMON_SENSE_SKILL_BOOKS = [
  "character_attributes_basics",
  "common_currency",
] as const;

export function getDefaultWorldLore(): string[] {
  return t("prompt.world_lore", getActiveLocale()).split("\n");
}

export function getFactBoundaryRules(): string[] {
  return t("prompt.fact_boundary", getActiveLocale()).split("\n");
}

export function getCommonSense(): string[] {
  const locale = getActiveLocale();
  const base = t("prompt.common_sense", locale).split("\n");
  const fromBooks: string[] = [];
  for (const bookId of COMMON_SENSE_SKILL_BOOKS) {
    fromBooks.push(...readSkillBookEntries(bookId, locale));
  }
  return [...base, ...fromBooks];
}

// 技能书 entries 真值在 data/i18n/<locale>/skills.json。
// 按 idx 探到 i18n key 不存在为止（t() 找不到 key 时会回退成 key 自身）。
// 上限 64 是安全栅栏，单本 entries 实际控制在 ~10 条以内。
export function readSkillBookEntries(bookId: string, locale: Parameters<typeof t>[1]): string[] {
  const out: string[] = [];
  for (let idx = 0; idx < 64; idx += 1) {
    const key = `skill.${bookId}.entries.${idx}`;
    const text = t(key, locale);
    if (!text || text === key) break;
    out.push(text);
  }
  return out;
}

// 技能书的"归属轴" 反查请用 skill-catalog.ts 的 getSkillForBook()。
// 这里不再维护本地 mapping —— 真值已收敛到 data/skills/skills.json。

export function getDefaultReignEraName(): string {
  return t("prompt.context.time.default_era", getActiveLocale());
}
