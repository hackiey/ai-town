// Action 轨每次 LLM call 都只回喂稳定的 pinned memory prefix。
// transcript 仍写入 agent_session_messages 供 debug 使用，但不再进入 LLM 消息序列。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import { userMessage } from "../../../agent-shared/utils/agent-message.js";
import type { SessionPersistence } from "./persistence.js";

export type MessagesAssembleOptions = {
  persistence: SessionPersistence;
  // 长期 Memory 的 pinned user message body（无则 undefined 由 builder 决定）。
  // 永远挂在 prefix 最前面，让它在 cache 视图上紧贴 system/tools 之后稳定坐死；
  // update_memory 改它只会让 messages 段失效，不污染 system/tools 段缓存。
  renderMemoryPin: () => string | undefined;
};

// 拼一份给 LLM 的 message 列表。
// Action 轨不再回喂历史 transcript（assistant tool_use / toolResult）——最新 user message
// （由 agent.prompt 注入）里已带近 8 游戏小时的近期事件时间线，足够快速反应做决策。
// LLM 实际看到的是：system + 置顶 Memory pin（这里返回的唯一前缀）+ 当前 user message。
// transcript 仍照常持久化（debug timeline / 后续自我行为详情捕获用），只是不进 LLM 消息序列。
export async function assembleMessagesForModel(options: MessagesAssembleOptions): Promise<AgentMessage[]> {
  await options.persistence.ensureSession();
  const memoryPin = options.renderMemoryPin();
  return memoryPin ? [userMessage(memoryPin)] : [];
}
