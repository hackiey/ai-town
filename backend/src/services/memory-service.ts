import { readFileSync } from "node:fs";
import { parseJsonColumn, type AppDb } from "../db/sqlite.js";
import { type Locale, SOURCE_LOCALE, t } from "../i18n/index.js";
import {
  COMMON_SENSE_SKILL_BOOKS,
  getCommonSense,
  readSkillBookEntries,
} from "../agent-shared/entity-descriptions/lore.js";
import {
  getBooksForSkill,
  isKnownSkillId,
} from "../agent-shared/entity-descriptions/skill-catalog.js";
import type {
  AgentMemoryKind,
  AgentMemoryRecord,
  StoredAgentMemoryKind,
} from "../agent-shared/prompt-context/types.js";
import { getProficiencyForCharacter } from "./world-state/proficiency-repo.js";
import { getRuntimeCharacter } from "./runtime-character-registry.js";

// 从 npcs.json 把 NPC 的 soul / 关系 / 技能 seed 进 runtime_storage。
// 技能 entries 真值在 data/i18n/<locale>/skills.json，没有单独注册表。
// 目标 runtimeName 按调用方传入的 resolver（一般用 worker 的 router）决定，
// 避免和运行时实际读 storage 的 runtimeName 漂移导致 NPC 看不到自己的 soul。
// Runtime 端的 prompt memory load / 工具变更在 runtimes/two-track-agent/memory.ts。

type NpcEntry = {
  name?: string;
  age?: string | number;
  occupation?: string;
  personality?: string;
  relationships?: string;
  basicInfo?: unknown;
  basic_info?: unknown;
  basics?: unknown;
  soul?: unknown;
  other?: unknown;
  starting_memory?: string[];
  starting_reflections?: unknown;
  // 手艺类技能真值。键 = skill_id（见 data/skills/skills.json），值 = 熟练度 0-100。
  // 同时决定 (a) npc_proficiency seed 数值；(b) 通过 skill-catalog.getBooksForSkill 反查
  // 注入 agent memory 的教材 entries。0 值合法 = "会但还没练，仍灌入教材"。
  proficiency?: Record<string, number>;
  // 知识类书籍（非手艺、非全员 common sense）—— wage_schedule / treasurer_duties 这种
  // "特定群体专属常识"。无熟练度概念，纯有/无。i18n entries 同样从 skills.json 教材里取。
  knowledge_books?: string[];
};

type SeededMemoryEntry = {
  id: string;
  kind: AgentMemoryKind;
  text: string;
  importance: number;
};

const SELF_KNOWLEDGE_IMPORTANCE = 0.95;
const COMMON_SENSE_IMPORTANCE = 0.9;
const SKILL_IMPORTANCE = 0.8;
const SEEDED_OTHER_IMPORTANCE = 0.7;
const ID_PREFIX = "seed:";
const MEMORY_KEY_PREFIX = "memory:";

// 调用方传入角色 → runtimeName 的解析器。
// 必须和 worker.ts 起 AgentHost 时用的同一个 AgentRuntimeRouter 保持一致，
// 否则 seed 写到一个 runtimeName，运行时读另一个，会出现 soul / 其他记忆为空的 bug。
export type SeedRuntimeResolver = (characterId: string) => string;

let _npcsCache: Map<string, NpcEntry> | undefined;

export function ensureMemoriesSeededForTown(
  db: AppDb,
  townId: string,
  resolveRuntime: SeedRuntimeResolver,
  locale: Locale = SOURCE_LOCALE,
): { seeded: number; characters: number } {
  const npcs = loadNpcEntries();
  const now = new Date().toISOString();

  let seeded = 0;
  const touchedCharacters = new Set<string>();
  for (const [characterId, entry] of npcs) {
    const runtimeName = resolveRuntime(characterId);
    const delta = seedMemoriesForCharacter(db, townId, characterId, entry, runtimeName, now, locale);
    seeded += delta;
    if (delta > 0) {
      touchedCharacters.add(characterId);
    }
  }

  return { seeded, characters: touchedCharacters.size };
}

