import assert from "node:assert/strict";
import test from "node:test";
import { normalizeWorldEventPayload, worldEventRecordToWorldEvent } from "../src/godot-link/event-adapter.js";
import type { WorldEventPayload, WorldEventRecord } from "../src/godot-link/protocol.js";

test("normalizes canonical world event payloads", () => {
  const result = normalizeWorldEventPayload({
    type: "say_to",
    spokenText: "hello",
    data: {
      actorId: "mira_blacksmith",
      affectedCharacterIds: ["oren_vale", "", 3],
      gameTime: { totalGameMinutes: 123 },
      targetCharacterId: "oren_vale",
      volume: "near",
    },
  } as WorldEventPayload, {
    id: "event_fallback",
    townId: "town_001",
    now: "2026-01-01T00:00:00.000Z",
  });

  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.equal(result.record.id, "event_fallback");
  assert.equal(result.record.actorId, "mira_blacksmith");
  assert.equal(result.record.spokenText, "hello");
  assert.deepEqual(result.record.gameTime, { totalGameMinutes: 123 });
  assert.deepEqual(result.event.data.affectedCharacterIds, ["oren_vale"]);
  assert.deepEqual(result.event.gameTime, { totalGameMinutes: 123 });
});

test("rejects unknown events and actorless local events", () => {
  const unknown = normalizeWorldEventPayload({ type: "does_not_exist" } as WorldEventPayload, options());
  assert.deepEqual(unknown, { ok: false, reason: "unknown world event type", type: "does_not_exist" });

  const actorless = normalizeWorldEventPayload({ type: "say_to", data: {} } as WorldEventPayload, options());
  assert.deepEqual(actorless, {
    ok: false,
    reason: "world event missing actorId or affectedCharacterIds",
    type: "say_to",
  });
});

test("allows explicitly global ambient events without actor or affected ids", () => {
  const result = normalizeWorldEventPayload({
    type: "weather_changed",
    data: { scope: "global", weather: "rain" },
  } as WorldEventPayload, options());

  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.equal(result.record.actorId, undefined);
  assert.deepEqual(result.event.data.affectedCharacterIds, []);
});

test("converts stored records back to runtime events", () => {
  const record: WorldEventRecord = {
    id: "event_1",
    townId: "town_001",
    type: "give",
    actorId: "mira_blacksmith",
    data: {
      affectedCharacterIds: ["oren_vale", "", 1],
      recipientCharacterId: "oren_vale",
      items: [{ itemId: "bread", quantity: 1 }],
    },
    occurredAt: "2026-01-01T00:00:00.000Z",
    createdAt: "2026-01-01T00:00:00.000Z",
  };

  const event = worldEventRecordToWorldEvent(record);
  assert.ok(event);
  assert.deepEqual(event.data.affectedCharacterIds, ["oren_vale"]);
  assert.equal(worldEventRecordToWorldEvent({ ...record, type: "unknown" }), null);
});

function options() {
  return { id: "event_1", townId: "town_001", now: "2026-01-01T00:00:00.000Z" };
}
