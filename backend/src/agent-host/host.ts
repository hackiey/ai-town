import type { WorldEvent } from "../godot-link/events.js";
import type { PerceptionManifestPayload } from "../godot-link/perception-manifest.js";
import type { WorldEventRecord } from "../godot-link/protocol.js";
import type { AgentCurrentContext } from "../agent-shared/prompt-context/types.js";
import type { AgentHostCatalog } from "./catalog.js";
import { IdentityAgentHostCatalog } from "./catalog.js";
import type { AgentKind } from "../agents/types.js";
import type { AgentActionHost, AgentRuntime, AgentRuntimeContext, AgentSessionStore, GameTool, RecentEventRecordsOptions } from "./runtime.js";
import type { AgentRuntimeRouter } from "./router.js";
import type { ThinkingTurnStore } from "./sqlite-thinking-turn-store.js";
import { AgentHostStateCache } from "./state-cache.js";
import type { RuntimeStorage } from "./storage.js";
import { InMemoryRuntimeStorage } from "./storage.js";

export type AgentHostOptions = {
  townId: string;
  router: AgentRuntimeRouter;
  runtimes: Record<string, AgentRuntime>;
  stateCache?: AgentHostStateCache;
  catalog?: AgentHostCatalog;
  characterEnabled?: (characterId: string) => boolean | Promise<boolean>;
  gameTools?: (ctx: { townId: string; characterId: string }) => GameTool[];
  storage?: (ctx: { runtimeName: string; townId: string; characterId: string }) => RuntimeStorage;
  actions?: (ctx: { runtimeName: string; townId: string; characterId: string }) => AgentActionHost;
  sessions?: AgentSessionStore;
  thinkingTurns?: ThinkingTurnStore;
  recentEventRecords?: (ctx: { townId: string; characterId: string }, opts?: RecentEventRecordsOptions) => Promise<WorldEventRecord[]> | WorldEventRecord[];
  characterGroups?: (ctx: { townId: string; characterId: string }) => Promise<string[]> | string[];
  currentContext?: (ctx: { townId: string; characterId: string; manifest: PerceptionManifestPayload }) => Promise<AgentCurrentContext | null> | AgentCurrentContext | null;
  setThinkingStatus?: (ctx: { runtimeName: string; townId: string; characterId: string; agentKind: AgentKind; active: boolean; reason: string; source?: string }) => Promise<void> | void;
};

export class AgentHost {
  private readonly townId: string;
  private readonly router: AgentRuntimeRouter;
  private readonly runtimes: Record<string, AgentRuntime>;
  private readonly stateCache: AgentHostStateCache;
  private readonly catalog: AgentHostCatalog;
  private readonly characterEnabled: (characterId: string) => boolean | Promise<boolean>;
  private readonly gameTools: (ctx: { townId: string; characterId: string }) => GameTool[];
  private readonly storageFactory: (ctx: { runtimeName: string; townId: string; characterId: string }) => RuntimeStorage;
  private readonly actionHostFactory: (ctx: { runtimeName: string; townId: string; characterId: string }) => AgentActionHost;
  private readonly sessionStore: AgentSessionStore;
  private readonly thinkingTurnStore: ThinkingTurnStore;
  private readonly recentEventRecordsFactory: (ctx: { townId: string; characterId: string }, opts?: RecentEventRecordsOptions) => Promise<WorldEventRecord[]> | WorldEventRecord[];
  private readonly characterGroupsFactory: (ctx: { townId: string; characterId: string }) => Promise<string[]> | string[];
  private readonly currentContextFactory: (ctx: { townId: string; characterId: string; manifest: PerceptionManifestPayload }) => Promise<AgentCurrentContext | null> | AgentCurrentContext | null;
  private readonly thinkingStatus: (ctx: { runtimeName: string; townId: string; characterId: string; agentKind: AgentKind; active: boolean; reason: string; source?: string }) => Promise<void> | void;
  private readonly contexts = new Map<string, AgentRuntimeContext>();
  private readonly fallbackStorage = new Map<string, RuntimeStorage>();

