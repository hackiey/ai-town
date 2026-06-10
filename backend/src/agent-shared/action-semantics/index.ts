// Action 语义元数据：每个 tool 名字对应一个 lane（body / speech / mental / read）。
// Lane 用来判断"工具执行会不会打断当前持续工作"——
// say_to 只占嘴不占身体，update_memory 只占脑子，use_workstation 占身体所以会打断。
//
// 不同 agent 共用同一份 lane 表（这是游戏世界的规则，不是 agent 策略）。

import { listCraftSlugs } from "../game-tools/craft-registry.js";

export type ActionLane = "body" | "speech" | "mental" | "read";

export type ActionSemantics = {
  lane: ActionLane;
};

const ACTION_SEMANTICS: Record<string, ActionSemantics> = {
  say_to: { lane: "speech" },
  update_memory: { lane: "mental" },
  do_nothing: { lane: "mental" },
  put: { lane: "body" },
  take: { lane: "body" },
  // craft action 都是工作台行为，共享 body lane。见 game-tools/craft-registry.ts。
  ...Object.fromEntries(
    listCraftSlugs().map((slug) => [
      slug,
      { lane: "body" as ActionLane },
    ]),
  ),
  plan_farm_work: { lane: "body" },
  sleep: { lane: "body" },
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
