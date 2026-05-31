import {
  getEnvApiKey,
  getModel,
  getModels,
  getProviders,
  type Api,
  type KnownProvider,
  type Model,
  type OpenAICompletionsCompat,
} from "@mariozechner/pi-ai";
import type { ThinkingLevel } from "@mariozechner/pi-agent-core";
import {
  parseAgentModelReference,
  type AgentConfig,
  type AgentModelReference,
  type AgentProviderDefinition,
} from "../config/env.js";

export type AgentIdentity = {
  townId: string;
  characterId: string;
};

export type AgentModelSelection = {
  reference: AgentModelReference;
  model: Model<any>;
  thinkingLevel: ThinkingLevel;
};

type ProviderDefaults = {
  api: Api;
  baseUrl: string;
  contextWindow: number;
  maxTokens: number;
  reasoning: boolean;
  compat?: OpenAICompletionsCompat;
};

const DEFAULT_CONTEXT_WINDOW = 128000;
const DEFAULT_MAX_TOKENS = 8192;

const PROVIDER_DEFAULTS: Record<string, ProviderDefaults> = {
  anthropic: {
    api: "anthropic-messages",
    baseUrl: "https://api.anthropic.com",
    contextWindow: 200000,
    maxTokens: 64000,
    reasoning: true,
  },
  cerebras: {
    api: "openai-completions",
    baseUrl: "https://api.cerebras.ai/v1",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: false,
  },
  google: {
    api: "google-generative-ai",
    baseUrl: "https://generativelanguage.googleapis.com",
    contextWindow: 1000000,
    maxTokens: 65536,
    reasoning: true,
  },
  groq: {
    api: "openai-completions",
    baseUrl: "https://api.groq.com/openai/v1",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: false,
  },
  huggingface: {
    api: "openai-completions",
    baseUrl: "https://router.huggingface.co/v1",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: false,
  },
  mistral: {
    api: "mistral-conversations",
    baseUrl: "https://api.mistral.ai",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: false,
  },
  openai: {
    api: "openai-responses",
    baseUrl: "https://api.openai.com/v1",
    contextWindow: 400000,
    maxTokens: 128000,
    reasoning: true,
  },
  openrouter: {
    api: "openai-completions",
    baseUrl: "https://openrouter.ai/api/v1",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: true,
  },
  "vercel-ai-gateway": {
    api: "openai-completions",
    baseUrl: "https://ai-gateway.vercel.sh/v1",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: true,
  },
  xai: {
    api: "openai-completions",
    baseUrl: "https://api.x.ai/v1",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: true,
  },
  zai: {
    api: "openai-completions",
    baseUrl: "https://api.z.ai/api/coding/paas/v4",
    contextWindow: 128000,
    maxTokens: 8192,
    reasoning: true,
  },
};

const EMPTY_COST = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
};

export function resolveAgentModel(config: AgentConfig, identity: AgentIdentity): AgentModelSelection {
  const reference = selectAgentModelReference(config, identity);
  const model = resolveModelReference(config, reference);
  return {
    reference,
    model,
    thinkingLevel: reference.thinkingLevel as ThinkingLevel,
  };
}

// Two-track 专用：从 NPC config 拿到的 raw `provider:model[/level]` 解析成 AgentModelSelection。
// 必须显式提供 action 和 thinking 两个；任一缺失或不在 AGENT_AVAILABLE_MODELS 都报错。
// 与 resolveAgentModel 不同：这里不读 modelOverrides / defaultModel，完全由 NPC config 决定。
export type TwoTrackAgentModelsRaw = {
  action?: string;
  thinking?: string;
};

export type TwoTrackAgentModels = {
  action: AgentModelSelection;
  thinking: AgentModelSelection;
};

export function resolveTwoTrackAgentModels(
  config: AgentConfig,
  identity: AgentIdentity,
  raw: TwoTrackAgentModelsRaw | undefined,
): TwoTrackAgentModels {
  const action = requireTwoTrackReference(config, identity, "action", raw?.action);
  const thinking = requireTwoTrackReference(config, identity, "thinking", raw?.thinking);
  return {
    action: selectionFromReference(config, action),
    thinking: selectionFromReference(config, thinking),
  };
}

