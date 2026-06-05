// Action 语义元数据：每个 tool 名字对应一个 lane（body / speech / mental / read）+
// 剩余时间估算（可选）。Lane 用来判断"工具执行会不会打断当前持续工作"——
// say_to 只占嘴不占身体，update_memory 只占脑子，use_workstation 占身体所以会打断。
//
// 不同 agent 共用同一份 lane 表（这是游戏世界的规则，不是 agent 策略）。

import type { ActionLogRecord } from "../../godot-link/protocol.js";
import { listCraftSlugs } from "../game-tools/craft-registry.js";
import { arrayValue, numberValue, objectValue, stringValue } from "../utils/primitives.js";

export type ActionLane = "body" | "speech" | "mental" | "read";

export type ActionSemantics = {
  lane: ActionLane;
  estimateRemainingGameMinutes?: (action: ActionLogRecord) => number | undefined;
};

const ACTION_SEMANTICS: Record<string, ActionSemantics> = {
  say_to: { lane: "speech" },
  update_memory: { lane: "mental" },
  do_nothing: { lane: "mental" },
  view_container: { lane: "read" },
  // put_take 是瞬时存取（body lane，但不耗时）；instant action 不需要 estimator。
  put_take: { lane: "body" },
  // 10 个 craft action + draw_water 共享 body lane + estimator
  // （都是工作台行为，target shape 一致）。见 game-tools/craft-registry.ts。
  ...Object.fromEntries(
    listCraftSlugs().map((slug) => [
      slug,
      { lane: "body" as ActionLane, estimateRemainingGameMinutes: estimateWorkstationRemainingGameMinutes },
    ]),
  ),
  plan_farm_work: { lane: "body", estimateRemainingGameMinutes: estimateFarmWorkRemainingGameMinutes },
  sleep: { lane: "body", estimateRemainingGameMinutes: estimateSleepRemainingGameMinutes },
};

const DEFAULT_ACTION_SEMANTICS: ActionSemantics = { lane: "body" };

export function actionSemantics(actionName: string): ActionSemantics {
  return ACTION_SEMANTICS[actionName] ?? DEFAULT_ACTION_SEMANTICS;
}

export function toolActionLane(toolName: string): ActionLane {
  return actionSemantics(toolName).lane;
}

export function isBodyAction(actionName: string): boolean {
  return toolActionLane(actionName) === "body";
}

export function shouldToolInterruptContinuedWork(toolName: string): boolean {
  return isBodyAction(toolName);
}

export function estimateRemainingBodyActionGameMinutes(action: ActionLogRecord): number | undefined {
  return actionSemantics(action.action).estimateRemainingGameMinutes?.(action);
}

function estimateWorkstationRemainingGameMinutes(action: ActionLogRecord): number | undefined {
  const result = action.result ?? {};
  const remainingSeconds = numberValue(result.remaining_game_seconds ?? result.remainingGameSeconds);
  if (remainingSeconds != null) {
    return Math.max(0, remainingSeconds / 60);
  }
  const durationSeconds = numberValue(result.duration ?? result.duration_seconds ?? result.durationGameSeconds);
  const elapsedSeconds = numberValue(result.elapsed_game_seconds ?? result.elapsedGameSeconds);
  if (durationSeconds != null && elapsedSeconds != null) {
    return Math.max(0, (durationSeconds - elapsedSeconds) / 60);
  }
  if (durationSeconds != null) {
    return Math.max(0, durationSeconds / 60);
  }
  const target = objectValue(action.target);
  const workstationId = stringValue(target?.workstation_id) ?? stringValue(target?.workstationId) ?? stringValue(target?.workstation);
  const verb = stringValue(target?.verb);
  if (verb === "dig" && (workstationId === "gold_mine_workstation" || workstationId === "silver_mine_workstation")) {
    return 60;
  }
  return undefined;
}

function estimateFarmWorkRemainingGameMinutes(action: ActionLogRecord): number | undefined {
  const result = action.result ?? {};
  const remaining = recordArray(result.remaining).length > 0
    ? recordArray(result.remaining)
    : recordArray(objectValue(action.target)?.ops);
  if (remaining.length === 0) return undefined;
  return remaining.reduce((total, op) => total + farmWorkOpDurationMinutes(stringValue(op.kind)), 0);
}

function farmWorkOpDurationMinutes(kind: string | undefined): number {
  switch (kind) {
    case "plant": return 1;
    case "pest": return 5;
    case "water": return 15;
    case "harvest": return 1;
    case "uproot": return 2;
    default: return 0;
  }
}

function estimateSleepRemainingGameMinutes(action: ActionLogRecord): number | undefined {
  const target = objectValue(action.target) ?? {};
  return numberValue(target.duration_game_minutes ?? target.durationGameMinutes);
}

function recordArray(value: unknown): Record<string, unknown>[] {
  return arrayValue(value).filter(isRecordValue);
}

function isRecordValue(value: unknown): value is Record<string, unknown> {
  return Boolean(objectValue(value));
}
