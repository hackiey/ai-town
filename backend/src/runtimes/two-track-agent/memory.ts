import type { RuntimeStorage, RuntimeStorageValue } from "../../agent-host/storage.js";
import { createMessageId } from "../../services/ids.js";
import type {
  AgentMemoryKind,
  AgentMemoryRecord,
  PromptMemoryRecord,
  PromptMemorySections,
  StoredAgentMemoryKind,
} from "../../agent-shared/prompt-context/types.js";

export type LoadTwoTrackAgentPromptMemoriesOptions = {
  otherLimit?: number;
};

export type UpdateTwoTrackAgentMemoryInput = {
  operation: "add" | "edit" | "remove";
  kind: AgentMemoryKind;
  oldString?: string;
  newString?: string;
  now?: string;
  townId: string;
  characterId: string;
};

export type UpdateTwoTrackAgentMemoryResult = {
  operation: "add" | "edit" | "remove";
  status: "added" | "updated" | "removed" | "not_found" | "unchanged";
  kind: AgentMemoryKind;
  memoryId?: string;
  text?: string;
  previousText?: string;
};

const SELF_KNOWLEDGE_IMPORTANCE = 0.95;
const COMMON_SENSE_IMPORTANCE = 0.9;
const SKILL_IMPORTANCE = 0.8;
const DEFAULT_OTHER_IMPORTANCE = 0.5;
const DEFAULT_OTHER_MEMORY_LIMIT = 20;
const ID_PREFIX = "seed:";
const MEMORY_KEY_PREFIX = "memory:";

export async function loadTwoTrackAgentPromptMemories(
  storage: RuntimeStorage,
  options: LoadTwoTrackAgentPromptMemoriesOptions = {},
): Promise<PromptMemorySections> {
  const otherLimit = options.otherLimit ?? DEFAULT_OTHER_MEMORY_LIMIT;
  const rows = await storage.list(MEMORY_KEY_PREFIX);
  const rawMemories = rows.map((row) => runtimeMemoryFromValue(row.value));

  const seen = new Set<string>();
  const selfKnowledge: PromptMemoryRecord[] = [];
  const commonSense: PromptMemoryRecord[] = [];
  const skills: PromptMemoryRecord[] = [];
  const other: PromptMemoryRecord[] = [];

  for (const raw of rawMemories) {
    const normalized = normalizeMemoryRecord(raw);
    const dedupeKey = `${normalized.kind}\u0000${normalizeMemoryText(normalized.text)}`;
    if (!normalizeMemoryText(normalized.text) || seen.has(dedupeKey)) {
      continue;
    }
    seen.add(dedupeKey);

    if (normalized.kind === "self_knowledge") {
      selfKnowledge.push(normalized);
      continue;
    }
    if (normalized.kind === "common_sense") {
      commonSense.push(normalized);
      continue;
    }
    if (normalized.kind === "skill") {
      skills.push(normalized);
      continue;
    }
    other.push(normalized);
  }

  // common_sense 与 self/skill 一样不受 other 上限约束（全员基础知识，不该被截断）。
  const limitedOther = other.slice(0, otherLimit);
  return {
    selfKnowledge,
    commonSense,
    skills,
    other: limitedOther,
    all: [...selfKnowledge, ...commonSense, ...skills, ...limitedOther],
  };
}

export async function updateTwoTrackAgentMemory(
  storage: RuntimeStorage,
  input: UpdateTwoTrackAgentMemoryInput,
): Promise<UpdateTwoTrackAgentMemoryResult> {
  const now = input.now ?? new Date().toISOString();
  const kind = input.kind;

  if (input.operation === "add") {
    const text = requireMemoryString(input.newString);
    const existing = await findMemoryByKindAndText(storage, kind, text);
    if (existing) {
      return { operation: "add", status: "unchanged", kind, memoryId: existing.id, text: existing.text };
    }

    const memoryId = createMessageId("memory");
    await storage.set(memoryStorageKey(memoryId), memoryToStorageValue({
      id: memoryId,
      townId: input.townId,
      characterId: input.characterId,
      kind,
      text,
      importance: defaultImportance(kind),
      createdAt: now,
      lastAccessedAt: now,
    }));

    return { operation: "add", status: "added", kind, memoryId, text };
  }

  const oldText = requireMemoryString(input.oldString);
  const target = await findMemoryByKindAndText(storage, kind, oldText);
  if (!target) {
    return {
      operation: input.operation,
      status: "not_found",
      kind,
      previousText: oldText,
      text: input.operation === "remove" ? undefined : normalizeOptionalMemoryString(input.newString),
    };
  }

  if (input.operation === "remove") {
    await storage.delete(memoryStorageKey(target.id));
    return { operation: "remove", status: "removed", kind, memoryId: target.id, previousText: target.text };
  }

  const newText = requireMemoryString(input.newString);
  if (normalizeMemoryText(target.text) === normalizeMemoryText(newText) && normalizeStoredMemoryKind(target.kind, target.id) === kind) {
    return { operation: "edit", status: "unchanged", kind, memoryId: target.id, text: target.text, previousText: target.text };
  }

  await storage.set(memoryStorageKey(target.id), memoryToStorageValue({
    ...target,
    kind,
    text: newText,
    lastAccessedAt: now,
  }));

  return { operation: "edit", status: "updated", kind, memoryId: target.id, text: newText, previousText: target.text };
}