// 把 npcs.json 之外的角色（目前：被 AI 接管的玩家）也 seed 成 NPC 等价的 memory。
// 身份/技能不来自 npcs.json，而来自共享 player 模板（soul/knowledge_books/other）
// + 玩家在 DB 里**真实积累**的 proficiency（决定 skill-book seed），name 取运行时注册名。
// 走和 NPC 同一条 seedMemoriesForCharacter 管线，写进同一份 runtime_storage。
export function seedPlayerTakeoverMemories(
  db: AppDb,
  townId: string,
  characterId: string,
  resolveRuntime: SeedRuntimeResolver,
  locale: Locale = SOURCE_LOCALE,
): { seeded: number } {
  const template = loadPlayerTemplate();
  const profRows = getProficiencyForCharacter(db, townId, characterId);
  const proficiency = profRows.length > 0
    ? Object.fromEntries(profRows.map((row) => [row.skillId, row.value]))
    : (template.proficiency ?? {});
  const name = getRuntimeCharacter(characterId)?.displayName ?? template.name;
  const entry: NpcEntry = { ...template, name, proficiency };
  const seeded = seedMemoriesForCharacter(
    db,
    townId,
    characterId,
    entry,
    resolveRuntime(characterId),
    new Date().toISOString(),
    locale,
  );
  return { seeded };
}

// 单角色 seed 核心：算出期望 memory 集合，与已有 seed 行 diff，增/改/删，返回变更条数。
// NPC（ensureMemoriesSeededForTown）与玩家接管（seedPlayerTakeoverMemories）共用。
// 三条 prepared statement 每次现 prepare——better-sqlite3 按 SQL 文本内部缓存，重复 prepare 很便宜。
function seedMemoriesForCharacter(
  db: AppDb,
  townId: string,
  characterId: string,
  entry: NpcEntry,
  runtimeName: string,
  now: string,
  locale: Locale,
): number {
  const insert = db.prepare(
    `INSERT INTO runtime_storage (runtimeName, townId, characterId, key, value, updatedAt)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(runtimeName, townId, characterId, key) DO UPDATE SET
       value = excluded.value,
       updatedAt = excluded.updatedAt`,
  );
  const remove = db.prepare(
    `DELETE FROM runtime_storage
     WHERE runtimeName = ? AND townId = ? AND characterId = ? AND key = ?`,
  );
  const selectSeeded = db.prepare(
    `SELECT key, value
     FROM runtime_storage
     WHERE runtimeName = ? AND townId = ? AND characterId = ? AND key LIKE ?`,
  );
  const bookIds = seededSkillBookIds(entry);
  const expectedMemories = [
    ...selfKnowledgeSeedEntries(characterId, entry, locale),
    ...commonSenseSeedEntries(characterId, locale),
    ...skillSeedEntries(characterId, bookIds, locale),
    ...otherSeedEntries(characterId, entry, locale),
  ];
  const expectedById = new Map(expectedMemories.map((memory) => [memory.id, memory]));
  const existingRows = selectSeeded.all(runtimeName, townId, characterId, `${MEMORY_KEY_PREFIX}${ID_PREFIX}%`) as Array<Record<string, unknown>>;
  const existingById = new Map(existingRows.map((row) => [
    runtimeMemoryFromRow(row).id,
    {
      kind: runtimeMemoryFromRow(row).kind,
      text: runtimeMemoryFromRow(row).text,
      importance: runtimeMemoryFromRow(row).importance,
    },
  ]));

  let seeded = 0;
  for (const memory of expectedMemories) {
    const existing = existingById.get(memory.id);
    if (!existing) {
      insert.run(runtimeName, townId, characterId, memoryStorageKey(memory.id), JSON.stringify(memoryValue(townId, characterId, memory, now)), now);
      seeded += 1;
      continue;
    }
    if (
      existing.kind !== memory.kind
      || normalizeMemoryText(existing.text) !== normalizeMemoryText(memory.text)
      || existing.importance !== memory.importance
    ) {
      insert.run(runtimeName, townId, characterId, memoryStorageKey(memory.id), JSON.stringify(memoryValue(townId, characterId, memory, now)), now);
      seeded += 1;
    }
  }

  for (const existingId of existingById.keys()) {
    if (expectedById.has(existingId)) {
      continue;
    }
    remove.run(runtimeName, townId, characterId, memoryStorageKey(existingId));
    seeded += 1;
  }

  return seeded;
}

