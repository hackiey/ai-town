// Event payload 上的"谁"和"对谁"。Wire contract 已锁：
//   - actor 走 event.actorId（top-level，BackendRuntimeClient 从 data.actorId 提升）
//   - 对话 target 走 data.targetCharacterId
//   - 感知集合走 data.affectedCharacterIds
// 详见 backend/src/godot-link/world-events.ts。

import type { WorldEventRecord } from "../../godot-link/protocol.js";
import { normalizeCharacterId } from "../name-resolver/index.js";
import { stringArray, stringValue } from "../utils/primitives.js";

export function eventActorId(event: WorldEventRecord): string | undefined {
  return event.actorId ? normalizeCharacterId(event.actorId) : undefined;
}

// Backend id 形态约定：玩家 player_<peerId>，NPC = slug。详见 src/autoload/backend_runtime_client.gd。
export function isPlayerActor(actorId: string | undefined): boolean {
  return actorId != null && actorId.startsWith("player_");
}

// 直接对话 target（say_to 的 targetCharacterId 等）。
export function directSpeechTargetIds(event: WorldEventRecord): string[] {
  const target = stringValue(event.data?.targetCharacterId);
  return target ? [normalizeCharacterId(target)] : [];
}

// 所有"可能感知到本事件"的 character id。睡眠/失明过滤在 mechanic 端完成
// （[[feedback_perception_filter_at_source]]），到这里的 affectedCharacterIds 已经只包含真能感知到的人。
export function resolveCharacterIdsForEvent(event: WorldEventRecord): string[] {
  const data = event.data ?? {};
  const ids = [
    ...stringArray(data.affectedCharacterIds),
    stringValue(data.targetCharacterId),
  ]
    .filter((id): id is string => Boolean(id))
    .map(normalizeCharacterId);
  return [...new Set(ids)];
}
