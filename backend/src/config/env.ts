import type { OpenAICompletionsCompat } from "@mariozechner/pi-ai";

export type LogLevel = "fatal" | "error" | "warn" | "info" | "debug" | "trace" | "silent";

export type AppConfig = {
  nodeEnv: string;
  host: string;
  port: number;
  logLevel: LogLevel;
  dbPath: string;
  agentHostToken: string;
  agentHost: AgentHostConnectionConfig;
  agent: AgentConfig;
};

export type AgentHostConnectionConfig = {
  enabled: boolean;
  godotWsUrl: string;
  townId: string;
  instanceId: string;
  reconnectDelayMs: number;
};

export type AgentThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

export type AgentProviderCompat = OpenAICompletionsCompat;

export type AgentProviderDefinition = {
  provider: string;
  api?: string;
  baseUrl?: string;
  apiKeyEnv?: string;
  headers?: Record<string, string>;
  contextWindow?: number;
  maxTokens?: number;
  reasoning?: boolean;
  compat?: AgentProviderCompat;
};

export type AgentModelReference = {
  raw: string;
  provider: string;
  model: string;
  thinkingLevel: AgentThinkingLevel;
};

export type AgentModelOverride = {
  agentId: string;
  model: AgentModelReference;
};

export type AgentConfig = {
  enabled: boolean;
  providers: AgentProviderDefinition[];
  availableModels: AgentModelReference[];
  defaultModel: AgentModelReference;
  modelOverrides: AgentModelOverride[];
  maxToolCallsPerTurn: number;
};

const LOG_LEVELS = new Set<LogLevel>([
  "fatal",
  "error",
  "warn",
  "info",
  "debug",
  "trace",
  "silent",
]);

const AGENT_THINKING_LEVELS = new Set<AgentThinkingLevel>([
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
]);

const OPENAI_COMPLETIONS_THINKING_FORMATS = new Set<NonNullable<AgentProviderCompat["thinkingFormat"]>>([
  "openai",
  "openrouter",
  "zai",
  "qwen",
  "qwen-chat-template",
]);

const OPENAI_COMPLETIONS_MAX_TOKEN_FIELDS = new Set<NonNullable<AgentProviderCompat["maxTokensField"]>>([
  "max_completion_tokens",
  "max_tokens",
]);

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const nodeEnv = env.NODE_ENV ?? "development";
  // Only backend agent host and the headless Godot server should know this.
  const agentHostToken = env.AGENT_HOST_TOKEN ?? devOnlyDefault(nodeEnv, "dev-headless-only-token");
  const agent = parseAgentConfig(env);
  const agentHost = parseAgentHostConnectionConfig(env);

  return {
    nodeEnv,
    host: env.HOST ?? "0.0.0.0",
    port: parsePort(env.PORT ?? "3000"),
    logLevel: parseLogLevel(env.LOG_LEVEL ?? "info"),
    dbPath: env.DB_PATH ?? "./data/state.db",
    agentHostToken,
    agentHost,
    agent,
  };
}

function parseAgentHostConnectionConfig(env: NodeJS.ProcessEnv): AgentHostConnectionConfig {
  return {
    enabled: parseOptionalBoolean(env.AGENT_HOST_CONNECT_ENABLED) ?? true,
    godotWsUrl: env.GODOT_AGENT_WS_URL ?? "ws://127.0.0.1:3100/agent-host",
    townId: env.TOWN_ID ?? "town_001",
    instanceId: env.AGENT_HOST_INSTANCE_ID ?? "backend_agent_host",
    reconnectDelayMs: parsePositiveInteger(env.AGENT_HOST_RECONNECT_DELAY_MS ?? "3000", "AGENT_HOST_RECONNECT_DELAY_MS"),
  };
}