export function validateMemoryBookReferences(): void {
  const npcs = loadNpcEntries();
  const errors: string[] = [];
  const checked = new Map<string, boolean>();

  for (const [characterId, entry] of npcs) {
    for (const bookId of seededSkillBookIds(entry)) {
      let ok = checked.get(bookId);
      if (ok === undefined) {
        ok = readSkillBookEntries(bookId, SOURCE_LOCALE).length > 0;
        checked.set(bookId, ok);
      }
      if (!ok) {
        errors.push(`npc "${characterId}" references unknown skill book "${bookId}"`);
      }
    }
  }

  if (errors.length > 0) {
    throw new Error(`skill books validation failed:\n  - ${errors.join("\n  - ")}`);
  }
}

function loadNpcEntries(): Map<string, NpcEntry> {
  if (_npcsCache) return _npcsCache;

  const raw = JSON.parse(
    readFileSync(new URL("../../data/town/npcs.json", import.meta.url), "utf8"),
  ) as Record<string, NpcEntry>;

  const out = new Map<string, NpcEntry>();
  for (const [characterId, entry] of Object.entries(raw)) {
    out.set(characterId, entry ?? {});
  }
  _npcsCache = out;
  return out;
}

let _playerTemplateCache: NpcEntry | undefined;

// 共享 player 模板（backend/data/town/player-template.json，与 npcs.json 同目录）。
// 只取 soul/other/knowledge_books/name 给 memory seed 用；proficiency 由调用方用
// 玩家 DB 真值覆盖。starting_inventory/wallet 是 Godot 创角 seed 用的，这里忽略。
function loadPlayerTemplate(): NpcEntry {
  if (_playerTemplateCache) return _playerTemplateCache;
  const raw = JSON.parse(
    readFileSync(new URL("../../data/town/player-template.json", import.meta.url), "utf8"),
  ) as NpcEntry;
  _playerTemplateCache = raw ?? {};
  return _playerTemplateCache;
}

function selfKnowledgeSeedEntries(
  characterId: string,
  entry: NpcEntry,
  locale: Locale,
): SeededMemoryEntry[] {
  const out: SeededMemoryEntry[] = [];
  const name = readCatalogValue(`npc.${characterId}.name`, locale) ?? readScalar(entry.name);
  const age = readScalar(entry.age);
  const occupation = readCatalogValue(`npc.${characterId}.occupation`, locale) ?? readScalar(entry.occupation);
  const personality = readCatalogValue(`npc.${characterId}.personality`, locale) ?? readScalar(entry.personality);
  const basics = basicInfoList(entry.basicInfo ?? entry.basic_info ?? entry.basics);
  const soulMemories = sentenceList(entry.soul);

  if (name) {
    out.push(seedMemory(characterId, "name", "self_knowledge", ensureSentence(t("prompt.context.memory_seed.self_knowledge.name_format", locale, { value: name })), SELF_KNOWLEDGE_IMPORTANCE));
  }
  if (age) {
    out.push(seedMemory(characterId, "age", "self_knowledge", ensureSentence(t("prompt.context.memory_seed.self_knowledge.age_format", locale, { value: age })), SELF_KNOWLEDGE_IMPORTANCE));
  }
  if (occupation) {
    out.push(seedMemory(characterId, "occupation", "self_knowledge", ensureSentence(t("prompt.context.memory_seed.self_knowledge.occupation_format", locale, { value: occupation })), SELF_KNOWLEDGE_IMPORTANCE));
  }
  if (soulMemories.length === 0 && personality) {
    out.push(seedMemory(characterId, "personality", "self_knowledge", ensureSentence(t("prompt.context.memory_seed.self_knowledge.personality_format", locale, { value: personality })), SELF_KNOWLEDGE_IMPORTANCE));
  }
  basics.forEach((value, idx) => {
    out.push(seedMemory(characterId, `basic_${idx}`, "self_knowledge", ensureSentence(t("prompt.context.memory_seed.self_knowledge.basic_info_format", locale, { value })), SELF_KNOWLEDGE_IMPORTANCE));
  });
  soulMemories.forEach((value, idx) => {
    out.push(seedMemory(characterId, `soul_${idx}`, "self_knowledge", ensureSentence(value), SELF_KNOWLEDGE_IMPORTANCE));
  });

  return out;
}