function requireTwoTrackReference(
  config: AgentConfig,
  identity: AgentIdentity,
  field: "action" | "thinking",
  raw: string | undefined,
): AgentModelReference {
  if (!raw || !raw.trim()) {
    throw new Error(
      `[two-track-agent] NPC ${identity.characterId} (town ${identity.townId}) 缺少 agent_models.${field}；` +
      `请在 npcs.json 该角色下配置 "agent_models": { "action": "...", "thinking": "..." }`,
    );
  }
  const reference = parseAgentModelReference(raw);
  if (!config.availableModels.some((m) => m.raw === reference.raw)) {
    throw new Error(
      `[two-track-agent] NPC ${identity.characterId} agent_models.${field}="${reference.raw}" ` +
      `不在 AGENT_AVAILABLE_MODELS 列表里（当前可用：${config.availableModels.map((m) => m.raw).join(", ") || "（空）"}）`,
    );
  }
  return reference;
}

function selectionFromReference(config: AgentConfig, reference: AgentModelReference): AgentModelSelection {
  return {
    reference,
    model: resolveModelReference(config, reference),
    thinkingLevel: reference.thinkingLevel as ThinkingLevel,
  };
}

export function resolveAgentProviderApiKey(config: AgentConfig, provider: string): string | undefined {
  const providerDefinition = findProviderDefinition(config, provider);
  if (providerDefinition?.apiKeyEnv) {
    return process.env[providerDefinition.apiKeyEnv];
  }
  return getEnvApiKey(provider);
}

function selectAgentModelReference(config: AgentConfig, identity: AgentIdentity): AgentModelReference {
  const townScopedAgentId = `${identity.townId}:${identity.characterId}`;
  return (
    config.modelOverrides.find((override) => override.agentId === townScopedAgentId)?.model ??
    config.modelOverrides.find((override) => override.agentId === identity.characterId)?.model ??
    config.defaultModel
  );
}

function resolveModelReference(config: AgentConfig, reference: AgentModelReference): Model<any> {
  const providerDefinition = findProviderDefinition(config, reference.provider);
  const registeredModel = getRegisteredModel(reference);
  if (registeredModel) {
    return applyProviderDefinition(registeredModel, reference, providerDefinition);
  }
  return buildDynamicModel(reference, providerDefinition);
}

function getRegisteredModel(reference: AgentModelReference): Model<any> | undefined {
  return getModel(reference.provider as KnownProvider, reference.model as never) as Model<any> | undefined;
}

function getRegisteredProviderTemplate(provider: string): Model<any> | undefined {
  const models = getModels(provider as KnownProvider) as Model<any>[];
  return models[0];
}

function getRegisteredModelById(modelId: string): Model<any> | undefined {
  const normalizedModelId = normalizeModelLookupKey(modelId);
  let exactMatch: Model<any> | undefined;
  let suffixMatch: Model<any> | undefined;

  for (const provider of getProviders()) {
    for (const model of getModels(provider as KnownProvider) as Model<any>[]) {
      if (normalizeModelLookupKey(model.id) === normalizedModelId) {
        if (hasNonZeroCost(model)) {
          return model;
        }
        exactMatch ??= model;
      }
      if (normalizeModelLookupKey(lastModelIdSegment(model.id)) === normalizedModelId) {
        if (hasNonZeroCost(model) && !hasNonZeroCost(suffixMatch)) {
          suffixMatch = model;
        } else {
          suffixMatch ??= model;
        }
      }
    }
  }

  return exactMatch ?? suffixMatch;
}

function hasNonZeroCost(model: Model<any> | undefined): boolean {
  return !!model && (model.cost.input > 0 || model.cost.output > 0 || model.cost.cacheRead > 0 || model.cost.cacheWrite > 0);
}

function applyProviderDefinition(
  model: Model<any>,
  reference: AgentModelReference,
  providerDefinition?: AgentProviderDefinition,
): Model<any> {
  const api = providerDefinition?.api ?? model.api;
  const baseUrl = providerDefinition?.baseUrl ?? model.baseUrl;

  return {
    ...model,
    id: reference.model,
    name: model.name || reference.model,
    provider: reference.provider,
    api,
    baseUrl,
    reasoning: providerDefinition?.reasoning ?? model.reasoning,
    contextWindow: providerDefinition?.contextWindow ?? model.contextWindow,
    maxTokens: providerDefinition?.maxTokens ?? model.maxTokens,
    headers: mergeHeaders(model.headers, providerDefinition?.headers),
    compat: mergeOpenAICompletionsCompat(
      model.compat,
      inferOpenAICompletionsCompat(api, reference.provider, baseUrl),
      providerDefinition?.compat,
    ),
  };
}

