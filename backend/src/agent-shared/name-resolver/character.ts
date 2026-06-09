// Character name resolver。所有"id ↔ 显示名"翻译只走这一处。
// 真值来源（按 lookup 顺序）：
//   1. i18n catalog `npc.<id>.name`（静态 NPC，由 npcs.json + locale 包驱动）
//   2. 静态 descriptor（npcs.json，作为 i18n 缺译时的 fallback）
//   3. player name cache（player_accounts 表镜像，玩家名真值）
//   4. id 本身（兜底，让 localize 链能 detect "no match"）
// LLM 边界约定见 [[feedback_llm_id_name_boundary]]。

import { allPlayerNames, getPlayerName } from "./player-name-cache.js";
import { SOURCE_LOCALE, t, type Locale } from "../../i18n/index.js";
import { buildAliasIndex, normalizeCharacterAliasKey, uniqueDisplayStrings, type AliasIndex } from "./alias-index.js";
import { characterDescriptor, characterDescriptors } from "./source-data.js";

export function characterName(id: string): string {
  return characterDisplayName(id);
}

export function characterDisplayName(id: string, locale: Locale = SOURCE_LOCALE): string {
  const i18nKey = `npc.${id}.name`;
  const i18nValue = t(i18nKey, locale);
  if (i18nValue && i18nValue !== i18nKey) {
    return i18nValue;
  }
  return characterDescriptor(id)?.name?.trim()
    || getPlayerName(id)?.trim()
    || id;
}

export function characterNameAliases(id: string): string[] {
  const descriptor = characterDescriptor(id);
  const playerName = getPlayerName(id);
  return uniqueDisplayStrings([
    characterDisplayName(id),
    descriptor?.name,
    ...(descriptor?.aliases ?? []),
    playerName,
    id,
  ]);
}

export function resolveCharacterIdByName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const key = normalizeCharacterAliasKey(value);
  if (!key) return undefined;
  const staticId = characterAliasIndex().get(key);
  if (staticId) return staticId;
  // 玩家名 cache 不大且生命周期短，直接全表线性扫。
  for (const entry of allPlayerNames()) {
    const aliases = [entry.characterId, entry.displayName];
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
