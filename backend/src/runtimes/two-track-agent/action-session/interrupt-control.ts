// 打断决策状态机 + 节流标志。把 ActionTrackSession 主体里的状态判定抽出来，
// 让 maybeDispatchInterrupt 的决策树独立可读。
//
// 三态运行机制：
//   idle:         没有 turn 在跑；新事件直接 runTurnLoop
//   tool_waiting: turn 在跑且有 tool 正在等 Godot terminal（plan_farm_work 等慢 tool）
//                 → release()：让慢 tool 立刻返回 runtime_pending 进度快照，pi-agent-core
//                   完成 toolResult message_end 持久化 → turn_end 处的 queueMicrotask(abort)
//                   触发 runCurrentTurn 退出 → outer runTurnLoop 拉队列起新 turn，
//                   下一 LLM call 拿到 fresh context 包括新事件
//   thinking:     turn 在跑但无 tool 执行中（LLM 流式输出阶段）
//                 → abortAgentWithReason()：prompt() 提前退出，半截 assistant message
//                   被 persistence 跳过；outer while 看 stopAgentLoopThisTurn 退出
//                   → runTurnLoop 拉新队列继续
//
// 节流：一个 turn 内只 fire 一次。同 turn 内后续事件直接累积进 pendingEvents，
// 自然被新 turn（或当前 turn 的下一个 LLM 迭代）随到随显随清地一并消费。turn 入口 reset。

import { INTERRUPT_WINDOW_MS } from "../../../agent-shared/game-tools/release-controller.js";

export { INTERRUPT_WINDOW_MS };

export type EventRuntimeStateProbe = {
  turnInFlight: boolean;
  activeToolExecutions: number;
};

export type EventRuntimeState = "idle" | "thinking" | "tool_waiting";

export function eventRuntimeState(probe: EventRuntimeStateProbe): EventRuntimeState {
  if (!probe.turnInFlight) return "idle";
  if (probe.activeToolExecutions > 0) return "tool_waiting";
  return "thinking";
}

export class InterruptWindow {
  private fired = false;

  reset(): void {
    this.fired = false;
  }

  markFired(): void {
    this.fired = true;
  }

  hasFiredThisTurn(): boolean {
    return this.fired;
  }
}