function normalizeStoredMemoryKind(kind: string, id?: string): AgentMemoryKind {
  if (kind === "self_knowledge" || kind === "common_sense" || kind === "skill" || kind === "other") {
    return kind;
  }
  if (kind === "profile") {
    return "self_knowledge";
  }
  if (kind === "long_term" && typeof id === "string" && id.startsWith(`${ID_PREFIX}`)) {
    return "skill";
  }
  return "other";
}

async function findMemoryByKindAndText(
  storage: RuntimeStorage,
  kind: AgentMemoryKind,
  text: string,
): Promise<PromptMemoryRecord | undefined> {
  const rows = await storage.list(MEMORY_KEY_PREFIX);
  const normalizedNeedle = normalizeMemoryText(text);
  for (const row of rows) {
    const memory = normalizeMemoryRecord(runtimeMemoryFromValue(row.value));
    if (memory.kind === kind && normalizeMemoryText(memory.text) === normalizedNeedle) {
      return memory;
    }
  }
  return undefined;
}

function runtimeMemoryFromValue(value: RuntimeStorageValue): AgentMemoryRecord {
  const row = objectValue(value) ?? {};
  return {
    id: stringValue(row.id) ?? "",
    townId: stringValue(row.townId) ?? "",
    characterId: stringValue(row.characterId) ?? "",
    kind: (stringValue(row.kind) ?? "other") as StoredAgentMemoryKind,
    text: stringValue(row.text) ?? "",
    importance: typeof row.importance === "number" ? row.importance : Number(row.importance ?? 0),
    createdAt: stringValue(row.createdAt) ?? "",
    lastAccessedAt: stringValue(row.lastAccessedAt),
    sourceEventIds: stringArray(row.sourceEventIds),
  };
}

function memoryToStorageValue(memory: AgentMemoryRecord): RuntimeStorageValue {
  const out: Record<string, RuntimeStorageValue> = {
    id: memory.id,
    townId: memory.townId,
    characterId: memory.characterId,
    kind: memory.kind,
    text: memory.text,
    importance: memory.importance,
    createdAt: memory.createdAt,
  };
  if (memory.lastAccessedAt) {
    out.lastAccessedAt = memory.lastAccessedAt;
  }
  if (memory.sourceEventIds) {
    out.sourceEventIds = memory.sourceEventIds;
  }
  return out;
}

function normalizeMemoryRecord(record: AgentMemoryRecord): PromptMemoryRecord {
  return {
    ...record,
    kind: normalizeStoredMemoryKind(record.kind, record.id),
  };
}

function memoryStorageKey(id: string): string {
  return `${MEMORY_KEY_PREFIX}${id}`;
}

function defaultImportance(kind: AgentMemoryKind): number {
  if (kind === "self_knowledge") return SELF_KNOWLEDGE_IMPORTANCE;
  if (kind === "common_sense") return COMMON_SENSE_IMPORTANCE;
  if (kind === "skill") return SKILL_IMPORTANCE;
  return DEFAULT_OTHER_IMPORTANCE;
}

function requireMemoryString(value: string | undefined): string {
  const normalized = normalizeOptionalMemoryString(value);
  if (!normalized) {
    throw new Error("memory text is required");
  }
  return normalized;
}

function normalizeOptionalMemoryString(value: string | undefined): string | undefined {
  const normalized = normalizeMemoryText(value ?? "");
  return normalized.length > 0 ? normalized : undefined;
}

function normalizeMemoryText(value: string): string {
  return value.trim().replace(/\s+/g, " ");
}

function objectValue(value: unknown): Record<string, RuntimeStorageValue> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, RuntimeStorageValue>
    : undefined;
}

function stringValue(value: RuntimeStorageValue | undefined): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function stringArray(value: RuntimeStorageValue | undefined): string[] | undefined {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string" && entry.length > 0) : undefined;
}
