import type { AgentToolInterruptRequest, AgentToolInterrupts } from "./types.js";

type ReleaseWaiter = () => void;

// Release 信号控制器：通知所有"在等 Godot terminal"的慢 tool 立刻返回当前进度（runtime_pending），
// 不取消 Godot 端的 action（动作继续在游戏世界跑，detached 后由 ContinuedActionManager 监听完成）。
// "打断不停活" —— NPC 能边干边说话。
//
// 关键：release() 是一次性广播，只通知调用时已注册的 waiters，不留持久 released 状态。
// 否则 LLM 在 continue 后下的新 tool（如回应玩家的 say_to）会被旧 release 信号秒杀，
// 返回非 terminal 的 runtime_pending 记录，被 ContinuedActionManager 当 detached action，
// 完成时再排个 notice 起新 turn → 错误产生"工具调用完成"打断循环。
export class TurnReleaseController implements AgentToolInterrupts {
  private readonly waiters = new Set<ReleaseWaiter>();

  release(): void {
    const targets = [...this.waiters];
    this.waiters.clear();
    for (const waiter of targets) waiter();
  }

  waitForInterrupt(signal?: AbortSignal): Promise<AgentToolInterruptRequest> {
    return new Promise((resolve) => {
      const waiter: ReleaseWaiter = () => resolve({ reason: "released" });
      this.waiters.add(waiter);
      if (signal) {
        if (signal.aborted) {
          this.waiters.delete(waiter);
          return;
        }
        signal.addEventListener(
          "abort",
          () => {
            this.waiters.delete(waiter);
            // 不 reject —— 调用方用 race 模式，这个 promise 永远不需要 settle
          },
          { once: true },
        );
      }
    });
  }
}

// 打断有效期窗（throttling window）：第一个 act-able 事件立即 fire（不延迟），同时开窗。
// 窗口期内（自上次 fire 起 INTERRUPT_WINDOW_MS 内）的新事件，如果 NPC 还在 thinking/tool_waiting，
// 积极合并打断（abort 重启 / release）；窗口期外的事件不打断当前 turn，入 pendingEvents 排队，
// 等当前 turn 自然结束后 finally fallback 起新 turn 消费。GameClock default 7×：1 game-minute ≈ 8.57s。
export const INTERRUPT_WINDOW_MS = 8_600;
