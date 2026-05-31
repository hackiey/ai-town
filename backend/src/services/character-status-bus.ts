import type { Redis } from "ioredis";
import type { CharacterStatusPayload } from "../godot-link/protocol.js";

export const CHARACTER_STATUS_BUS_PATTERN = "town:*:character-status";

export function characterStatusBusChannel(townId: string): string {
  return `town:${townId}:character-status`;
}

export function parseCharacterStatusBusChannel(channel: string): string | null {
  const match = /^town:(.+):character-status$/.exec(channel);
  return match?.[1] ?? null;
}

export async function publishCharacterStatusToBus(
  redis: Redis,
  townId: string,
  payload: CharacterStatusPayload,
): Promise<number> {
  return redis.publish(characterStatusBusChannel(townId), JSON.stringify(payload));
}

export async function publishThinkingStatusToBus(
  redis: Redis,
  townId: string,
  characterId: string,
  active: boolean,
  reason: string,
  agentKind: "npc" | "player" | "god",
): Promise<number> {
  return publishCharacterStatusToBus(redis, townId, {
    characterId,
    status: "thinking",
    active,
    reason,
    agentKind,
  });
}

export function parseCharacterStatusBusPayload(raw: string): CharacterStatusPayload {
  const payload = JSON.parse(raw) as Partial<CharacterStatusPayload>;
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
  return {
    characterId: payload.characterId,
    status: "thinking",
    active: payload.active,
    reason: payload.reason,
    agentKind: payload.agentKind,
  };
}
