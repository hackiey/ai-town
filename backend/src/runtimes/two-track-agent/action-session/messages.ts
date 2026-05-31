// Session 历史装配辅助：从持久化记录里拼出 LLM 看到的 message 列表，
// 含 pinned memory prefix，并对历史 user message 做窗口裁剪。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import {
  isUserMessage,
  userMessage,
  userMessageContentText,
} from "../../../agent-shared/utils/agent-message.js";
import { getActiveLocale, t } from "../../../i18n/index.js";
import type { SessionPersistence } from "./persistence.js";

const DEFAULT_AGENT_RECENT_MESSAGE_LIMIT = 60;
const DEFAULT_AGENT_FULL_USER_MESSAGE_LIMIT = 5;

export type MessagesAssembleOptions = {
  persistence: SessionPersistence;
  sessionRecentMessageLimit: number;
  sessionFullUserMessageLimit: number;
  // 长期 Memory 的 pinned user message body（无则 undefined 由 builder 决定）。
  // 永远挂在 prefix 最前面，让它在 cache 视图上紧贴 system/tools 之后稳定坐死；
  // update_memory 改它只会让 messages 段失效，不污染 system/tools 段缓存。
  renderMemoryPin: () => string | undefined;
};

// 拼一份给 LLM 的 message 列表。
// = [optional pinned memory, ...trimmed recent history]
// 历史 context-turn user message 除最新一条外，text content 都被替换成占位符——
// 当前感知/working_memory 只由最新一条 user message 承担，避免 LLM 看老 brief。
// tool_use / tool_result（toolResult role）完整保留，让 LLM 看得到自己之前做过什么。
export async function assembleMessagesForModel(options: MessagesAssembleOptions): Promise<AgentMessage[]> {
  await options.persistence.ensureSession();
  const recentLimit = Math.min(options.sessionRecentMessageLimit, DEFAULT_AGENT_RECENT_MESSAGE_LIMIT);
  // 历史压缩已删 —— 直接从 seq=0 之后拉，让 sessionRecentMessageLimit 兜底窗口。
  const recent = await options.persistence.listMessagesAfter(0, { limit: recentLimit, order: "desc" });
  const trimmed = trimHistoricalUserMessages(
    recent.reverse().map((record) => record.message),
    options.sessionFullUserMessageLimit,
  );
  const placeholdered = placeholderizeOldUserMessages(trimmed);
  const prefix: AgentMessage[] = [];
  const memoryPin = options.renderMemoryPin();
  if (memoryPin) {
    prefix.push(userMessage(memoryPin));
  }
  return [...prefix, ...placeholdered];
}

// 把历史 context-turn user message 的 text 替换成占位符；最新一条 user message 保留原文。
// pinned memory 前缀 user message 不动；toolResult / assistant 不动。
export function placeholderizeOldUserMessages(messages: AgentMessage[]): AgentMessage[] {
  let latestContextUserIndex = -1;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!isUserMessage(message)) continue;
    if (isPinnedPrefixUserMessage(message)) continue;
    latestContextUserIndex = index;
    break;
  }
  if (latestContextUserIndex < 0) return messages;
  const placeholder = t("prompt.context.label.user_message_truncated", getActiveLocale());
  return messages.map((message, index) => {
    if (index === latestContextUserIndex) return message;
    if (!isUserMessage(message)) return message;
    if (isPinnedPrefixUserMessage(message)) return message;
    return { ...message, content: placeholder } as AgentMessage;
  });
}

// 只保留最近 N 条 user context turn，老的 user / 后续 assistant / toolResult 一起丢。
// pinned memory prefix user 不算 turn，永远保留。
export function trimHistoricalUserMessages(messages: AgentMessage[], fullUserMessageLimit: number): AgentMessage[] {
  const keepLimit = Math.min(fullUserMessageLimit, DEFAULT_AGENT_FULL_USER_MESSAGE_LIMIT);
  const turnStartIndices: number[] = [];
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index];
    if (!isUserMessage(message) || isPinnedPrefixUserMessage(message)) {
      continue;
    }
    turnStartIndices.push(index);
  }
  if (turnStartIndices.length <= keepLimit) {
    return messages;
  }
  const cutoffIndex = turnStartIndices[turnStartIndices.length - keepLimit];
  const out: AgentMessage[] = [];
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index];
    if (index >= cutoffIndex) {
      out.push(message);
      continue;
    }
    if (isUserMessage(message) && isPinnedPrefixUserMessage(message)) {
      out.push(message);
    }
  }
  return out;
}

// pinned prefix user message：当前只有 pinned memory。预留 helper 形式，
// 未来想再加固定置顶段直接在这里 || 一下。
function isPinnedPrefixUserMessage(message: Extract<AgentMessage, { role: "user" }>): boolean {
  return isSessionMemoryPinnedUserMessage(message);
}

export function isSessionMemoryPinnedUserMessage(message: Extract<AgentMessage, { role: "user" }>): boolean {
  const prefix = `# ${t("prompt.context.label.memory", getActiveLocale())}`;
  return (userMessageContentText(message) ?? "").startsWith(prefix);
}

export const SESSION_RECENT_MESSAGE_LIMIT_CEILING = DEFAULT_AGENT_RECENT_MESSAGE_LIMIT;
export const SESSION_FULL_USER_MESSAGE_LIMIT_CEILING = DEFAULT_AGENT_FULL_USER_MESSAGE_LIMIT;
