// Event filter helpers：判断"这条事件和某个角色相关吗"。
// 用于从 world_events 大池子里筛出"该 character 的相关事件"装进 prompt。
// 比 event-semantics 的 classifier 宽松：affectedIds / actor / target / global scope 都算"相关"。

import type { WorldEventRecord } from "../../godot-link/protocol.js";
import { objectValue } from "../utils/primitives.js";

const CHARACTER_CONTEXT_EVENT_TYPES = new Set(["character_context", "context_snapshot"]);

// 自身专属事件：Godot 发出时 affectedCharacterIds=[actor]，只该进 actor 自己的时间线。
// action_failed 的 data 里带 target.targetCharacterId（被说话对象），若按 target 匹配会
// 漏进对方时间线——而它的渲染器硬编码 actor 为"你"，结果变成"你想对 你 说"且真正的
// actor 被吞掉（见 action-failed.ts 的 self-only 不变式）。这里按 actor-only 收口。
const SELF_ONLY_EVENT_TYPES = new Set(["action_failed"]);

export function isCharacterContextEvent(event: WorldEventRecord): boolean {
  return CHARACTER_CONTEXT_EVENT_TYPES.has(event.type);
}

export function isEventRelevantToCharacter(event: WorldEventRecord, characterId: string): boolean {
  if (event.actorId === characterId) return true;
  // 自身专属事件只认 actor，绝不因 target/affected 字段命中而漏进他人时间线。
  if (SELF_ONLY_EVENT_TYPES.has(event.type)) return false;

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