  constructor(options: AgentHostOptions) {
    this.townId = options.townId;
    this.router = options.router;
    this.runtimes = options.runtimes;
    this.stateCache = options.stateCache ?? new AgentHostStateCache();
    this.catalog = options.catalog ?? new IdentityAgentHostCatalog();
    this.characterEnabled = options.characterEnabled ?? (() => true);
    this.gameTools = options.gameTools ?? (() => []);
    this.storageFactory = options.storage ?? ((ctx) => this.defaultStorage(ctx));
    this.actionHostFactory = options.actions ?? (() => unavailableActionHost());
    this.sessionStore = options.sessions ?? unavailableSessionStore();
    this.thinkingTurnStore = options.thinkingTurns ?? unavailableThinkingTurnStore();
    this.recentEventRecordsFactory = options.recentEventRecords ?? ((ctx, opts) => this.defaultRecentEventRecords(ctx, opts));
    this.characterGroupsFactory = options.characterGroups ?? (() => []);
    this.currentContextFactory = options.currentContext ?? (() => null);
    this.thinkingStatus = options.setThinkingStatus ?? (() => undefined);
  }

  async onEvent(event: WorldEvent): Promise<void> {
    this.stateCache.pushEvent(this.townId, event);
    const characterIds = await this.enabledCharacterIdsForEvent(event);
    await Promise.all(characterIds.map((characterId) => {
      const { runtime, ctx } = this.runtimeForCharacter(characterId);
      return runtime.onEvent(event, ctx);
    }));
  }

  // Godot 主动 push 的 perception manifest 入 cache。worker 在 perception-manifest-bus 收到后调。
  // Runtime 当场用 manifest + SELECT sqlite 拼 context。
  ingestManifest(manifest: PerceptionManifestPayload): void {
    this.stateCache.putManifest(this.townId, manifest);
  }

  async detachCharacter(characterId: string): Promise<void> {
    const key = this.contextKey(characterId);
    const ctx = this.contexts.get(key);
    if (!ctx) {
      return;
    }
    const runtimeName = this.router.runtimeFor(characterId);
    const runtime = this.runtimes[runtimeName];
    this.contexts.delete(key);
    await runtime?.detach(ctx);
  }

  contextFor(characterId: string): AgentRuntimeContext {
    return this.runtimeForCharacter(characterId).ctx;
  }

  private runtimeForCharacter(characterId: string): { runtime: AgentRuntime; ctx: AgentRuntimeContext } {
    const runtimeName = this.router.runtimeFor(characterId);
    const runtime = this.runtimes[runtimeName];
    if (!runtime) {
      throw new Error(`agent runtime not registered: ${runtimeName}`);
    }

    const key = this.contextKey(characterId);
    const existing = this.contexts.get(key);
    if (existing) {
      return { runtime, ctx: existing };
    }

    const ctx = this.createRuntimeContext(runtimeName, characterId);
    this.contexts.set(key, ctx);
    runtime.attach(ctx);
    return { runtime, ctx };
  }

