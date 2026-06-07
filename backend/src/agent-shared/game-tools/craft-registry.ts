// 手艺（craft）真值访问层。
// 真值在 data/skills/crafts.json（Godot 项目根的 data/ 下，跨端共享）。
// Godot 端 src/autoload/crafts.gd 与本文件读同一份，禁止再起镜像表。
//
// craft = LLM 看到的一个手艺工具（mine / cook / smith…），背后由 (workstation, verb)
// 决定路由到哪个 lua reaction。新增 craft 改 data/skills/crafts.json，别动这里。
//
// 本模块只暴露纯函数查询。所有调用方（factory 过滤、schema 装配、tool-factories
// 工厂、event 渲染、reaction-catalog 对账）都走这些 helper，不要绕过去自己 parse JSON。

import { readFileSync } from "node:fs";

// ───────── JSON shape ─────────

type CraftOperation = { workstation: string; verb: string };

type CraftRecordJson = {
  skillId: string;
  operations: CraftOperation[];
  subOptions?: string[];
  fixedSubOption?: string;
};

type CraftsFile = {
  crafts: Record<string, CraftRecordJson>;
};

// ───────── derived view ─────────

// 单个 craft 的运行时视图。operations 是 (workstation, verb) 元组列表；workstations /
// verbs / fixedVerb 是从 operations 派生的便利字段（多数 craft 这些值都唯一）。
export type CraftSpec = {
  skillId: string;
  operations: ReadonlyArray<CraftOperation>;
  workstations: ReadonlyArray<string>;
  verbs: ReadonlyArray<string>;
  // 所有 operations 的 verb 相同时填这个；多 verb craft（cook、smelt、woodwork）为 undefined。
  fixedVerb?: string;
  subOptions?: ReadonlyArray<string>;
  fixedSubOption?: string;
};

let _crafts: Record<string, CraftSpec> | null = null;
let _slugs: readonly string[] = [];
let _proficiencySlugs: readonly string[] = [];

function load(): void {
  if (_crafts !== null) return;
  const url = new URL("../../../../data/skills/crafts.json", import.meta.url);
  const raw = readFileSync(url, "utf8");
  const parsed = JSON.parse(raw) as CraftsFile;
  if (!parsed || typeof parsed.crafts !== "object") {
    throw new Error("[craft-registry] data/skills/crafts.json missing top-level `crafts` object");
  }
  const built: Record<string, CraftSpec> = {};
  for (const [slug, rec] of Object.entries(parsed.crafts)) {
    if (!Array.isArray(rec.operations) || rec.operations.length === 0) {
      throw new Error(`[craft-registry] craft '${slug}' must declare at least one operation`);
    }
    const workstations = Array.from(new Set(rec.operations.map((op) => op.workstation)));
    const verbs = Array.from(new Set(rec.operations.map((op) => op.verb)));
    built[slug] = {
      // skillId 可以为空字符串：表示该 craft 没有熟练度概念。
      // listProficiencyCrafts 会过滤掉这种，filter 不会按 proficiency 误伤它们。
      skillId: rec.skillId ?? "",
      operations: rec.operations,
      workstations,
      verbs,
      fixedVerb: verbs.length === 1 ? verbs[0] : undefined,
      subOptions: rec.subOptions,
      fixedSubOption: rec.fixedSubOption,
    };
  }
  _crafts = built;
  _slugs = Object.keys(built);
  _proficiencySlugs = _slugs.filter((s) => built[s].skillId.length > 0);
}

// ───────── public API ─────────

// craft slug 类型：保留 string 以避免 `as const` 二次维护成本（数据真值在 JSON）。
// 调用方该 narrow 时用 isKnownCraft 守护。
export type CraftSlug = string;

// 所有登记的 craft（含无 proficiency 的直接使用型）。
export function listCraftSlugs(): readonly string[] {
  load();
  return _slugs;
}

// 只列有 skillId 的 craft —— LLM 工具按 proficiency 过滤时只看这一档。
// skillId="" 的直接使用型不在此列，由各 factory 自己 always-expose。
export function listProficiencyCrafts(): readonly string[] {
  load();
  return _proficiencySlugs;
}

// listCraftSlugs 已含全部 craft 动作；保留这个别名以表达"是否是 wire action"语义。
export function isCraftAction(name: string): boolean {
  return isKnownCraft(name);
}

export function isKnownCraft(name: string): boolean {
  load();
  return name in (_crafts as Record<string, CraftSpec>);
}

export function getCraftSpec(slug: string): CraftSpec {
  load();
  const spec = (_crafts as Record<string, CraftSpec>)[slug];
  if (!spec) throw new Error(`[craft-registry] unknown craft slug '${slug}'`);
  return spec;
}

// 反查：(workstation, verb) → craft slug。Phase B reaction-catalog 用它给每条 reaction
// 标 craft 归属；事件渲染也走这条。
export function craftForWorkstationVerb(workstationId: string, verb: string): string | undefined {
  load();
  for (const slug of _slugs) {
    const spec = (_crafts as Record<string, CraftSpec>)[slug];
    if (spec.operations.some((op) => op.workstation === workstationId && op.verb === verb)) return slug;
  }
  return undefined;
}

// craft → 对应 proficiency 真值 skill_id。filter / event 渲染 / proficiency section 走这条。
export function skillIdForCraft(slug: string): string {
  return getCraftSpec(slug).skillId;
}

// 反查：skill_id → craft slug。1-1；找不到返回 undefined。
export function craftForSkillId(skillId: string): string | undefined {
  load();
  for (const slug of _slugs) {
    if ((_crafts as Record<string, CraftSpec>)[slug].skillId === skillId) return slug;
  }
  return undefined;
}

// 是否是真值表登记过的 skill_id（reaction.skill_id 对账用，见 reaction-catalog.auditCraftSkillConsistency）。
export function isKnownProficiencySkillId(skillId: string): boolean {
  return craftForSkillId(skillId) !== undefined;
}

// 给定 craft + workstation，回查该 (craft, workstation) 上的 verb。多 verb 同站（cook）时
// 返回第一个；典型用法是 fixedVerb 单一 verb 或按工作台分支的 craft 调用。
export function verbForWorkstation(slug: string, workstationId: string): string | undefined {
  const spec = getCraftSpec(slug);
  return spec.operations.find((op) => op.workstation === workstationId)?.verb;
}

// 矿场 dig 没有 inputs（沿用旧 isMiningWorkstationUse 的特殊逻辑）。
export function craftSkipsInputs(slug: string): boolean {
  return slug === "mine";
}
