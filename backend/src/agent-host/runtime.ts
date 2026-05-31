import type { ActionAck, CharacterAction } from "../godot-link/actions.js";
import type { WorldEvent } from "../godot-link/events.js";
import type { PerceptionManifestPayload } from "../godot-link/perception-manifest.js";
import type { ActionLogRecord, GameTimeSnapshot, WorldEventRecord } from "../godot-link/protocol.js";
import type { AgentKind, AgentSessionMessageRecord, AgentSessionRecord, AgentToolSnapshot } from "../agents/types.js";
import type { RuntimeStorage } from "./storage.js";
import type { ThinkingTurnStore } from "./sqlite-thinking-turn-store.js";

export type JsonSchema = Record<string, unknown>;

export type GameTool = {
  name: string;
  description: string;
  inputSchema: JsonSchema;
  handler: (input: unknown) => Promise<ActionAck>;
};

export type RecentEventRecordsOptions = {
  sinceMs?: number;
  limit?: number;
  type?: string;
};

export type SubmitGameActionInput = {
  characterId: string;
  action: CharacterAction;
  target?: Record<string, unknown>;
  reason?: string;
  priority?: number;
  expiresAt?: string;
  gameTime?: GameTimeSnapshot;
};

export type SubmitGameActionOptions = {
  preempt?: boolean;
};

export type WaitForGameActionOptions = {
  signal?: AbortSignal;
  pollIntervalMs?: number;
  timeoutMs?: number;
  failOnTimeout?: boolean;
  timeoutError?: string;
};

export type EmitWorldEventInput = {
  type: string;
  actorId?: string;
  text?: string;
  data?: Record<string, unknown>;
  occurredAt?: string;
  gameTime?: GameTimeSnapshot;
};

export interface AgentActionHost {
  submit(input: SubmitGameActionInput, options?: SubmitGameActionOptions): Promise<ActionLogRecord>;
  get(actionId: string): Promise<ActionLogRecord | undefined>;
  recentForCharacter(characterId: string, limit: number): Promise<ActionLogRecord[]>;
  cancel(action: ActionLogRecord, reason: string): Promise<ActionLogRecord>;
  waitForTerminal(action: ActionLogRecord, options?: WaitForGameActionOptions): Promise<ActionLogRecord>;
  emitWorldEvent(input: EmitWorldEventInput): Promise<WorldEventRecord>;
}

export type EnsureAgentSessionInput = {
  id: string;
  townId: string;
  characterId: string;
  agentKind: AgentKind;
};

export type AppendAgentSessionMessageInput = {
  id: string;
  sessionId: string;
  townId: string;
  characterId: string;
  agentKind: AgentKind;
  role: string;
  message: unknown;
  gameTime?: GameTimeSnapshot;
  turnReason?: string;
  toolsSnapshot?: AgentToolSnapshot[];
  llmMessages?: AgentSessionMessageRecord["message"][];
  llmSystemPrompt?: string;
  inventorySnapshot?: AgentSessionMessageRecord["inventorySnapshot"];
};

export type UpdateAgentSessionMessageInput = {
  id: string;
  message: unknown;
};

export type UpdateAgentSessionUsageInput = {
  sessionId: string;
  usage: unknown;
  tokenCount: number;
  costUsd?: number;
};

export interface AgentSessionStore {
  ensure(input: EnsureAgentSessionInput): Promise<AgentSessionRecord>;
  listMessages(sessionId: string, opts?: { afterSeq?: number; limit?: number; order?: "asc" | "desc" }): Promise<AgentSessionMessageRecord[]>;
  appendMessage(input: AppendAgentSessionMessageInput): Promise<AgentSessionRecord>;
  updateMessage(input: UpdateAgentSessionMessageInput): Promise<void>;
  updateUsage(input: UpdateAgentSessionUsageInput): Promise<AgentSessionRecord>;
}

export interface AgentRuntime {
  readonly name: string;
  attach(ctx: AgentRuntimeContext): void;
  onEvent(event: WorldEvent, ctx: AgentRuntimeContext): Promise<void>;
  detach(ctx: AgentRuntimeContext): Promise<void>;
}

export interface AgentRuntimeContext {
  readonly characterId: string;
  readonly townId: string;

  gameTools(): GameTool[];
  // Manifest = "我感知到的实体 id 集合"。Runtime 自己一般不直接调；通过 getCurrentContext 拿
  // 已拼好的 AgentCurrentContext 更方便。
  getManifest(): Promise<PerceptionManifestPayload | null>;
  // Worker 端预 wire 为 manifest+repo 拼出来的 AgentCurrentContext。返回 null = manifest 未到。
  getCurrentContext(): Promise<import("../agent-shared/prompt-context/types.js").AgentCurrentContext | null>;
  recentEvents(opts?: { sinceMs?: number; limit?: number }): WorldEvent[];
  recentEventRecords(opts?: RecentEventRecordsOptions): Promise<WorldEventRecord[]>;
  characterGroups(): Promise<string[]>;

  resolveCharacterName(id: string): string;
  resolveItemName(id: string): string;
  resolveLocationName(id: string): string;

  storage(): RuntimeStorage;
  actions(): AgentActionHost;
  sessions(): AgentSessionStore;
  thinkingTurns(): ThinkingTurnStore;
  setThinkingStatus(active: boolean, reason: string, agentKind: AgentKind): Promise<void>;
}

export type AgentRuntimeFactory = (params: { name: string }) => AgentRuntime;