function otherSeedEntries(
  characterId: string,
  entry: NpcEntry,
  locale: Locale,
): SeededMemoryEntry[] {
  const out: SeededMemoryEntry[] = [];
  const relationships = readCatalogValue(`npc.${characterId}.relationships`, locale) ?? readScalar(entry.relationships);
  const otherMemories = sentenceList(entry.other);
  const reflectionMemories = sentenceList(entry.starting_reflections);

  if (otherMemories.length === 0 && relationships) {
    out.push(seedMemory(characterId, "relationships", "other", ensureSentence(relationships), SEEDED_OTHER_IMPORTANCE));
  }
  otherMemories.forEach((value, idx) => {
    out.push(seedMemory(characterId, `other_${idx}`, "other", ensureSentence(value), SEEDED_OTHER_IMPORTANCE));
  });
  reflectionMemories.forEach((value, idx) => {
    out.push(seedMemory(characterId, `reflection_${idx}`, "other", ensureSentence(value), SEEDED_OTHER_IMPORTANCE));
  });

  return out;
}

// NPC 应当 seed 哪些 skill book —— 两路 union：
//   1. 手艺：proficiency 的每个 key（skill_id） → data/skills/skills.json 反查 books
//   2. 知识：knowledge_books 字段直接列举（admin/管理类专属知识，无熟练度概念）
// value 数值此处不参与判定（0 也算"会但还没练"，依然 seed 教材）；DB seed 行另由 Godot 端做。
// COMMON_SENSE_SKILL_BOOKS 仍然过滤 —— 这些走全员 common sense，不在 NPC 个体 skill 段。
function seededSkillBookIds(entry: NpcEntry): string[] {
  const out = new Set<string>();
  const prof = entry.proficiency;
  if (prof && typeof prof === "object") {
    for (const skillId of Object.keys(prof)) {
      if (!isKnownSkillId(skillId)) continue;
      for (const bookId of getBooksForSkill(skillId)) {
        if (COMMON_SENSE_SKILL_BOOKS_SET.has(bookId)) continue;
        out.add(bookId);
      }
    }
  }
  const knowledge = entry.knowledge_books;
  if (Array.isArray(knowledge)) {
    for (const v of knowledge) {
      if (typeof v !== "string" || v.length === 0) continue;
      if (COMMON_SENSE_SKILL_BOOKS_SET.has(v)) continue;
      out.add(v);
    }
  }
  return [...out];
}

const COMMON_SENSE_SKILL_BOOKS_SET: Set<string> = new Set(COMMON_SENSE_SKILL_BOOKS);

