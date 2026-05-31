// pi-agent-core 的 AgentMessage 形态访问器。各 agent session 持久化/渲染会用。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { Usage } from "@mariozechner/pi-ai";
import { finiteNumber, stringValue } from "./primitives.js";

export function userMessage(content: string): AgentMessage {
  return {
    role: "user",
    content,
    timestamp: Date.now(),
  };
}

export function isUserMessage(message: AgentMessage): message is Extract<AgentMessage, { role: "user" }> {
  return (message as { role?: unknown }).role === "user";
}

export function isAssistantMessage(message: AgentMessage): message is Extract<AgentMessage, { role: "assistant" }> {
  return (message as { role?: unknown }).role === "assistant";
}

export function isToolResultMessage(message: AgentMessage): boolean {
  return (message as { role?: unknown }).role === "toolResult";
}

export function agentMessageRole(message: AgentMessage): string {
  return stringValue((message as { role?: unknown }).role) ?? "unknown";
}

export function assistantMessageTimestamp(message: AgentMessage): number | undefined {
  if (!isAssistantMessage(message)) {
    return undefined;
  }
  const timestamp = (message as { timestamp?: unknown }).timestamp;
  return finiteNumber(timestamp) ? timestamp : undefined;
}

export function userMessageContentText(message: Extract<AgentMessage, { role: "user" }>): string | undefined {
  if (typeof message.content === "string") {
    return message.content;
  }
  const textPart = message.content.find((part) => part.type === "text");
  return textPart?.text;
}

export function assistantUsage(message: AgentMessage): Usage | undefined {
  if (!isAssistantMessage(message)) {
    return undefined;
  }
  return message.usage;
}

export function usageTokenCount(usage: Usage): number {
  return usage.totalTokens || usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
}

export function usageCostUsd(usage: Usage): number | undefined {
  const cost = usage.cost?.total;
  return Number.isFinite(cost) ? Math.max(0, cost) : undefined;
}

// 用于把 (user / toolResult) message 去重持久化的 key。assistant message 用 timestamp 自己 dedup。
export function persistedMessageKey(message: AgentMessage): string | undefined {
  const role = agentMessageRole(message);
  if (role !== "user" && role !== "toolResult") {
    return undefined;
  }
  const timestamp = (message as { timestamp?: unknown }).timestamp;
  if (!finiteNumber(timestamp)) {
    return undefined;
  }
  const toolCallId = stringValue((message as { toolCallId?: unknown }).toolCallId) ?? "";
  return `${role}:${timestamp}:${toolCallId}`;
}
