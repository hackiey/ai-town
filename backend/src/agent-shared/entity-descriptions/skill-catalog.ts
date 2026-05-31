// 技能轴 catalog 真值访问层。
// 真值在 data/skills/skills.json（root data/ 共享给 backend / Godot / lua）。
//
// 本模块只暴露 "skill_id → 元数据" 的纯函数查询。**不要**让别处的代码重新读 JSON
// 或自己维护一份镜像表 —— 命名漂移就是这么发生的（见 docs/proficiency_issues.md #4）。
//
// 设计取舍：boot 时一次 readFileSync 同步加载，全程进程内常驻。文件很小（<2KB），
// 而且重启间不会变；不值得做异步惰加载。

import { readFileSync } from "node:fs";

type SkillEntry = {
  books: string[];
};

type SkillCatalogFile = {
  skills: Record<string, SkillEntry>;
};

let catalog: Record<string, SkillEntry> | null = null;

function loadCatalog(): Record<string, SkillEntry> {
  if (catalog !== null) return catalog;
  const url = new URL("../../../../data/skills/skills.json", import.meta.url);
  const raw = readFileSync(url, "utf8");
  const parsed = JSON.parse(raw) as SkillCatalogFile;
  if (!parsed || typeof parsed !== "object" || !parsed.skills) {
    throw new Error("[skill-catalog] data/skills/skills.json missing top-level `skills` object");
  }
  catalog = parsed.skills;
  return catalog;
}

// 该 skill 关联的所有 book ids（i18n/skills.json 里的 entry id）。
// 空数组 = catalog 里有这条 skill 但暂时没书（如 charcoal_making / smelting）。
export function getBooksForSkill(skillId: string): string[] {
  const entry = loadCatalog()[skillId];
  return entry ? [...entry.books] : [];
}

// 反查：bookId 所属的 skill_id；找不到返回 undefined（common sense / admin 类书归"其他"组）。
export function getSkillForBook(bookId: string): string | undefined {
  const all = loadCatalog();
  for (const [skillId, entry] of Object.entries(all)) {
    if (entry.books.includes(bookId)) return skillId;
  }
  return undefined;
}

// 是否是真值表里登记过的 skill_id。用于 lua reaction.skill_id 对账、proficiency 数据校验。
export function isKnownSkillId(skillId: string): boolean {
  return Object.prototype.hasOwnProperty.call(loadCatalog(), skillId);
}

// 全部已登记的 skill_id（顺序按 JSON 文件中的出现顺序）。
export function listAllSkillIds(): string[] {
  return Object.keys(loadCatalog());
}