// 全员通识"常识"——以前固定写在 system prompt，现改成每个角色的可变 memory（kind=common_sense），
// 这样 LLM 能用 update_memory 增删改。内容来源同 getCommonSense（i18n prompt.common_sense
// 基础条目 + COMMON_SENSE_SKILL_BOOKS 教材），与 system 渲染脱钩后 system 那段已移除。
function commonSenseSeedEntries(characterId: string, locale: Locale): SeededMemoryEntry[] {
  return getCommonSense(locale).map((text, idx) => ({
    id: `${ID_PREFIX}common_sense:${idx}_${characterId}`,
    kind: "common_sense",
    text,
    importance: COMMON_SENSE_IMPORTANCE,
  }));
}

function skillSeedEntries(
  characterId: string,
  bookIds: string[],
  locale: Locale,
): SeededMemoryEntry[] {
  const out: SeededMemoryEntry[] = [];
  for (const bookId of bookIds) {
    const entries = readSkillBookEntries(bookId, locale);
    entries.forEach((text, idx) => {
      out.push({
        id: `${ID_PREFIX}skill:${bookId}:${idx}_${characterId}`,
        kind: "skill",
        text,
        importance: SKILL_IMPORTANCE,
      });
    });
  }
  return out;
}

function seedMemory(
  characterId: string,
  key: string,
  kind: AgentMemoryKind,
  text: string,
  importance: number,
): SeededMemoryEntry {
  return {
    id: `${ID_PREFIX}${kind}:${key}_${characterId}`,
    kind,
    text,
    importance,
  };
}

function rowToAgentMemory(row: Record<string, unknown>): AgentMemoryRecord {
  return {
    id: row.id as string,
    townId: row.townId as string,
    characterId: row.characterId as string,
    kind: (typeof row.kind === "string" ? row.kind : "other") as StoredAgentMemoryKind,
    text: typeof row.text === "string" ? row.text : "",
    importance: typeof row.importance === "number" ? row.importance : Number(row.importance ?? 0),
    createdAt: row.createdAt as string,
    lastAccessedAt: typeof row.lastAccessedAt === "string" ? row.lastAccessedAt : undefined,
    sourceEventIds: parseJsonColumn<string[]>(row.sourceEventIds),
  };
}

function runtimeMemoryFromRow(row: Record<string, unknown>): AgentMemoryRecord {
  const parsed = parseJsonColumn<Record<string, unknown>>(row.value) ?? {};
  return rowToAgentMemory(parsed);
}

function memoryStorageKey(id: string): string {
  return `${MEMORY_KEY_PREFIX}${id}`;
}

function memoryValue(townId: string, characterId: string, memory: SeededMemoryEntry, now: string): AgentMemoryRecord {
  return {
    id: memory.id,
    townId,
    characterId,
    kind: memory.kind,
    text: memory.text,
    importance: memory.importance,
    createdAt: now,
    lastAccessedAt: now,
  };
}

function readCatalogValue(key: string, locale: Locale): string | undefined {
  const value = t(key, locale).trim();
  return value && value !== key ? value : undefined;
}

function readScalar(value: unknown): string | undefined {
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return undefined;
}

function basicInfoList(value: unknown): string[] {
  if (value == null) {
    return [];
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed ? [trimmed] : [];
  }
  if (Array.isArray(value)) {
    return value
      .map(readScalar)
      .filter((entry): entry is string => Boolean(entry));
  }
  if (typeof value !== "object") {
    return [];
  }
  return Object.entries(value as Record<string, unknown>)
    .map(([key, entry]) => {
      const rendered = readScalar(entry);
      return rendered ? `${key}: ${rendered}` : undefined;
    })
    .filter((entry): entry is string => Boolean(entry));
}

function sentenceList(value: unknown): string[] {
  return basicInfoList(value).map(ensureSentence);
}

function ensureSentence(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) {
    return trimmed;
  }
  return /[。！？.!?]$/.test(trimmed) ? trimmed : `${trimmed}。`;
}

function normalizeMemoryText(value: string): string {
  return value.trim();
}
