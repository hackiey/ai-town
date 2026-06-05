import type { MessageBus } from "../plugins/message-bus.js";
import type { GameTimeSnapshot } from "../godot-link/protocol.js";

export const GAME_TIME_BUS_PATTERN = "game.time:*";

export type GameTimeBusPayload = {
  gameTime: GameTimeSnapshot;
  observedAt: string;
};

export function gameTimeBusChannel(townId: string): string {
  return `game.time:${townId}`;
}

export function parseGameTimeBusChannel(channel: string): string | null {
  const match = /^game\.time:(.+)$/.exec(channel);
  return match?.[1] ?? null;
}

export function publishGameTimeToBus(
  bus: MessageBus,
  townId: string,
  gameTime: GameTimeSnapshot,
  observedAt = new Date().toISOString(),
): number {
  return bus.publish(gameTimeBusChannel(townId), {
    gameTime,
    observedAt,
  } satisfies GameTimeBusPayload);
}

export function parseGameTimeBusPayload(raw: unknown): GameTimeBusPayload {
  const payload = (raw ?? {}) as Partial<GameTimeBusPayload>;
  if (!payload.gameTime || typeof payload.gameTime !== "object" || Array.isArray(payload.gameTime)) {
    throw new Error("game time bus payload missing gameTime");
  }
  return {
    gameTime: payload.gameTime,
    observedAt: typeof payload.observedAt === "string" ? payload.observedAt : new Date().toISOString(),
  };
}