  private createRuntimeContext(runtimeName: string, characterId: string): AgentRuntimeContext {
    return {
      characterId,
      townId: this.townId,
      gameTools: () => this.gameTools({ townId: this.townId, characterId }),
      getManifest: () => Promise.resolve(this.stateCache.getManifest(this.townId, characterId) ?? null),
      getCurrentContext: async () => {
        const manifest = this.stateCache.getManifest(this.townId, characterId);
        if (!manifest) return null;
        return await this.currentContextFactory({ townId: this.townId, characterId, manifest });
      },
      recentEvents: (opts) => this.stateCache.recentEventsForCharacter(this.townId, characterId, opts),
      recentEventRecords: (opts) => Promise.resolve(this.recentEventRecordsFactory({ townId: this.townId, characterId }, opts)),
      characterGroups: () => Promise.resolve(this.characterGroupsFactory({ townId: this.townId, characterId })),
      resolveCharacterName: (id) => this.catalog.resolveCharacterName(id),
      resolveItemName: (id) => this.catalog.resolveItemName(id),
      resolveLocationName: (id) => this.catalog.resolveLocationName(id),
      storage: () => this.storageFactory({ runtimeName, townId: this.townId, characterId }),
      actions: () => this.actionHostFactory({ runtimeName, townId: this.townId, characterId }),
      sessions: () => this.sessionStore,
      thinkingTurns: () => this.thinkingTurnStore,
      setThinkingStatus: (active, reason, agentKind, source) => Promise.resolve(this.thinkingStatus({ runtimeName, townId: this.townId, characterId, agentKind, active, reason, source })),
    };
  }

  private characterIdsForEvent(event: WorldEvent): string[] {
    const ids = new Set<string>(event.data.affectedCharacterIds);
    if (event.actorId) {
      ids.add(event.actorId);
    }
    if (ids.size === 0 && "scope" in event.data && event.data.scope === "global") {
      for (const key of this.contexts.keys()) {
        const [townId, characterId] = key.split(":", 2);
        if (townId === this.townId && characterId) {
          ids.add(characterId);
        }
      }
    }
    return [...ids];
  }

  private async enabledCharacterIdsForEvent(event: WorldEvent): Promise<string[]> {
    const ids = this.characterIdsForEvent(event);
    const checks = await Promise.all(ids.map(async (characterId) => ({
      characterId,
      enabled: await this.characterEnabled(characterId),
    })));
    return checks.filter((check) => check.enabled).map((check) => check.characterId);
  }

  private defaultStorage(ctx: { runtimeName: string; townId: string; characterId: string }): RuntimeStorage {
    const key = `${ctx.runtimeName}:${ctx.townId}:${ctx.characterId}`;
    let storage = this.fallbackStorage.get(key);
    if (!storage) {
      storage = new InMemoryRuntimeStorage();
      this.fallbackStorage.set(key, storage);
    }
    return storage;
  }

  private defaultRecentEventRecords(ctx: { townId: string; characterId: string }, opts: RecentEventRecordsOptions = {}): WorldEventRecord[] {
    return this.stateCache.recentEventsForCharacter(ctx.townId, ctx.characterId, opts)
      .filter((event) => opts.type == null || event.type === opts.type)
      .map((event) => ({
        id: event.eventId,
        townId: ctx.townId,
        type: event.type,
        actorId: event.actorId,
        spokenText: event.spokenText,
        data: event.data,
        occurredAt: event.occurredAt,
        createdAt: event.occurredAt,
        gameTime: event.gameTime ?? event.data.gameTime,
      }));
  }

  private contextKey(characterId: string): string {
    return `${this.townId}:${characterId}`;
  }
}

function unavailableActionHost(): AgentActionHost {
  const unavailable = async () => {
    throw new Error("agent action host is not configured");
  };
  return {
    submit: unavailable,
    recordFailed: () => { throw new Error("agent action host is not configured"); },
    get: unavailable,
    recentForCharacter: unavailable,
    cancel: unavailable,
    waitForTerminal: unavailable,
    emitWorldEvent: unavailable,
  };
}

function unavailableSessionStore(): AgentSessionStore {
  const unavailable = async () => {
    throw new Error("agent session store is not configured");
  };
  return {
    ensure: unavailable,
    listMessages: unavailable,
    appendMessage: unavailable,
    updateMessage: unavailable,
    updateUsage: unavailable,
  };
}

function unavailableThinkingTurnStore(): ThinkingTurnStore {
  return {
    record: async () => {
      throw new Error("thinking turn store is not configured");
    },
  };
}
