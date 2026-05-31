// Event filter helpers：判断"这条事件和某个角色相关吗"。
// 用于从 world_events 大池子里筛出"该 character 的相关事件"装进 prompt。
// 比 event-semantics 的 classifier 宽松：affectedIds / actor / target / global scope 都算"相关"。

import type { WorldEventRecord } from "../../godot-link/protocol.js";
import { objectValue } from "../utils/primitives.js";

const CHARACTER_CONTEXT_EVENT_TYPES = new Set(["character_context", "context_snapshot"]);

export function isCharacterContextEvent(event: WorldEventRecord): boolean {
  return CHARACTER_CONTEXT_EVENT_TYPES.has(event.type);
}

export function isEventRelevantToCharacter(event: WorldEventRecord, characterId: string): boolean {
  if (event.actorId === characterId) return true;

  const data = event.data ?? {};
  const target = objectValue(data.target);
  if (
    matchesCharacterId(data.characterId, characterId)
    || matchesCharacterId(data.character_id, characterId)
    || matchesCharacterId(data.targetCharacterId, characterId)
    || matchesCharacterId(data.target_character_id, characterId)
  ) return true;
  if (
    matchesCharacterId(target?.character, characterId)
    || matchesCharacterId(target?.characterId, characterId)
    || matchesCharacterId(target?.character_id, characterId)
    || matchesCharacterId(target?.targetCharacterId, characterId)
    || matchesCharacterId(target?.target_character_id, characterId)
    || matchesCharacterId(target?.to, characterId)
  ) return true;
  if (matchesCharacterIdList(data.affectedCharacterIds, characterId) || matchesCharacterIdList(data.affected_character_ids, characterId)) return true;
  if (matchesCharacterIdList(data.visibleToCharacterIds, characterId) || matchesCharacterIdList(data.visible_to_character_ids, characterId)) return true;
  return data.scope === "global" || data.global === true;
}

function matchesCharacterId(value: unknown, characterId: string): boolean {
  return typeof value === "string" && value === characterId;
}

function matchesCharacterIdList(value: unknown, characterId: string): boolean {
  return Array.isArray(value) && value.some((entry) => entry === characterId);
}
