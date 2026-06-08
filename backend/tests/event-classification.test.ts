import assert from "node:assert/strict";
import test from "node:test";
import type { WorldEventRecord } from "../src/godot-link/protocol.js";
import { classifyEventForCharacter } from "../src/agent-shared/event-semantics/classification.js";

test("woke_up is always a hard interrupt", () => {
  assert.deepEqual(classifyEventForCharacter(event({ type: "woke_up" }), "mira_blacksmith"), {
    kind: "hard_interrupt",
    interruptKey: "hard",
  });
});

test("self-authored sensory events are ignored", () => {
  assert.deepEqual(classifyEventForCharacter(event({
    type: "say_to",
    actorId: "mira_blacksmith",
    data: { affectedCharacterIds: ["oren_vale"], targetCharacterId: "oren_vale" },
  }), "mira_blacksmith"), { kind: "ignored" });
});

test("direct player speech interrupts affected characters", () => {
  assert.deepEqual(classifyEventForCharacter(event({
    type: "say_to",
    actorId: "player_123",
    data: { affectedCharacterIds: ["mira_blacksmith"] },
  }), "mira_blacksmith"), {
    kind: "sensory",
    interruptKey: "direct_speech",
    direct: true,
  });
});

test("give ignores giver, directly interrupts recipient, and remains ambient for witnesses", () => {
  const give = event({
    type: "give",
    actorId: "mira_blacksmith",
    data: {
      affectedCharacterIds: ["mira_blacksmith", "oren_vale", "tomas_miller"],
      recipientCharacterId: "oren_vale",
      items: [{ itemId: "bread", quantity: 1 }],
    },
  });

  assert.deepEqual(classifyEventForCharacter(give, "mira_blacksmith"), { kind: "ignored" });
  assert.deepEqual(classifyEventForCharacter(give, "oren_vale"), {
    kind: "sensory",
    interruptKey: "direct_speech",
    direct: true,
  });
  assert.deepEqual(classifyEventForCharacter(give, "tomas_miller"), {
    kind: "sensory",
    interruptKey: "ambient_sensory",
    direct: false,
  });
});

test("unaffected characters ignore sensory events", () => {
  assert.deepEqual(classifyEventForCharacter(event({
    type: "container_put_take",
    actorId: "mira_blacksmith",
    data: { affectedCharacterIds: ["oren_vale"] },
  }), "tomas_miller"), { kind: "ignored" });
});

function event(overrides: Partial<WorldEventRecord>): WorldEventRecord {
  return {
    id: "event_1",
    townId: "town_001",
    type: "say_to",
    actorId: "mira_blacksmith",
    data: { affectedCharacterIds: [] },
    occurredAt: "2026-01-01T00:00:00.000Z",
    createdAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}
