// Reaction 元数据 catalog —— lua = 单一真值。
// Godot 在 BackendRuntimeClient 握手后立刻通过 `runtime.reaction_catalog_sync` 把
// data/mechanics/crafting.lua 的 list_reaction_metadata 结果发过来。本模块只缓存 +
// 提供查询，从不修改。
//
// 用途：
//   1. tool schema 的 sub_option enum description 注入难度数字（"axe_head（难度 55）"）
//   2. 失败 event 渲染时按 reaction id 回查难度
//   3. lua skill_id 与 craft-registry 的 axis→skillId 映射对账
//
// 单一全局缓存（不分 town）：lua 文件全局共享；多 town 假场景下也是同一份 mechanics。

import {
  craftForWorkstationVerb,
  getCraftSpec,
  listProficiencyCrafts,
  type CraftSlug,
} from "../../agent-shared/game-tools/craft-registry.js";
import type { ReactionMetaPayload } from "../../godot-link/protocol.js";

// 对外暴露的轻量 view（camelCase；wire 上是 snake_case）。
export type ReactionMeta = {
  id: string;
  skillId: string;
  difficulty: number;
  workstation: string;
  verb: string;
  subOption: string;
};

let _catalog: ReactionMeta[] = [];
let _byId: Map<string, ReactionMeta> = new Map();
let _byCraft: Map<CraftSlug, ReactionMeta[]> = new Map();
let _bySkill: Map<string, ReactionMeta[]> = new Map();
let _received = false;

// Godot 握手后调用。每次重连都重设 —— catalog 是源完全替换，不做差分。
export function setReactionCatalog(rows: ReactionMetaPayload[]): void {
  const normalized: ReactionMeta[] = rows
    .map((row) => ({
      id: String(row.id ?? ""),
      skillId: String(row.skill_id ?? ""),
      difficulty: Number(row.difficulty ?? 0),
      workstation: String(row.workstation ?? ""),
      verb: String(row.verb ?? ""),
      subOption: String(row.sub_option ?? ""),
    }))
    .filter((r) => r.id.length > 0);

  _catalog = normalized;
  _byId = new Map(normalized.map((r) => [r.id, r]));

  _byCraft = new Map();
  _bySkill = new Map();
  for (const r of normalized) {
    const axis = craftForWorkstationVerb(r.workstation, r.verb);
    if (axis) {
      const list = _byCraft.get(axis) ?? [];
      list.push(r);
      _byCraft.set(axis, list);
    }
    if (r.skillId) {
      const list = _bySkill.get(r.skillId) ?? [];
      list.push(r);
      _bySkill.set(r.skillId, list);
    }
  }
  _received = true;
}

// 是否已收到过一次 dump。schema 注入端可据此降级渲染（catalog 未就绪 = 不注入难度）。
export function isReactionCatalogReady(): boolean {
  return _received;
}

export function getAllReactions(): ReactionMeta[] {
  return _catalog;
}

export function getReactionById(id: string): ReactionMeta | undefined {
  return _byId.get(id);
}

// axis = TS 端 craft-registry 的 slug（mine / cook / smith / ...）。
// 通过反查 craft-registry.craftForWorkstationVerb 拿到归属，避免 axis ↔ lua
// (workstation, verb) 映射出现第二份镜像。
export function getReactionsForCraft(axis: CraftSlug): ReactionMeta[] {
  return _byCraft.get(axis) ?? [];
}

// skillId = data/skills/skills.json 的键，与 lua reaction.skill_id 同名。
export function getReactionsForSkill(skillId: string): ReactionMeta[] {
  return _bySkill.get(skillId) ?? [];
}

// 启动期 / 调试用：检查 craft-registry.[axis].skillId 是否与该 axis 下
// 所有 reaction 实际的 skill_id 一致。返回所有不一致的报告，调用方决定 log 还是 throw。
// （Phase A 已经在 lua 端做了"必须有 skill_id"的硬校验；这里是 axis ↔ skill_id 的二次对账。）
export type CraftSkillConsistencyIssue = {
  craft: CraftSlug;
  expectedSkillId: string;
  actualSkillId: string;
  reactionId: string;
};

export function auditCraftSkillConsistency(): CraftSkillConsistencyIssue[] {
  const issues: CraftSkillConsistencyIssue[] = [];
  for (const craft of listProficiencyCrafts()) {
    const expected = getCraftSpec(craft).skillId;
    for (const r of getReactionsForCraft(craft)) {
      if (r.skillId !== expected) {
        issues.push({ craft, expectedSkillId: expected, actualSkillId: r.skillId, reactionId: r.id });
      }
    }
  }
  return issues;
}
