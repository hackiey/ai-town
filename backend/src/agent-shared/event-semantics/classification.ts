// 事件分类：把 "X 类型 + Y 角色视角" 映射到一个通用 kind（hard_interrupt / sensory / ignored）+
// interrupt 子类型（hard / direct_speech / ambient_sensory）。
//
// 这是"语义层"——只描述事件本身，不决定该 agent 怎么反应。
// "怎么反应"是 per-agent 的 reaction 表，由 agent 自己定义。
//
// 重点：到这里的事件都假定接收方是醒着且能感知到的（mechanic 端已 filter，
// [[feedback_perception_filter_at_source]]）。
//
// woke_up 这类系统通知靠 hard 路径强制把它放进 agent 注意范围（对方可能不在场）。

import { SAY_TO_ACTION } from "../../godot-link/actions.js";
import { WOKE_UP_EVENT } from "../../godot-link/events.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import { directSpeechTargetIds, eventActorId, isPlayerActor, resolveCharacterIdsForEvent } from "./actor.js";
import { isSayToEventType } from "../event-descriptions/index.js";
import { listCraftSlugs } from "../game-tools/craft-registry.js";

export type EventSemanticKind = "hard_interrupt" | "sensory" | "ignored";
export type EventInterruptKey = "hard" | "direct_speech" | "ambient_sensory";

export type EventClassification = {
  kind: EventSemanticKind;
  direct?: boolean;
  interruptKey?: EventInterruptKey;
};

export const ALWAYS_INTERRUPTING_EVENTS = new Set<string>([
  WOKE_UP_EVENT,
]);

// 外界可感知动作进入 sensory 集合；旁观者落进 ambient_sensory（不打断，只入历史/待下次上下文）。
// 直接互动（交易、赠送、对话）在下方专用分支升级成 direct_speech。
export const SENSORY_EVENT_TYPES = new Set<string>([
  SAY_TO_ACTION,
  "move_to_location",
  "give",
  "container_put_take",
  "view_container",
  "use_item",
  "pick_up_item",
  "drop_item",
  "brewed",
  "went_to_sleep",
  "write",
  "read",
  "plan_farm_work",
  "action_failed",
  ...listCraftSlugs(),
]);

export function classifyEventForCharacter(
  event: WorldEventRecord,
  characterId: string,
): EventClassification {
  // 1. ALWAYS_INTERRUPTING：系统通知性质，hard 唤醒。
  if (ALWAYS_INTERRUPTING_EVENTS.has(event.type)) {
    return { kind: "hard_interrupt", interruptKey: "hard" };
  }

  // 1b. 交易提议事件：买家当面找卖家撮合，等同 direct_speech 语义。
  //     买家自己发出的忽略（自己已 pending tool 阻塞等回应，不需要 hard_interrupt 自己）。
  if (event.type === "trade_offer") {
    if (eventActorId(event) === characterId) {
      return { kind: "ignored" };
    }
    return { kind: "sensory", interruptKey: "direct_speech", direct: true };
  }

  if (event.type === "trade_response") {
    if (eventActorId(event) === characterId) {
      return { kind: "ignored" };
    }
    return { kind: "sensory", interruptKey: "direct_speech", direct: true };
  }

  // 1c. give：offer 工具 request:[] 触发的单向赠送。
  //     发件人（actor）忽略——其 tool response 已 sync 返回 transferred 结果，不重复 turn。
  //     收件人 direct_speech 强触发 turn（必须感知到"X 给了我 Y"，否则不知道东西哪来的）。
  //     旁观者继续往下走 ambient_sensory 路径（"give" 已加进 SENSORY_EVENT_TYPES）。
  if (event.type === "give") {
    if (eventActorId(event) === characterId) {
      return { kind: "ignored" };
    }
    const recipientId = (event.data as { recipientCharacterId?: string } | undefined)?.recipientCharacterId;
    if (recipientId && recipientId === characterId) {
      return { kind: "sensory", interruptKey: "direct_speech", direct: true };
    }
    // 旁观者：不在这里 short-circuit，下方 isSensoryEventForCharacter 走 ambient_sensory
  }

  // 2. 自己产生的 sensory（我自己说话/走动）：自始至终 ignored。
  if (isSelfAuthoredSensoryEvent(event, characterId)) {
    return { kind: "ignored" };
  }

  // 3. spoken_to_directly 的隐含 target 就是本 NPC，跳过 targetIds 检查。
  if (event.type === "spoken_to_directly") {
    return { kind: "sensory", interruptKey: "direct_speech", direct: true };
  }

  // 4. targetIds 闸门：本 NPC 不在事件感知范围内则忽略。
  const targetIds = resolveCharacterIdsForEvent(event);
  if (!targetIds.includes(characterId)) {
    return { kind: "ignored" };
  }

  // Player 喊话即便不带 targetCharacterId 也视为 direct_speech，确保 thinking 状态下能 act。
  // NPC 之间的范围喊话仍是 ambient_sensory，在 thinking 时仅入队不打断 LLM。
  if (isSayToEventType(event.type) && isPlayerActor(eventActorId(event))) {
    return { kind: "sensory", interruptKey: "direct_speech", direct: true };
  }

  if (isDirectSpeechToCharacter(event, characterId)) {
    return { kind: "sensory", interruptKey: "direct_speech", direct: true };
  }

  if (isSensoryEventForCharacter(event, characterId)) {
    return { kind: "sensory", interruptKey: "ambient_sensory", direct: false };
  }

  return { kind: "ignored" };
}

export function isSelfAuthoredSensoryEvent(event: WorldEventRecord, characterId: string): boolean {
  if (!SENSORY_EVENT_TYPES.has(event.type)) return false;
  return eventActorId(event) === characterId;
}

export function isSensoryEventForCharacter(event: WorldEventRecord, characterId: string): boolean {
  if (!SENSORY_EVENT_TYPES.has(event.type)) return false;
  const actorId = eventActorId(event);
  if (actorId && actorId === characterId) return false;
  return resolveCharacterIdsForEvent(event).includes(characterId);
}

export function isDirectSpeechToCharacter(event: WorldEventRecord, characterId: string): boolean {
  if (event.type === "spoken_to_directly") return true;
  return directSpeechTargetIds(event).includes(characterId);
}