function parsePort(value: string): number {
  const port = Number(value);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid PORT: ${value}`);
  }
  return port;
}

function parseLogLevel(value: string): LogLevel {
  if (!LOG_LEVELS.has(value as LogLevel)) {
    throw new Error(`Invalid LOG_LEVEL: ${value}`);
  }
  return value as LogLevel;
}

function parseAgentConfig(env: NodeJS.ProcessEnv): AgentConfig {
  const providers = parseAgentProviderDefinitions(env.AGENT_CUSTOM_PROVIDERS_JSON);
  const availableModels = parseAgentModelReferences(env.AGENT_AVAILABLE_MODELS ?? env.AGENT_MODELS ?? legacyAgentModelList(env));
  const enabled = parseOptionalBoolean(env.AGENT_ENABLED) ?? availableModels.length > 0;
  if (enabled && availableModels.length === 0) {
    throw new Error("AGENT_AVAILABLE_MODELS is required when AGENT_ENABLED=true");
  }
  const defaultModel = parseDefaultAgentModel(env.AGENT_DEFAULT_MODEL, availableModels);
  const modelOverrides = parseAgentModelOverrides(env.AGENT_MODEL_OVERRIDES);
  assertModelsAreAvailable(modelOverrides.map((override) => override.model), availableModels, "AGENT_MODEL_OVERRIDES");

  return {
    enabled,
    providers,
    availableModels,
    defaultModel,
    modelOverrides,
    maxToolCallsPerTurn: parsePositiveInteger(env.AGENT_MAX_TOOL_CALLS_PER_TURN ?? "2", "AGENT_MAX_TOOL_CALLS_PER_TURN"),
  };
}

function legacyAgentModelList(env: NodeJS.ProcessEnv): string {
  const provider = (env.AGENT_PROVIDER ?? "").trim();
  const model = (env.AGENT_MODEL ?? "").trim();
  if (!provider || provider === "disabled" || provider === "none" || !model) {
    return "";
  }
  const thinkingLevel = env.AGENT_THINKING_LEVEL ? `/${env.AGENT_THINKING_LEVEL}` : "";
  return `${provider}:${model}${thinkingLevel}`;
}

function parseOptionalBoolean(value: string | undefined): boolean | undefined {
  if (value === undefined || value.trim() === "") {
    return undefined;
  }
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off", "disabled", "none"].includes(normalized)) {
    return false;
  }
  throw new Error(`Invalid AGENT_ENABLED: ${value}`);
}

function parseAgentProviderDefinitions(value: string | undefined): AgentProviderDefinition[] {
  if (!value || value.trim() === "") {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(value) as unknown;
  } catch (error) {
    throw new Error(`Invalid AGENT_CUSTOM_PROVIDERS_JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  const entries = Array.isArray(parsed)
    ? parsed
    : isPlainObject(parsed)
      ? Object.entries(parsed).map(([provider, config]) => ({
        ...(isPlainObject(config) ? config : {}),
        provider,
      }))
      : undefined;

  if (!entries) {
    throw new Error("AGENT_CUSTOM_PROVIDERS_JSON must be an array or object");
  }

  return entries.map((entry) => {
    if (typeof entry !== "object" || entry === null) {
      throw new Error("AGENT_CUSTOM_PROVIDERS_JSON entries must be objects");
    }
    const source = entry as Record<string, unknown>;
    const provider = source.provider ?? source.name;
    if (typeof provider !== "string" || provider.trim() === "") {
      throw new Error("AGENT_CUSTOM_PROVIDERS_JSON provider is required");
    }
    return {
      provider: provider.trim(),
      api: optionalString(source.api),
      baseUrl: optionalString(source.baseUrl),
      apiKeyEnv: optionalString(source.apiKeyEnv),
      headers: parseOptionalStringRecord(source.headers, "headers"),
      contextWindow: optionalPositiveInteger(source.contextWindow, "contextWindow"),
      maxTokens: optionalPositiveInteger(source.maxTokens, "maxTokens"),
      reasoning: typeof source.reasoning === "boolean" ? source.reasoning : undefined,
      compat: parseOptionalProviderCompat(source.compat),
    };
  });
}

function parseAgentModelReferences(value: string): AgentModelReference[] {
  return value
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean)
    .map(parseAgentModelReference);
}

function parseDefaultAgentModel(value: string | undefined, availableModels: AgentModelReference[]): AgentModelReference {
  if (value && value.trim()) {
    const parsed = parseAgentModelReference(value.trim());
    const found = availableModels.find((model) => model.raw === parsed.raw);
    if (!found) {
      throw new Error(`AGENT_DEFAULT_MODEL must be listed in AGENT_AVAILABLE_MODELS: ${value}`);
    }
    return found;
  }
  return availableModels[0] ?? parseAgentModelReference("disabled:disabled/off");
}

export function parseAgentModelReference(value: string): AgentModelReference {
  const separatorIndex = value.indexOf(":");
  if (separatorIndex <= 0 || separatorIndex === value.length - 1) {
    throw new Error(`Invalid agent model reference "${value}". Expected provider:model[/reasoning]`);
  }
  const provider = value.slice(0, separatorIndex).trim();
  const modelAndReasoning = value.slice(separatorIndex + 1).trim();
  const slashIndex = modelAndReasoning.lastIndexOf("/");
  const maybeReasoning = slashIndex >= 0 ? modelAndReasoning.slice(slashIndex + 1) : "";
  const hasReasoningSuffix = AGENT_THINKING_LEVELS.has(maybeReasoning as AgentThinkingLevel);
  const model = hasReasoningSuffix ? modelAndReasoning.slice(0, slashIndex) : modelAndReasoning;
  const thinkingLevel = hasReasoningSuffix ? parseAgentThinkingLevel(maybeReasoning) : "low";
  if (!provider || !model) {
    throw new Error(`Invalid agent model reference "${value}". Expected provider:model[/reasoning]`);
  }
  return {
    raw: `${provider}:${model}/${thinkingLevel}`,
    provider,
    model,
    thinkingLevel,
  };
}

