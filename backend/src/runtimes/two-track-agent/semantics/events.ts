// Two-track action 轨的事件触发判定。
// 通用分类逻辑（classifyEventForCharacter）走 agent-shared/event-semantics，
// 这里只放 two-track 独有的两个判定：
//  - shouldTriggerActionTurn：哪些事件值得让 action 轨起一个新 turn
//    （ambient_sensory 在 action 轨里只入历史不触发，因为 action 轨没有思考延迟，
//     等下一次直接交互再统一回应即可，避免 NPC 走来走去就抢话）
//  - isSignificantForThinking：哪些事件值得让 thinking 轨提前重写 working_memory

import { ALWAYS_INTERRUPTING_EVENTS, type EventClassification } from "../../../agent-shared/event-semantics/classification.js";
import { eventActorId, isPlayerActor } from "../../../agent-shared/event-semantics/actor.js";
import { isSayToEventType } from "../../../agent-shared/event-descriptions/index.js";
import { WOKE_UP_EVENT } from "../../../godot-link/events.js";
import type { WorldEventRecord } from "../../../godot-link/protocol.js";

export {
  classifyEventForCharacter,
  isSelfAuthoredSensoryEvent,
  isSensoryEventForCharacter,
  isDirectSpeechToCharacter,
  type EventClassification,
  type EventSemanticKind,
  type EventInterruptKey,
} from "../../../agent-shared/event-semantics/classification.js";

// Action 轨在事件到来时的运行态。决定 decideAction 怎么调度：
// - idle:         turn 未跑，新事件开窗 + 起 turn
// - thinking:     turn 在跑，LLM 流式中（无 tool 正在跑），新事件可能 abort 重启
// - tool_waiting: turn 在跑，慢 tool 在等 Godot terminal，新事件可能 release（"打断不停活"）
export type EventRuntimeState = "idle" | "thinking" | "tool_waiting";

export type InterruptAction = {
  shouldAct: boolean; // false = 仅入 pendingEvents 等下次自然 turn
};

// ambient_sensory 在任何状态都不触发 action turn，只入 pendingEvents 等下次直接交互一并上下文。
// 理由：action 轨自身没有"思考延迟"概念，路人走来走去不值得 abort/release 当前活动；
// 真正需要回应时（direct_speech / hard_interrupt）才打断。
// 打断不停活：tool_waiting 也 act，慢 tool 通过 release 闭合 tool_use 后让 LLM 看到新事件。
//
// 真值表（state × kind/interruptKey）：
//   any        × ignored          → false
//   any        × hard_interrupt   → true   （woke_up / shelf_item_sold 等强制打断）
//   any        × direct_speech    → true   （被对话/被发起交易，必须响应）
//   any        × ambient_sensory  → false  （路人走过/远处说话只入历史）
export function decideAction(
  classification: EventClassification,
  _state: EventRuntimeState,
): InterruptAction {
  if (classification.kind === "ignored" || !classification.interruptKey) {
    return { shouldAct: false };
  }
  if (classification.kind === "hard_interrupt") {
    return { shouldAct: true };
  }
  if (classification.interruptKey === "direct_speech") {
    return { shouldAct: true };
  }
  // ambient_sensory: 任何状态都不触发
  return { shouldAct: false };
}

// Two-track action 轨：除 ambient_sensory 外的可感知事件都触发新 turn。
// ambient_sensory（路人走过等）仅累积进 pendingEvents 当作历史，等其它触发再批量上下文。
export function shouldTriggerActionTurn(classification: EventClassification): boolean {
  if (classification.kind === "ignored" || !classification.interruptKey) return false;
  if (classification.interruptKey === "ambient_sensory") return false;
  return true;
}

// 一次 turn 内多个 classification 折叠成一个 think reason。
// 任一 hard_interrupt → "interrupt"，否则 → "sensory"。
export function reasonForClassifications(classifications: EventClassification[]): "interrupt" | "sensory" {
  return classifications.some((c) => c.kind === "hard_interrupt") ? "interrupt" : "sensory";
}

// "先想再行动"事件：这类事件来时，runtime 会先 await 一轮 thinking 写完 working_memory，
// 再让 action 轨开始 turn。之后两条轨道恢复各自节奏。
// 选这里的标准：NPC 经历了一段较长的"意识中断"或"上下文剧变"，第一反应前需要重建认知。
const THINK_FIRST_EVENT_TYPES = new Set<string>([
  WOKE_UP_EVENT,
]);

export function isThinkFirstEvent(event: WorldEventRecord): boolean {
  return THINK_FIRST_EVENT_TYPES.has(event.type);
}

// thinking 轨是否要为这个事件提前 fire 一次思考。和 action 触发独立。
export function isSignificantForThinking(event: WorldEventRecord, characterId: string): boolean {
  if (eventActorId(event) === characterId) return false;
  if (ALWAYS_INTERRUPTING_EVENTS.has(event.type)) return true;
  if (event.type === "trade_offer") return true;
  // give：单向赠送对收件人是重要事件（拿到东西后要重写 working_memory 反映新背包），
  // actor 已被 eventActorId === characterId 闸门排除，旁观者按距离闸门归类 ambient_sensory。
  if (event.type === "give") return true;
  if (event.type === "spoken_to_directly") return true;
  if (isSayToEventType(event.type) && isPlayerActor(eventActorId(event))) return true;
  return false;
}
