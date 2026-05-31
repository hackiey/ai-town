import type { ActionAckStatus, CharacterAction } from "./actions.js";
import type { PerceptionManifestPayload } from "./perception-manifest.js";

export type TownId = string;

export const PROTOCOL_VERSION = "1.0.0";
export const PROTOCOL_MAJOR_VERSION = 1;

export type GameTimeSnapshot = {
  totalGameMinutes?: number;
  totalGameHours?: number;
  day?: number;
  hour?: number;
  minute?: number;
  year?: number;
  dayOfYear?: number;
  eraName?: string;
};

export type MessageEnvelope<TPayload = unknown, TType extends string = string> = {
  id: string;
  seq?: number;
  type: TType;
  townId: TownId;
  createdAt: string;
  version: string;
  payload: TPayload;
};

export function protocolMajor(version: string): number | null {
  const [major] = version.split(".");
  const parsed = Number(major);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

export function isCompatibleProtocolVersion(version: string): boolean {
  return protocolMajor(version) === PROTOCOL_MAJOR_VERSION;
}

export function assertCompatibleEnvelopeVersion(envelope: { version?: unknown }): void {
  if (typeof envelope.version !== "string" || !isCompatibleProtocolVersion(envelope.version)) {
    throw new Error(`unsupported protocol version: ${String(envelope.version)}`);
  }
}

export type RuntimeHelloPayload = {
  instanceId: string;
  serverTime: string;
};

export type RuntimeHeartbeatPayload = {
  instanceId?: string;
  onlinePlayers?: number;
  characterCount?: number;
  gameTime?: GameTimeSnapshot;
};

export type CharacterStatusPayload = {
  characterId: string;
  status: "online" | "offline" | "disabled" | "thinking";
  active?: boolean;
  reason?: string;
  agentKind?: "npc" | "player" | "god";
};

export type ActionAckPayload = {
  ackSeq: number;
  actionId?: string;
  messageId?: string;
  status?: ActionAckStatus;
  error?: string;
  gameTime?: GameTimeSnapshot;
  result?: Record<string, unknown>;
};

export type ActionCancelPayload = {
  actionId: string;
  characterId: string;
  reason: string;
  interruptEventId?: string;
  requestedAt: string;
};

export type ActionRequestPayload = {
  characterId: string;
  action: CharacterAction;
  target?: Record<string, unknown>;
  reason?: string;
  priority?: number;
  expiresAt?: string;
  preempt?: boolean;
  gameTime?: GameTimeSnapshot;
};

export type PlayerCommandPayload = {
  playerId: string;
  characterId?: string;
  text: string;
  commandId?: string;
  issuedAt?: string;
  gameTime?: GameTimeSnapshot;
};

export type WorldEventPayload = {
  eventId?: string;
  actorId?: string;
  type: string;
  // Spoken/typed words verbatim. Set only by say_to / broadcast_speech /
  // player_command. Other event types leave this absent — backend renderers
  // produce prose from event.data.
  spokenText?: string;
  data?: Record<string, unknown>;
  occurredAt?: string;
  gameTime?: GameTimeSnapshot;
  // 事件目标（actor + affected）各自事件时刻的完整 perception manifest，按 characterId 索引。
  // 随同一条 world event 下发，worker 在触发 turn 前写入缓存，避免感知 stale。原始 dict，
  // 由 normalizeManifestPayload 归一。详见 godot-message-handler.handleWorldEvent。
  perception?: Record<string, unknown>;
};

export type ActionSubmission = {
  id: string;
  townId: TownId;
  characterId: string;
  action: CharacterAction;
  target?: Record<string, unknown> | string;
  reason?: string;
  priority: number;
  expiresAt?: string;
  createdAt: string;
  gameTime?: GameTimeSnapshot;
};

export type ActionLogStatus =
  | "submitted"
  | "pushed"
  | "accepted"
  | "cancelling"
  | "completed"
  | "failed"
  | "cancelled"
  | "interrupted";

export type ActionLogRecord = ActionSubmission & {
  status: ActionLogStatus;
  pushedAt?: string;
  pushedMessageId?: string;
  acceptedAt?: string;
  acceptedGameTime?: GameTimeSnapshot;
  completedAt?: string;
  completedGameTime?: GameTimeSnapshot;
  failedAt?: string;
  failedGameTime?: GameTimeSnapshot;
  cancelledAt?: string;
  error?: string;
  result?: Record<string, unknown>;
};

export type RuntimeSessionRecord = {
  townId: TownId;
  instanceId: string;
  connectedAt: string;
  disconnectedAt?: string;
  lastSeenAt: string;
  lastAckSeq: number;
};

export type WorldEventRecord = {
  id: string;
  townId: TownId;
  type: string;
  actorId?: string;
  // Spoken/typed words verbatim — see WorldEventPayload.spokenText.
  spokenText?: string;
  data?: Record<string, unknown>;
  occurredAt: string;
  createdAt: string;
  gameTime?: GameTimeSnapshot;
};

export const SERVER_MESSAGE = {
  runtimeAccepted: "runtime.accepted",
  actionSubmit: "action.submit",
  actionCancel: "action.cancel",
  agentThinking: "agent.thinking",
  characterGroupsRefresh: "character.groups.refresh",
  // Server→client list of agent models available for AI takeover model pickers.
  // Sent in response to RUNTIME_MESSAGE.requestAvailableModels.
  availableModels: "available.models",
  pong: "pong",
  error: "error",
} as const;

// Raw `provider:model[/level]` strings from AGENT_AVAILABLE_MODELS, for the
// client's AI-takeover model dropdowns.
export type AvailableModelsPayload = {
  models: string[];
};

export type CharacterGroupsRefreshPayload = {
  characterId: string;
};

export const RUNTIME_MESSAGE = {
  heartbeat: "runtime.heartbeat",
  perceptionManifest: "character.perception_manifest",
  characterRegister: "character.register",
  characterUnregister: "character.unregister",
  actionAck: "action.ack",
  actionRequest: "action.request",
  playerCommand: "player.command",
  worldEvent: "world.event",
  // Client asks for the model list to populate AI-takeover pickers; server
  // replies with SERVER_MESSAGE.availableModels.
  requestAvailableModels: "request.available_models",
  ping: "ping",
  protocolAck: "protocol.ack",
  // lua reaction 元数据 dump。BackendRuntimeClient 在握手后立刻发一次，每次重连都重发。
  // 单一真值在 data/mechanics/crafting.lua —— backend 只接收 + 缓存，从不修改。
  reactionCatalog: "runtime.reaction_catalog_sync",
} as const;

// 单条 reaction 元数据：覆盖 LLM tool 路由 / 难度提示需要的所有字段。
// effects / failure_modes / inputs 不导出（那些是 mechanic 运行用，backend 不需要）。
export type ReactionMetaPayload = {
  id: string;
  skill_id: string;
  difficulty: number;
  workstation: string;
  verb: string;
  sub_option: string;
};

export type ReactionCatalogSyncPayload = {
  reactions: ReactionMetaPayload[];
};

// Runtime-registered character (player or other dynamic character not in the
// static npcs.json catalog). Godot sends one on connect, one on disconnect.
export type CharacterRegisterPayload = {
  characterId: string;
  displayName?: string;
  kind?: "player" | "npc" | "other";
  aliases?: string[];
};

export type CharacterUnregisterPayload = {
  characterId: string;
};

export const AGENT_HOST_MESSAGE = {
  hello: "agent.host.hello",
} as const;

export type AgentHostHelloPayload = {
  instanceId: string;
  token: string;
  lastAckSeq?: number;
  locale?: string;
};

export type ProtocolAckPayload = {
  ackSeq: number;
};

export type PerceptionManifestEnvelope = MessageEnvelope<PerceptionManifestPayload, typeof RUNTIME_MESSAGE.perceptionManifest>;
