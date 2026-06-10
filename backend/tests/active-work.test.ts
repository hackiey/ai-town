import assert from "node:assert/strict";
import test from "node:test";
import type { AgentRuntimeContext } from "../src/agent-host/runtime.js";
import type { ContinuedActionManager } from "../src/agent-shared/notices/queue.js";
import type { ActionLogRecord } from "../src/godot-link/protocol.js";
import { computeActiveWorkLines } from "../src/runtimes/two-track-agent/action-session/active-work.js";

test("active work renders well liquid take as drawing water", async () => {
  const lines = await renderActiveWorkFor({
    id: "action_draw_water",
    townId: "town_001",
    characterId: "oren_vale",
    action: "take",
    target: {
      transfers: [{
        kind: "liquid",
        amount: 20,
        from: { where: "well", containerId: "well" },
        to: { where: "backpack", slotIndex: 4 },
      }],
    },
    priority: 0.5,
    createdAt: "2026-01-01T00:00:00.000Z",
    status: "accepted",
  });

  assert.deepEqual(lines, ["- 正在从水井打水；水会在完成回执后进桶，完成前即使背包仍显示空桶也不要再次打水（状态=执行中）"]);
});

test("active work renders active farm operation and farm target", async () => {
  const lines = await renderActiveWorkFor({
    id: "action_water_field",
    townId: "town_001",
    characterId: "oren_vale",
    action: "plan_farm_work",
    target: { farmId: "north_wall_field_3", ops: [{ kind: "water" }] },
    result: {
      active_kind: "water",
      active_state: "working",
      completed: [],
      remaining: [{ kind: "water", slot_index: -1 }],
    },
    priority: 0.5,
    createdAt: "2026-01-01T00:00:00.000Z",
    status: "accepted",
  });

  assert.deepEqual(lines, ["- 浇水 北墙麦圃3号农田（状态=执行中）"]);
});

async function renderActiveWorkFor(action: ActionLogRecord): Promise<string[]> {
  const ctx = {
    actions: () => ({
      recentForCharacter: async () => [action],
    }),
  } as unknown as AgentRuntimeContext;
  const continuedActions = {
    restore: async () => undefined,
    activeIntentLine: () => undefined,
  } as unknown as ContinuedActionManager;
  return computeActiveWorkLines({ ctx, characterId: action.characterId, continuedActions });
}
