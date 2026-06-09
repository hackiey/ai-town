// pi-agent-core 的 AgentMessage 形态访问器。各 agent session 持久化/渲染会用。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { Usage } from "@mariozechner/pi-ai";
import { stringValue } from "./primitives.js";

export function userMessage(content: string): AgentMessage {
  return {
    role: "user",
    content,
    timestamp: Date.now(),
  };
}

export function isAssistantMessage(message: AgentMessage): message is Extract<AgentMessage, { role: "assistant" }> {
  return (message as { role?: unknown }).role === "assistant";
}

export function agentMessageRole(message: AgentMessage): string {
  return stringValue((message as { role?: unknown }).role) ?? "unknown";
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