function parseAgentModelOverrides(value: string | undefined): AgentModelOverride[] {
  if (!value || !value.trim()) {
    return [];
  }
  return value.split(",").map((entry) => {
    const separatorIndex = entry.indexOf("=");
    if (separatorIndex <= 0 || separatorIndex === entry.length - 1) {
      throw new Error(`Invalid AGENT_MODEL_OVERRIDES entry: ${entry}`);
    }
    return {
      agentId: entry.slice(0, separatorIndex).trim(),
      model: parseAgentModelReference(entry.slice(separatorIndex + 1).trim()),
    };
  });
}

function assertModelsAreAvailable(
  models: AgentModelReference[],
  availableModels: AgentModelReference[],
  name: string,
): void {
  for (const model of models) {
    if (!availableModels.some((availableModel) => availableModel.raw === model.raw)) {
      throw new Error(`${name} references a model that is not listed in AGENT_AVAILABLE_MODELS: ${model.raw}`);
    }
  }
}

function parseAgentThinkingLevel(value: string): AgentThinkingLevel {
  if (!AGENT_THINKING_LEVELS.has(value as AgentThinkingLevel)) {
    throw new Error(`Invalid AGENT_THINKING_LEVEL: ${value}`);
  }
  return value as AgentThinkingLevel;
}

function parsePositiveInteger(value: string, name: string): number {
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) {
    throw new Error(`Invalid ${name}: ${value}`);
  }
  return number;
}

function optionalPositiveInteger(value: unknown, name: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw new Error(`Invalid AGENT_CUSTOM_PROVIDERS_JSON ${name}: ${String(value)}`);
  }
  return value;
}

function optionalBoolean(value: unknown, name: string): boolean | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "boolean") {
    throw new Error(`AGENT_CUSTOM_PROVIDERS_JSON ${name} must be a boolean`);
  }
  return value;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

function optionalEnum<T extends string>(value: unknown, allowed: Set<T>, name: string): T | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string" || !allowed.has(value as T)) {
    throw new Error(`AGENT_CUSTOM_PROVIDERS_JSON ${name} is invalid: ${String(value)}`);
  }
  return value as T;
}

function parseOptionalStringRecord(value: unknown, name: string): Record<string, string> | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`AGENT_CUSTOM_PROVIDERS_JSON ${name} must be an object`);
  }
  const result: Record<string, string> = {};
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry !== "string") {
      throw new Error(`AGENT_CUSTOM_PROVIDERS_JSON ${name}.${key} must be a string`);
    }
    result[key] = entry;
  }
  return result;
}

function parseOptionalProviderCompat(value: unknown): AgentProviderCompat | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (!isPlainObject(value)) {
    throw new Error("AGENT_CUSTOM_PROVIDERS_JSON compat must be an object");
  }

  return {
    supportsStore: optionalBoolean(value.supportsStore, "compat.supportsStore"),
    supportsDeveloperRole: optionalBoolean(value.supportsDeveloperRole, "compat.supportsDeveloperRole"),
    supportsReasoningEffort: optionalBoolean(value.supportsReasoningEffort, "compat.supportsReasoningEffort"),
    supportsUsageInStreaming: optionalBoolean(value.supportsUsageInStreaming, "compat.supportsUsageInStreaming"),
    maxTokensField: optionalEnum(value.maxTokensField, OPENAI_COMPLETIONS_MAX_TOKEN_FIELDS, "compat.maxTokensField"),
    requiresToolResultName: optionalBoolean(value.requiresToolResultName, "compat.requiresToolResultName"),
    requiresAssistantAfterToolResult: optionalBoolean(
      value.requiresAssistantAfterToolResult,
      "compat.requiresAssistantAfterToolResult",
    ),
    requiresThinkingAsText: optionalBoolean(value.requiresThinkingAsText, "compat.requiresThinkingAsText"),
    thinkingFormat: optionalEnum(value.thinkingFormat, OPENAI_COMPLETIONS_THINKING_FORMATS, "compat.thinkingFormat"),
    supportsStrictMode: optionalBoolean(value.supportsStrictMode, "compat.supportsStrictMode"),
  };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function devOnlyDefault(nodeEnv: string, value: string): string {
  if (nodeEnv === "production") {
    throw new Error("AGENT_HOST_TOKEN is required in production");
  }
  return value;
}
