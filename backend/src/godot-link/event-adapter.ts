// Ingress chokepoint for world events arriving over the wire from Godot.
//
// Wire contract: data must conform to one of WorldEventDataByType (see
// world-events.ts). Specifically:
//   - data.actorId: string                          (lifted to top-level event.actorId)
//   - data.affectedCharacterIds: string[]           (visibility / snapshot-flush)
//   - per-event-type semantic fields, camelCase
//
// We assert and pass through. No alias normalization, no key re-derivation —
// the previous "tolerate every shape" approach hid drift bugs (offer_trade
// silently dropped its offer/request arrays). If the wire shape is wrong now,
// we reject loudly so the emitter gets fixed at the source.

import type { WorldEventPayload, WorldEventRecord } from "./protocol.js";
import { isKnownWorldEventType, type WorldEvent } from "./events.js";

export type NormalizeWorldEventPayloadOptions = {
  id: string;
  townId: string;
  now: string;
};

export type NormalizeWorldEventPayloadResult =
  | { ok: true; record: WorldEventRecord; event: WorldEvent }
  | { ok: false; reason: string; type?: string };

export function normalizeWorldEventPayload(
  payload: WorldEventPayload,
  options: NormalizeWorldEventPayloadOptions,
): NormalizeWorldEventPayloadResult {
  if (!payload || typeof payload.type !== "string" || payload.type.length === 0) {
    return { ok: false, reason: "world event missing type" };
  }
  if (!isKnownWorldEventType(payload.type)) {
    return { ok: false, reason: "unknown world event type", type: payload.type };
  }

  const data = objectValue(payload.data) ?? {};
  const actorId = payload.actorId ?? stringValue(data.actorId);
  const affectedCharacterIds = stringArray(data.affectedCharacterIds);
  const isGlobal = data.scope === "global";

  if (!isGlobal && !actorId && affectedCharacterIds.length === 0) {
    return {
      ok: false,
      reason: "world event missing actorId or affectedCharacterIds",
      type: payload.type,
    };
  }

  const gameTime = payload.gameTime ?? objectValue(data.gameTime) as WorldEventRecord["gameTime"];
  const record: WorldEventRecord = {
    id: payload.eventId ?? options.id,
    townId: options.townId,
    type: payload.type,
    actorId,
    spokenText: payload.spokenText,
    data,
    occurredAt: payload.occurredAt ?? options.now,
    createdAt: options.now,
    gameTime,
  };

  const event: WorldEvent = {
    eventId: record.id,
    type: record.type,
    actorId,
    spokenText: record.spokenText,
    data: {
      ...data,
      affectedCharacterIds,
      gameTime,
    },
    occurredAt: record.occurredAt,
    gameTime,
  } as WorldEvent;

  return { ok: true, event, record };
}

export function worldEventRecordToWorldEvent(record: WorldEventRecord): WorldEvent | null {
  if (!isKnownWorldEventType(record.type)) {
    return null;
  }
  const data = record.data ?? {};
  return {
    eventId: record.id,
    type: record.type,
    actorId: record.actorId,
    spokenText: record.spokenText,
    data: {
      ...data,
      affectedCharacterIds: stringArray(data.affectedCharacterIds),
      gameTime: record.gameTime ?? objectValue(data.gameTime),
    },
    occurredAt: record.occurredAt,
    gameTime: record.gameTime,
  } as WorldEvent;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === "string" && entry.length > 0)
    : [];
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function objectValue(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}
