import type { AgentToolResult, AgentToolUpdateCallback } from "@mariozechner/pi-agent-core";
import type { AgentActionHost } from "../../agent-host/runtime.js";
import type { RuntimeStorage } from "../../agent-host/storage.js";
import type { MoveToLocationTarget } from "../../godot-link/actions.js";
import type { ActionLogRecord, GameTimeSnapshot } from "../../godot-link/protocol.js";
import type { AgentKind } from "../../agents/types.js";
import type { AgentCurrentContext } from "../prompt-context/types.js";

export type ActionResultFormatter<TDetails> = (
  record: ActionLogRecord,
  context: {
    toolName: string;
    target: Record<string, unknown> | string;
    resultNote?: string;
    displayTarget?: string;
  },
) => AgentToolResult<TDetails> | Promise<AgentToolResult<TDetails>>;

export type SubmitToolActionOptions<TDetails = CharacterActionToolDetails> = {
  toolName?: string;
  resultNote?: string;
  displayTarget?: string;
  gameTime?: GameTimeSnapshot;
  signal?: AbortSignal;
  timeoutMs?: number;
  onUpdate?: AgentToolUpdateCallback<TDetails>;
  interrupts?: AgentToolInterrupts;
  formatResult?: ActionResultFormatter<TDetails>;
};

export type MoveTargetResolution = {
  target: MoveToLocationTarget;
  label: string;
};

export type MoveTargetError = {
  error: string;
};

// 打断信号：通知正在等 Godot terminal 的慢 tool 立刻返回当前进度（runtime_pending）。
// 不取消 Godot 端的 action（动作继续在游戏世界跑），LLM 这边只是闭合 tool_use。
// events 不通过 tool_result 传，统一走 user message 通道。
export type AgentToolInterruptRequest = {
  reason: string;
};

export type AgentToolInterrupts = {
  // signal: race 完成后传 AbortSignal 取消 wait，避免僵尸 waiter 堆在队列里
  // （那样 request() shift 出来的 waiter 对应的 tool 早已退出，interrupt 派不到真正 active 的 tool）
  waitForInterrupt(signal?: AbortSignal): Promise<AgentToolInterruptRequest>;
};

export type CharacterActionToolDetails = {
  actionId: string;
  status: string;
  error?: string;
  completion?: "runtime_pending" | "runtime_terminal";
  interrupted?: boolean;
  result?: Record<string, unknown>;
};

export type MoveToLocationToolDetails = CharacterActionToolDetails & {
  destination: string;
  targetType: "current_location" | "location" | "character" | "item";
  elapsedGameMinutes?: number;
  elapsedText?: string;
};

export type MemoryToolDetails = {
  operation: "add" | "edit" | "remove";
  memoryIndex?: number;
  memoryId?: string;
};

export type WorldEventToolDetails = {
  eventId: string;
};

export type DoNothingToolDetails = {
  didNothing: true;
  reason?: string;
};

export type CreateGameAgentToolsOptions = {
  townId: string;
  characterId?: string;
  agentKind?: AgentKind;
  actions: AgentActionHost;
  memoryStorage: RuntimeStorage;
  currentContext?: AgentCurrentContext;
  getCurrentContext?: () => Promise<AgentCurrentContext | undefined>;
  interrupts?: AgentToolInterrupts;
};
