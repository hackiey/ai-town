import type { MessageBus } from "../plugins/message-bus.js";
import type { PerceptionManifestPayload } from "../godot-link/perception-manifest.js";

export const WORLD_EVENT_BUS_PATTERN = "world.events:*";

export type WorldEventBusPayload = {
  eventId: string;
  // 事件目标（actor + affected）各自事件时刻的 perception manifest，按 characterId 索引。
  // worker 在触发 turn 前先 ingest 这些 manifest，保证决策时用的是事件时刻的感知真值，
  // 避免 manifest 与 event 分走两条 channel 互相 race 导致的 stale。
  perception?: Record<string, PerceptionManifestPayload>;
};

export function worldEventBusChannel(townId: string): string {
  return `world.events:${townId}`;
}

export function parseWorldEventBusChannel(channel: string): string | null {
  const match = /^world\.events:(.+)$/.exec(channel);
  return match?.[1] ?? null;
}

export function publishWorldEventToBus(
  bus: MessageBus,
  townId: string,
  eventId: string,
  perception?: Record<string, PerceptionManifestPayload>,
): number {
  const payload: WorldEventBusPayload = perception && Object.keys(perception).length > 0
    ? { eventId, perception }
    : { eventId };
  return bus.publish(worldEventBusChannel(townId), payload);
}

export function parseWorldEventBusPayload(raw: unknown): WorldEventBusPayload {
  const payload = (raw ?? {}) as Partial<WorldEventBusPayload>;
  if (!payload.eventId || typeof payload.eventId !== "string") {
    throw new Error("world event bus payload missing eventId");
  }
  const perception = payload.perception && typeof payload.perception === "object"
    ? payload.perception
    : undefined;
  return perception ? { eventId: payload.eventId, perception } : { eventId: payload.eventId };
}
