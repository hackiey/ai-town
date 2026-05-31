// Continued action queue：跟踪那些 backend 已经返回 runtime_pending、但还在 Godot 里
// 实际执行的"长任务"（plan_farm_work / use_workstation / sleep / move_to_location）。
// 等任务变 terminal 后产出 ActionNotice 给 agent 看。
//
// 状态机：
//   detached_pending → terminal_queued → terminal_delivered（删）
//
// 关键设计：
//   - 重启后从 runtime_storage 恢复未结束的 action，把"已经 terminal 但 agent 还没看到"的
//     直接 queue 成 notice
//   - 同一个 actionId 只 queue 一次 notice，consumeNotices 才标 terminal_delivered
//   - hasOpenBodyAction / firstOpenBodyAction / cancelOpenBodyAction 是给 turn-loop 决定
//     "要不要在执行新 body tool 前先取消旧的"用的
//
// 不持久化 actionNotices —— notice 是 in-memory 一次性的，未来若需 cross-restart 投递
// 再扩展 schema。

import type { AgentActionHost } from "../../agent-host/runtime.js";
import type { RuntimeStorage } from "../../agent-host/storage.js";
import type { ActionLogRecord } from "../../godot-link/protocol.js";
import { isBodyAction } from "../action-semantics/index.js";
import { arrayValue, objectValue, stringValue } from "../utils/primitives.js";

export type ActionNotice = {
  actionId: string;
  toolName: string;
  status: string;
  record: ActionLogRecord;
  reason: "continued_action_terminal";
};

type ContinuedActionState = {
  actionId: string;
  toolName: string;
  state: "detached_pending" | "terminal_queued" | "terminal_delivered";
  detachedAt: string;
  terminalAt?: string;
  terminalStatus?: string;
};

type ContinuedActionLogger = {
  warn(data: Record<string, unknown>, message: string): void;
};

export type ContinuedActionManagerOptions = {
  actions: AgentActionHost;
  storage: RuntimeStorage;
  logger?: ContinuedActionLogger;
  logContext?: Record<string, unknown>;
  onNoticeQueued?: () => void;
};

const CONTINUED_WORK_CANCEL_TIMEOUT_MS = 15_000;
const CONTINUED_ACTION_WAITER_POLL_MS = 60_000;
const CONTINUED_ACTION_STORAGE_KEY = "continued_actions:v1";
const TERMINAL_ACTION_STATUSES = new Set(["completed", "failed", "cancelled", "interrupted"]);

export class ContinuedActionManager {
  private readonly actions: AgentActionHost;
  private readonly storage: RuntimeStorage;
  private readonly logger?: ContinuedActionLogger;
  private readonly logContext: Record<string, unknown>;
  private readonly onNoticeQueued?: () => void;
  private readonly continuedActions = new Map<string, ContinuedActionState>();
  private readonly continuedActionWaiters = new Set<string>();
  private readonly actionNotices: ActionNotice[] = [];
  private restored = false;

  constructor(options: ContinuedActionManagerOptions) {
    this.actions = options.actions;
    this.storage = options.storage;
    this.logger = options.logger;
    this.logContext = options.logContext ?? {};
    this.onNoticeQueued = options.onNoticeQueued;
  }

  async restore(): Promise<void> {
    if (this.restored) return;
    this.restored = true;
    const value = await this.storage.get(CONTINUED_ACTION_STORAGE_KEY);
    const states = parseContinuedActionStates(value);
    for (const state of states) {
      if (state.state === "terminal_delivered") continue;
      this.continuedActions.set(state.actionId, state);
    }
    for (const state of this.continuedActions.values()) {
      const latest = await this.actions.get(state.actionId);
      if (!latest) {
        this.continuedActions.delete(state.actionId);
        continue;
      }
      if (TERMINAL_ACTION_STATUSES.has(latest.status)) {
        await this.queueActionNotice(state, latest);
      } else {
        this.startWaiter(state.actionId);
      }
    }
    await this.persist();
  }

