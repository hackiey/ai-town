// Character name resolver：静态 NPC（npcs.json）走缓存索引；运行时注册角色（player_*）走 in-memory registry 实时扫。
// LLM 边界约定见 [[feedback_llm_id_name_boundary]]。

import { allRuntimeCharacters, getRuntimeCharacter } from "../../services/runtime-character-registry.js";
import { SOURCE_LOCALE, t, type Locale } from "../../i18n/index.js";
import { buildAliasIndex, normalizeCharacterAliasKey, uniqueDisplayStrings, type AliasIndex } from "./alias-index.js";
import { characterDescriptor, characterDescriptors } from "./source-data.js";

export function characterName(id: string): string {
  return characterDisplayName(id);
}

// Lookup order: i18n catalog → static descriptor (npcs.json) → runtime registry
// (players registered at login) → the id itself. Resolver is the sole authority —
// no fallback parameter, otherwise callers can accidentally override the runtime
// registry (the bug that made players render as "player_xxx").
export function characterDisplayName(id: string, locale: Locale = SOURCE_LOCALE): string {
  const i18nKey = `npc.${id}.name`;
  const i18nValue = t(i18nKey, locale);
  if (i18nValue && i18nValue !== i18nKey) {
    return i18nValue;
  }
  return characterDescriptor(id)?.name?.trim()
    || getRuntimeCharacter(id)?.displayName?.trim()
    || id;
}

export function characterNameAliases(id: string): string[] {
  const descriptor = characterDescriptor(id);
  const runtime = getRuntimeCharacter(id);
  return uniqueDisplayStrings([
    characterDisplayName(id),
    descriptor?.name,
    ...(descriptor?.aliases ?? []),
    runtime?.displayName,
    ...(runtime?.aliases ?? []),
    id,
  ]);
}

export function resolveCharacterIdByName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const key = normalizeCharacterAliasKey(value);
  if (!key) return undefined;
  const staticId = characterAliasIndex().get(key);
  if (staticId) return staticId;
  // Runtime registry 没 cache，每次查；规模小 + 生命周期短，没必要缓存失效逻辑。
  for (const entry of allRuntimeCharacters()) {
    const aliases = [entry.characterId, entry.displayName, ...entry.aliases];
    if (aliases.some((alias) => normalizeCharacterAliasKey(alias) === key)) {
      return entry.characterId;
    }
  }
  return undefined;
}

let cachedIndex: AliasIndex | undefined;

function characterAliasIndex(): AliasIndex {
  if (cachedIndex) return cachedIndex;
  cachedIndex = buildAliasIndex(
    Object.keys(characterDescriptors()),
    characterNameAliases,
    normalizeCharacterAliasKey,
  );
  return cachedIndex;
}

