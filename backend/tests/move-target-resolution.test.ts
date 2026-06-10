import assert from "node:assert/strict";
import test from "node:test";
import { resolveMoveTarget } from "../src/agent-shared/game-tools/targets.js";

test("move_to_location accepts bare localized character names", () => {
  assert.deepEqual(resolveMoveTarget("鲁迪·泰特"), {
    target: { characterId: "rudi_tate" },
    label: "鲁迪·泰特",
  });
});

test("move_to_location keeps unknown names as location ids", () => {
  assert.deepEqual(resolveMoveTarget("不存在的地点"), {
    target: { locationId: "不存在的地点" },
    label: "不存在的地点",
  });
});

test("move_to_location does not special-case old target prefixes", () => {
  assert.deepEqual(resolveMoveTarget("人物：鲁迪·泰特"), {
    target: { locationId: "人物：鲁迪·泰特" },
    label: "人物：鲁迪·泰特",
  });
});
