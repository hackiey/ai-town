import { readFileSync } from "node:fs";
import { has, SOURCE_LOCALE } from "../i18n/index.js";

// Boot 时跑一次：校验 npcs.json 里每个 NPC 的 groups[] 引用的 group id 在 i18n catalog
// (data/i18n/<locale>/groups.json) 里都有 display name 注册。不通过就 throw 打断 boot——
// 开发期挡住 typo。
//
// 设计：
//   - group 归属真值在 npcs.json 每个 NPC 的 groups[]（项目规则 "NPC 配置真值在 npcs.json"）
//   - group "registry" 真值在 i18n catalog（display name 必填，凡是有 name 的 id 即合法）
//   - 资源归属（location / farm / workstation）的真值在 Godot 场景树 *.owner_group
//   - 运行时成员资格真值在 SQLite character_groups（首次种子由 Godot Db autoload 灌入）
//   - 已不存在 backend/data/town/groups.json
export function validateGroupDefinitions(): void {
  const npcs = loadNpcDescriptors();
  const errors: string[] = [];
  for (const [npcId, def] of Object.entries(npcs)) {
    const groups = Array.isArray(def.groups) ? def.groups : [];
    for (const groupId of groups) {
      if (typeof groupId !== "string" || !groupId.length) {
        errors.push(`npc "${npcId}" has invalid groups[] entry`);
        continue;
      }
      if (!has(`group.${groupId}.name`, SOURCE_LOCALE)) {
        errors.push(`npc "${npcId}" references unknown group "${groupId}" (no entry in data/i18n/${SOURCE_LOCALE}/groups.json)`);
      }
    }
  }
  if (errors.length > 0) {
    throw new Error(`npcs.json group membership validation failed:\n  - ${errors.join("\n  - ")}`);
  }
}

type NpcDescriptor = { groups?: unknown };
let cachedNpcs: Record<string, NpcDescriptor> | undefined;
function loadNpcDescriptors(): Record<string, NpcDescriptor> {
  if (cachedNpcs) {
    return cachedNpcs;
  }
  cachedNpcs = JSON.parse(
    readFileSync(new URL("../../data/town/npcs.json", import.meta.url), "utf8"),
  ) as Record<string, NpcDescriptor>;
  return cachedNpcs;
}