  async markToolResult(toolName: string, result: unknown): Promise<void> {
    // 只跟踪 body action（耗时动作）。say_to / update_memory / view_shelf / do_nothing
    // 是瞬间完成的 fast tool，不会有真正的 detached 状态。
    if (!isBodyAction(toolName)) return;
    const resultObject = objectValue(result);
    const details = objectValue(resultObject?.details);
    const actionId = stringValue(details?.actionId);
    if (!actionId) return;
    const completion = stringValue(details?.completion);
    if (completion === "runtime_pending") {
      await this.markDetached(actionId, toolName);
      return;
    }
    this.continuedActions.delete(actionId);
    await this.persist();
  }

  async hasOpenBodyAction(): Promise<boolean> {
    await this.restore();
    return (await this.firstOpenBodyAction()) !== undefined;
  }

  async firstOpenBodyAction(): Promise<ActionLogRecord | undefined> {
    await this.restore();
    const state = await this.firstOpenState();
    return state ? await this.actions.get(state.actionId) : undefined;
  }

  async cancelOpenBodyAction(nextToolName: string): Promise<string | undefined> {
    const continued = await this.firstOpenState();
    if (!continued) return undefined;
    const latest = await this.actions.get(continued.actionId);
    if (!latest || TERMINAL_ACTION_STATUSES.has(latest.status)) {
      if (latest && TERMINAL_ACTION_STATUSES.has(latest.status)) {
        await this.queueActionNotice(continued, latest);
      } else {
        this.continuedActions.delete(continued.actionId);
        await this.persist();
      }
      return undefined;
    }

    const reason = `interrupted by tool ${nextToolName}`;
    try {
      const cancelling = await this.actions.cancel(latest, reason);
      const terminal = await this.actions.waitForTerminal(cancelling, {
        timeoutMs: CONTINUED_WORK_CANCEL_TIMEOUT_MS,
        failOnTimeout: false,
        timeoutError: "runtime_cancel_timeout",
      });
      if (!TERMINAL_ACTION_STATUSES.has(terminal.status)) {
        return `当前工作尚未停止，暂不能执行 ${nextToolName}`;
      }
      await this.queueActionNotice(continued, terminal);
      return undefined;
    } catch (error) {
      this.logger?.warn({
        ...this.logContext,
        error,
        continuedActionId: continued.actionId,
        nextToolName,
      }, "failed to cancel continued tool action");
      return `当前工作停止失败，暂不能执行 ${nextToolName}`;
    }
  }

  hasQueuedNotices(): boolean {
    return this.actionNotices.length > 0;
  }

  async consumeNotices(): Promise<ActionNotice[]> {
    if (this.actionNotices.length === 0) return [];
    const notices = this.actionNotices.splice(0, this.actionNotices.length);
    for (const notice of notices) {
      this.continuedActions.delete(notice.actionId);
    }
    await this.persist();
    return notices;
  }

  activeIntentLine(): string | undefined {
    const continued = [...this.continuedActions.values()].find((action) => action.state === "detached_pending");
    return continued ? `正在执行：${continued.toolName}（actionId=${continued.actionId}）` : undefined;
  }

  private async markDetached(actionId: string, toolName: string): Promise<void> {
    await this.restore();
    const existing = this.continuedActions.get(actionId);
    if (existing?.state === "terminal_delivered") return;
    const state: ContinuedActionState = existing ?? {
      actionId,
      toolName,
      state: "detached_pending",
      detachedAt: new Date().toISOString(),
    };
    state.toolName = toolName;
    if (state.state !== "terminal_queued") {
      state.state = "detached_pending";
    }
    this.continuedActions.set(actionId, state);
    await this.persist();

    const latest = await this.actions.get(actionId);
    if (latest && TERMINAL_ACTION_STATUSES.has(latest.status)) {
      await this.queueActionNotice(state, latest);
      return;
    }
    this.startWaiter(actionId);
  }

  private async firstOpenState(): Promise<ContinuedActionState | undefined> {
    await this.restore();
    for (const continued of this.continuedActions.values()) {
      if (continued.state === "terminal_delivered") continue;
      const latest = await this.actions.get(continued.actionId);
      if (!latest) {
        this.continuedActions.delete(continued.actionId);
        await this.persist();
        continue;
      }
      if (TERMINAL_ACTION_STATUSES.has(latest.status)) {
        await this.queueActionNotice(continued, latest);
        continue;
      }
      if (isBodyAction(latest.action)) {
        return continued;
      }
    }
    return undefined;
  }

