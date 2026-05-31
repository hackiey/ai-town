// Debug log 用：把 AgentMessage / 工具调用 / 任意值序列化成可读文本，
// 并自动屏蔽 API key 之类的敏感字段。所有 agent runtime 共用。

import type { AgentMessage } from "@mariozechner/pi-agent-core";
import { arrayValue, objectValue, stringValue } from "./primitives.js";
import { agentMessageRole } from "./agent-message.js";

const SENSITIVE_LOG_KEYS = new Set([
  "apiKey", "api_key",
  "authorization", "Authorization", "bearer",
  "token", "accessToken", "access_token", "refreshToken", "refresh_token",
  "password", "secret",
]);

export function sanitizeForLog(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sanitizeForLog);
  }
  if (!value || typeof value !== "object") {
    return value;
  }
  const sanitized: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value)) {
    sanitized[key] = SENSITIVE_LOG_KEYS.has(key) ? "[redacted]" : sanitizeForLog(entry);
  }
  return sanitized;
}

export type LogToolCall = {
  id?: string;
  name?: string;
  args?: unknown;
};

export function extractToolCalls(message: Record<string, unknown>): LogToolCall[] {
  const toolCalls: LogToolCall[] = [];
  for (const toolCall of [...arrayValue(message.tool_calls), ...arrayValue(message.toolCalls)]) {
    const parsed = parseToolCall(toolCall);
    if (parsed) {
      toolCalls.push(parsed);
    }
  }

  if (stringValue(message.type) === "function_call") {
    const parsed = parseToolCall(message);
    if (parsed) {
      toolCalls.push(parsed);
    }
  }

  for (const part of contentParts(message)) {
    const partObject = objectValue(part);
    if (!partObject) {
      continue;
    }
    const type = stringValue(partObject.type);
    if (type === "toolCall" || type === "tool_use" || type === "function_call" || partObject.functionCall !== undefined) {
      const parsed = parseToolCall(partObject.functionCall ?? partObject);
      if (parsed) {
        toolCalls.push(parsed);
      }
    }
  }
  return toolCalls;
}

function parseToolCall(value: unknown): LogToolCall | undefined {
  const toolCall = objectValue(value);
  if (!toolCall) {
    return undefined;
  }

  const functionObject = objectValue(toolCall.function);
  const id = stringValue(toolCall.id) ?? stringValue(toolCall.call_id) ?? stringValue(toolCall.callId);
  const name = stringValue(toolCall.name) ?? stringValue(functionObject?.name);
  const args = toolCall.arguments ?? toolCall.args ?? toolCall.input ?? functionObject?.arguments;
  if (!id && !name) {
    return undefined;
  }
  return { id, name, args };
}

function contentParts(message: Record<string, unknown>): unknown[] {
  if (Array.isArray(message.content)) {
    return message.content;
  }
  if (Array.isArray(message.parts)) {
    return message.parts;
  }
  return [];
}

export function formatContentText(value: unknown): string | undefined {
  if (typeof value === "string") {
    return value.length > 0 ? value : undefined;
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  if (Array.isArray(value)) {
    const parts = value
      .map(formatContentPartText)
      .filter((part): part is string => Boolean(part));
    return parts.length > 0 ? parts.join("\n") : undefined;
  }

  const valueObject = objectValue(value);
  if (!valueObject) {
    return undefined;
  }
  if (isImageContent(valueObject)) {
    return formatImagePlaceholder(valueObject);
  }

  const text = stringValue(valueObject.text) ?? stringValue(valueObject.content) ?? stringValue(valueObject.output);
  if (text) {
    return text;
  }
  if (valueObject.parts !== undefined) {
    return formatContentText(valueObject.parts);
  }
  if (valueObject.response !== undefined) {
    return formatValueForLog(parseJsonString(valueObject.response));
  }
  return formatValueForLog(valueObject);
}

function formatContentPartText(part: unknown): string | undefined {
  if (typeof part === "string") {
    return part;
  }
  const partObject = objectValue(part);
  if (!partObject) {
    return undefined;
  }

  const type = stringValue(partObject.type);
  if (type === "thinking" || type === "reasoning" || type === "toolCall" || type === "tool_use" || type === "tool_result" || type === "function_call" || type === "function_call_output") {
    return undefined;
  }
  if (partObject.functionCall !== undefined || partObject.functionResponse !== undefined) {
    return undefined;
  }
  if (isImageContent(partObject)) {
    return formatImagePlaceholder(partObject);
  }

  const text = stringValue(partObject.text) ?? stringValue(partObject.content) ?? stringValue(partObject.output);
  if (text) {
    return text;
  }
  if (partObject.parts !== undefined) {
    return formatContentText(partObject.parts);
  }
  return undefined;
}

function isImageContent(value: Record<string, unknown>): boolean {
  const type = stringValue(value.type);
  return type === "image" || type === "image_url" || value.image_url !== undefined || value.inlineData !== undefined;
}

function formatImagePlaceholder(value: Record<string, unknown>): string {
  const mimeType = stringValue(value.mimeType) ?? stringValue(objectValue(value.inlineData)?.mimeType);
  return mimeType ? `[image ${mimeType}]` : "[image]";
}

export function formatValueForLog(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  try {
    return JSON.stringify(sanitizeForLog(value), null, 2) ?? String(value);
  } catch {
    return String(value);
  }
}

export function parseJsonString(value: unknown): unknown {
  if (typeof value !== "string") {
    return value;
  }

  const trimmed = value.trim();
  if ((!trimmed.startsWith("{") || !trimmed.endsWith("}")) && (!trimmed.startsWith("[") || !trimmed.endsWith("]"))) {
    return value;
  }

  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return value;
  }
}

export type AgentToolSnapshot = {
  name: string;
  label?: string;
  description?: string;
  parameters?: unknown;
};

export function snapshotAgentTools(
  tools: ReadonlyArray<{ name: string; label?: string; description?: string; parameters?: unknown }>,
): AgentToolSnapshot[] {
  return tools.map((tool) => ({
    name: tool.name,
    label: tool.label,
    description: tool.description,
    parameters: tool.parameters,
  }));
}

// 用于 session 持久化的"压缩历史"摘要里把每条 message 序列化成一行。
export function serializeSessionMessage(seq: number, message: AgentMessage): string {
  const object = message as unknown as Record<string, unknown>;
  if (!object) {
    return `## ${seq} unknown\n${String(message)}`;
  }
  const role = agentMessageRole(message);
  const lines = [`## ${seq} ${role}`];
  if (role === "toolResult") {
    lines.push(`tool: ${stringValue(object.toolName) ?? "unknown"}`);
    lines.push(`isError: ${String(object.isError ?? false)}`);
  }
  const content = formatContentText(object.content);
  if (content) {
    lines.push(content);
  }
  const toolCalls = extractToolCalls(message as unknown as Record<string, unknown>);
  if (toolCalls.length > 0) {
    lines.push(`tool_calls: ${toolCalls.map((toolCall) => toolCall.name ?? "unknown").join(", ")}`);
  }
  return lines.join("\n");
}
