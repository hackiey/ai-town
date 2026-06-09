import assert from "node:assert/strict";
import test from "node:test";
import { rowToActionLog } from "../src/db/records.js";
import type { AppDb } from "../src/db/sqlite.js";
import type { ActionLogRecord } from "../src/godot-link/protocol.js";
import { MessageBus } from "../src/plugins/message-bus.js";
import { ACTION_BUS_PATTERN, actionBusChannel } from "../src/services/action-bus.js";
import {
  recordActionAck,
  recordFailedAction,
  requestCancelAction,
  submitAction,
} from "../src/services/action-log-service.js";
import { createTestDb } from "./helpers/test-db.js";

test("submitAction persists a submitted record and publishes delivery", async () => {
  const db = createTestDb();
  try {
    const bus = new MessageBus();
    const nextPayload = waitForActionBusPayload(bus);
    const record = await submitAction(db, bus, {
      townId: "town_001",
      characterId: "mira_blacksmith",
      action: "move_to_location",
      target: { locationId: "forge" },
      priority: 99,
    });
    const published = await nextPayload;

    assert.equal(record.priority, 1);
    assert.equal(published.channel, actionBusChannel("town_001"));
    assert.deepEqual(published.payload, { kind: "deliver", actionId: record.id });

    const saved = readAction(db, record.id);
    assert.equal(saved.status, "submitted");
    assert.deepEqual(saved.target, { locationId: "forge" });
  } finally {
    db.close();
  }
});

test("recordActionAck advances accepted actions to terminal states", async () => {
  const db = createTestDb();
  try {
    const record = await submitAction(db, new MessageBus(), {
      townId: "town_001",
      characterId: "mira_blacksmith",
      action: "say_to",
      target: { targetCharacterId: "oren_vale", text: "hello", volume: "near" },
    });

    await recordActionAck(db, "town_001", {
      ackSeq: 1,
      actionId: record.id,
      status: "accepted",
      gameTime: { totalGameMinutes: 60 },
      result: { started: true },
    });
    const accepted = readAction(db, record.id);
    assert.equal(accepted.status, "accepted");
    assert.deepEqual(accepted.acceptedGameTime, { totalGameMinutes: 60 });
    assert.deepEqual(accepted.result, { started: true });

    await recordActionAck(db, "town_001", {
      ackSeq: 2,
      actionId: record.id,
      status: "completed",
      gameTime: { totalGameMinutes: 61 },
      result: { delivered: true },
    });
    const completed = readAction(db, record.id);
    assert.equal(completed.status, "completed");
    assert.ok(completed.completedAt);
    assert.deepEqual(completed.completedGameTime, { totalGameMinutes: 61 });
    assert.deepEqual(completed.result, { delivered: true });
  } finally {
    db.close();
  }
});

test("requestCancelAction marks pushed actions as cancelling and publishes cancellation", async () => {
  const db = createTestDb();
  try {
    const bus = new MessageBus();
    const record = await submitAction(db, bus, {
      townId: "town_001",
      characterId: "mira_blacksmith",
      action: "sleep",
      target: { durationGameMinutes: 120 },
    });
    await recordActionAck(db, "town_001", { ackSeq: 1, actionId: record.id, status: "accepted" });

    const nextPayload = waitForActionBusPayload(bus);
    const cancelling = await requestCancelAction(db, bus, readAction(db, record.id), "new direct order");
    const published = await nextPayload;

    assert.equal(cancelling.status, "cancelling");
    assert.equal(cancelling.error, "new direct order");
    assert.deepEqual(published.payload, { kind: "cancel", actionId: record.id });
  } finally {
    db.close();
  }
});

test("recordFailedAction writes only backend-owned failed action", () => {
  const db = createTestDb();
  try {
    const record = recordFailedAction(db, {
      townId: "town_001",
      characterId: "mira_blacksmith",
      action: "say_to",
      target: { targetCharacterId: "oren_vale", text: "not now", volume: "near" },
    }, "target is asleep");

    const saved = readAction(db, record.id);
    assert.equal(saved.status, "failed");
    assert.equal(saved.error, "target is asleep");

    const row = db.prepare("SELECT * FROM world_events WHERE type = 'action_failed'").get() as Record<string, unknown> | undefined;
    assert.equal(row, undefined);
  } finally {
    db.close();
  }
});

function readAction(db: AppDb, actionId: string): ActionLogRecord {
  const row = db.prepare("SELECT * FROM action_log WHERE actionId = ?").get(actionId) as Record<string, unknown> | undefined;
  assert.ok(row, `missing action_log row: ${actionId}`);
  return rowToActionLog(row);
}

function waitForActionBusPayload(bus: MessageBus): Promise<{ channel: string; payload: unknown }> {
  return new Promise((resolve) => {
    bus.psubscribe(ACTION_BUS_PATTERN, (channel, payload) => resolve({ channel, payload }));
  });
}
