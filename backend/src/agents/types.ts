import type { AgentMessage } from "@mariozechner/pi-agent-core";
import type { Usage } from "@mariozechner/pi-ai";
import type { GameTimeSnapshot } from "../godot-link/protocol.js";

export type AgentKind = "npc" | "player" | "god";

export type AgentAutonomy = "active" | "dormant" | "manual";

export type AgentDefinition = {
  agentId: string;
  kind: AgentKind;
  townId: string;
  characterId?: string;
  autonomy: AgentAutonomy;
};

export type AgentSessionRecord = {
  id: string;
  townId: string;
  characterId: string;
  agentKind: AgentKind;
  createdAt: string;
  updatedAt: string;
  messageSeq: number;
  lastUsage?: Usage;
  lastUsageTokenCount?: number;
  lastUsageCostUsd?: number;
  lastUsageUpdatedAt?: string;
};

export type AgentToolSnapshot = {
  name: string;
  label?: string;
  description?: string;
  parameters?: unknown;
};

export type AgentInventorySnapshot = {
  // 已渲染的中文字符串（直接是 user prompt 里看到的那几行），方便 debug 直接展示。
  inventory: string[];
  backpack: string[];
  walletCenti: number;
};

export type AgentSessionMessageRecord = {
  id: string;
  sessionId: string;
  townId: string;
  characterId: string;
  agentKind: AgentKind;
  seq: number;
  role: string;
  message: AgentMessage;
  createdAt: string;
  gameTime?: GameTimeSnapshot;
  turnReason?: string;
  toolsSnapshot?: AgentToolSnapshot[];
  llmMessages?: AgentMessage[];
  llmSystemPrompt?: string;
  inventorySnapshot?: AgentInventorySnapshot;
};

export type CharacterGroupRecord = {
  townId: string;
  characterId: string;
  groupId: string;
  joinedAt: string;
  source?: "seed" | "runtime";
};
