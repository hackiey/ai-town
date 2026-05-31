import { readFileSync } from "node:fs";

// 全局 LLM runtime 名。当前只有 two-track-agent；保留常量是给 memory-service / debug
// 路由共享命名空间用。
export const DEFAULT_AGENT_RUNTIME = "two-track-agent";

export type NpcAgentModelsConfig = {
  // two-track-agent: action 轨与 thinking 轨各自的模型 reference（"provider:model[/level]"）。
  // 两个字段都必填——two-track 启动时校验，缺一报错。
  action?: string;
  thinking?: string;
};

export type NpcRuntimeConfig = {
  agent_runtime?: string;
  agent_models?: NpcAgentModelsConfig;
};

export type AgentRuntimeRouterOptions = {
  defaultRuntime?: string;
};

export class AgentRuntimeRouter {
  private readonly routes = new Map<string, string>();
  private readonly configs = new Map<string, NpcRuntimeConfig>();
  private readonly defaultRuntime: string;

  constructor(npcs: Record<string, NpcRuntimeConfig>, options: AgentRuntimeRouterOptions = {}) {
    this.defaultRuntime = options.defaultRuntime ?? DEFAULT_AGENT_RUNTIME;
    this.reload(npcs);
  }

  reload(npcs: Record<string, NpcRuntimeConfig>): void {
    this.routes.clear();
    this.configs.clear();
    for (const [characterId, config] of Object.entries(npcs)) {
      this.routes.set(characterId, normalizeRuntimeName(config.agent_runtime) ?? this.defaultRuntime);
      this.configs.set(characterId, config);
    }
  }

  runtimeFor(characterId: string): string {
    return this.routes.get(characterId) ?? this.defaultRuntime;
  }

  npcConfigFor(characterId: string): NpcRuntimeConfig | undefined {
    return this.configs.get(characterId);
  }
}

export function loadNpcRuntimeConfig(source = new URL("../../data/town/npcs.json", import.meta.url)): Record<string, NpcRuntimeConfig> {
  const parsed = JSON.parse(readFileSync(source, "utf8")) as unknown;
  if (!isRecord(parsed)) {
    throw new Error("npcs.json must contain an object keyed by character id");
  }

  const out: Record<string, NpcRuntimeConfig> = {};
  for (const [characterId, value] of Object.entries(parsed)) {
    if (!isRecord(value)) {
      out[characterId] = {};
      continue;
    }
    out[characterId] = {
      agent_runtime: typeof value.agent_runtime === "string" ? value.agent_runtime : undefined,
      agent_models: parseAgentModelsField(value.agent_models),
    };
  }
  return out;
}

export function loadNpcRuntimeRouter(options: AgentRuntimeRouterOptions = {}): AgentRuntimeRouter {
  return new AgentRuntimeRouter(loadNpcRuntimeConfig(), options);
}

function normalizeRuntimeName(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized ? normalized : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function parseAgentModelsField(value: unknown): NpcAgentModelsConfig | undefined {
  if (!isRecord(value)) return undefined;
  const action = typeof value.action === "string" ? value.action.trim() : undefined;
  const thinking = typeof value.thinking === "string" ? value.thinking.trim() : undefined;
  if (!action && !thinking) return undefined;
  return {
    action: action || undefined,
    thinking: thinking || undefined,
  };
}
