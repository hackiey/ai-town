import type { MessageBus } from "../plugins/message-bus.js";
import type { CharacterStatusPayload } from "../godot-link/protocol.js";

export const CHARACTER_STATUS_BUS_PATTERN = "town:*:character-status";

export function characterStatusBusChannel(townId: string): string {
  return `town:${townId}:character-status`;
}

export function parseCharacterStatusBusChannel(channel: string): string | null {
  const match = /^town:(.+):character-status$/.exec(channel);
  return match?.[1] ?? null;
}

export function publishCharacterStatusToBus(
  bus: MessageBus,
  townId: string,
  payload: CharacterStatusPayload,
): number {
  return bus.publish(characterStatusBusChannel(townId), payload);
}

export function publishThinkingStatusToBus(
  bus: MessageBus,
  townId: string,
  characterId: string,
  active: boolean,
  reason: string,
  agentKind: "npc" | "player" | "god",
  source = "",
): number {
  const payload: CharacterStatusPayload = {
    characterId,
    status: "thinking",
    active,
    reason,
    agentKind,
  };
  if (source) payload.source = source;
  return publishCharacterStatusToBus(bus, townId, payload);
}

export function parseCharacterStatusBusPayload(raw: unknown): CharacterStatusPayload {
  const payload = (raw ?? {}) as Partial<CharacterStatusPayload>;
  if (!payload.characterId || typeof payload.characterId !== "string") {
    throw new Error("character status bus payload missing characterId");
  }
  if (payload.status !== "thinking") {
    throw new Error("character status bus payload has unsupported status");
  }
  if (typeof payload.active !== "boolean") {
    throw new Error("character status bus payload missing active");
  }
  if (payload.reason !== undefined && typeof payload.reason !== "string") {
    throw new Error("character status bus payload has invalid reason");
  }
  if (
    payload.agentKind !== undefined
    && payload.agentKind !== "npc"
    && payload.agentKind !== "player"
    && payload.agentKind !== "god"
  ) {
    throw new Error("character status bus payload has invalid agentKind");
  }
  if (payload.source !== undefined && typeof payload.source !== "string") {
    throw new Error("character status bus payload has invalid source");
  }
  return {
    characterId: payload.characterId,
    status: "thinking",
    active: payload.active,
    reason: payload.reason,
    agentKind: payload.agentKind,
    source: payload.source,
  };
}