  private startWaiter(actionId: string): void {
    if (this.continuedActionWaiters.has(actionId)) return;
    this.continuedActionWaiters.add(actionId);
    void this.waitForTerminal(actionId);
  }

  private async waitForTerminal(actionId: string): Promise<void> {
    try {
      while (this.continuedActions.has(actionId)) {
        const state = this.continuedActions.get(actionId);
        if (!state || state.state !== "detached_pending") return;
        const latest = await this.actions.get(actionId);
        if (!latest) {
          this.continuedActions.delete(actionId);
          await this.persist();
          return;
        }
        if (TERMINAL_ACTION_STATUSES.has(latest.status)) {
          await this.queueActionNotice(state, latest);
          return;
        }
        const waited = await this.actions.waitForTerminal(latest, {
          timeoutMs: CONTINUED_ACTION_WAITER_POLL_MS,
          failOnTimeout: false,
        });
        if (TERMINAL_ACTION_STATUSES.has(waited.status)) {
          await this.queueActionNotice(state, waited);
          return;
        }
        // waitForTerminal 是 max-wait budget 语义：在 POLL_MS 内反复 poll 直到 terminal 或超时；
        // 外层 while 自然按这个节奏 retry。
      }
    } catch (error) {
      this.logger?.warn({
        ...this.logContext,
        error,
        actionId,
      }, "failed while waiting for continued action terminal status");
    } finally {
      this.continuedActionWaiters.delete(actionId);
    }
  }

  private async queueActionNotice(state: ContinuedActionState, record: ActionLogRecord): Promise<void> {
    if (state.state === "terminal_delivered") return;
    const terminalAt = record.completedAt ?? record.failedAt ?? record.cancelledAt ?? new Date().toISOString();
    this.continuedActions.set(state.actionId, {
      ...state,
      state: "terminal_queued",
      terminalAt,
      terminalStatus: record.status,
    });
    if (!this.actionNotices.some((notice) => notice.actionId === state.actionId)) {
      this.actionNotices.push({
        actionId: state.actionId,
        toolName: state.toolName,
        status: record.status,
        record,
        reason: "continued_action_terminal",
      });
    }
    await this.persist();
    this.onNoticeQueued?.();
  }

  private async persist(): Promise<void> {
    const states = [...this.continuedActions.values()]
      .filter((state) => state.state !== "terminal_delivered")
      .map((state) => ({
        actionId: state.actionId,
        toolName: state.toolName,
        state: state.state,
        detachedAt: state.detachedAt,
        terminalAt: state.terminalAt ?? null,
        terminalStatus: state.terminalStatus ?? null,
      }));
    if (states.length === 0) {
      await this.storage.delete(CONTINUED_ACTION_STORAGE_KEY);
      return;
    }
    await this.storage.set(CONTINUED_ACTION_STORAGE_KEY, { actions: states });
  }
}

function parseContinuedActionStates(value: unknown): ContinuedActionState[] {
  const root = objectValue(value);
  const actions = arrayValue(root?.actions);
  const out: ContinuedActionState[] = [];
  for (const entry of actions) {
    const record = objectValue(entry);
    if (!record) continue;
    const actionId = stringValue(record.actionId);
    const toolName = stringValue(record.toolName);
    const state = stringValue(record.state);
    const detachedAt = stringValue(record.detachedAt) ?? new Date().toISOString();
    if (!actionId || !toolName || !isContinuedActionState(state)) continue;
    out.push({
      actionId,
      toolName,
      state,
      detachedAt,
      terminalAt: stringValue(record.terminalAt),
      terminalStatus: stringValue(record.terminalStatus),
    });
  }
  return out;
}

function isContinuedActionState(value: string | undefined): value is ContinuedActionState["state"] {
  return value === "detached_pending" || value === "terminal_queued" || value === "terminal_delivered";
}