function buildDynamicModel(reference: AgentModelReference, providerDefinition?: AgentProviderDefinition): Model<any> {
  const template = getRegisteredModelById(reference.model) ?? getRegisteredProviderTemplate(reference.provider);
  const defaults = PROVIDER_DEFAULTS[reference.provider];
  const fallbackApi = providerDefinition ? "openai-completions" : undefined;
  const api = providerDefinition?.api ?? template?.api ?? defaults?.api ?? fallbackApi;
  const baseUrl = providerDefinition?.baseUrl ?? template?.baseUrl ?? defaults?.baseUrl;

  if (!api || !baseUrl) {
    throw new Error(
      `Unknown agent provider "${reference.provider}". Add it to AGENT_CUSTOM_PROVIDERS_JSON with api and baseUrl.`,
    );
  }

  return {
    id: reference.model,
    name: reference.model,
    api,
    provider: reference.provider,
    baseUrl,
    reasoning: providerDefinition?.reasoning ?? defaults?.reasoning ?? reference.thinkingLevel !== "off",
    input: template?.input ?? ["text"],
    cost: template?.cost ?? EMPTY_COST,
    contextWindow: providerDefinition?.contextWindow ?? template?.contextWindow ?? defaults?.contextWindow ?? DEFAULT_CONTEXT_WINDOW,
    maxTokens: providerDefinition?.maxTokens ?? template?.maxTokens ?? defaults?.maxTokens ?? DEFAULT_MAX_TOKENS,
    headers: mergeHeaders(template?.headers, providerDefinition?.headers),
    compat: mergeOpenAICompletionsCompat(
      template?.compat,
      defaults?.compat,
      inferOpenAICompletionsCompat(api, reference.provider, baseUrl),
      providerDefinition?.compat,
    ),
  };
}

function normalizeModelLookupKey(value: string): string {
  return value.trim().toLowerCase();
}

function lastModelIdSegment(modelId: string): string {
  const slashIndex = modelId.lastIndexOf("/");
  return slashIndex >= 0 ? modelId.slice(slashIndex + 1) : modelId;
}

function findProviderDefinition(config: AgentConfig, provider: string): AgentProviderDefinition | undefined {
  return config.providers.find((definition) => definition.provider === provider);
}

function mergeHeaders(
  base: Record<string, string> | undefined,
  override: Record<string, string> | undefined,
): Record<string, string> | undefined {
  if (!base && !override) {
    return undefined;
  }
  return {
    ...(base ?? {}),
    ...(override ?? {}),
  };
}

function inferOpenAICompletionsCompat(
  api: Api,
  provider: string,
  baseUrl: string,
): OpenAICompletionsCompat | undefined {
  if (api !== "openai-completions") {
    return undefined;
  }

  const normalizedProvider = provider.toLowerCase();
  const normalizedBaseUrl = baseUrl.toLowerCase();
  const isDashScope =
    normalizedProvider === "dashscope" ||
    (normalizedBaseUrl.includes("dashscope") && normalizedBaseUrl.includes("aliyuncs.com"));

  if (!isDashScope) {
    return undefined;
  }

  return {
    supportsStore: false,
    supportsDeveloperRole: false,
    supportsReasoningEffort: false,
    maxTokensField: "max_tokens",
    thinkingFormat: "qwen",
    supportsStrictMode: false,
  };
}

function mergeOpenAICompletionsCompat(
  ...compatLayers: Array<OpenAICompletionsCompat | undefined>
): OpenAICompletionsCompat | undefined {
  let merged: OpenAICompletionsCompat | undefined;
  for (const compat of compatLayers) {
    if (!compat) {
      continue;
    }
    merged = {
      ...(merged ?? {}),
      ...compat,
    };
  }
  return merged;
}
