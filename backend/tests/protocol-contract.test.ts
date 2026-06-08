import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { ACTION_NAMES, isActionAckStatus, isKnownActionName } from "../src/godot-link/actions.js";
import { isKnownWorldEventType } from "../src/godot-link/events.js";
import {
  assertCompatibleEnvelopeVersion,
  isCompatibleProtocolVersion,
  protocolMajor,
} from "../src/godot-link/protocol.js";
import { listCraftSlugs } from "../src/agent-shared/game-tools/craft-registry.js";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

test("protocol versions are major-compatible only", () => {
  assert.equal(protocolMajor("1.0.0"), 1);
  assert.equal(protocolMajor("0.9.0"), 0);
  assert.equal(protocolMajor("not-a-version"), null);
  assert.equal(isCompatibleProtocolVersion("1.2.3"), true);
  assert.equal(isCompatibleProtocolVersion("2.0.0"), false);
  assert.doesNotThrow(() => assertCompatibleEnvelopeVersion({ version: "1.0.0" }));
  assert.throws(() => assertCompatibleEnvelopeVersion({ version: "2.0.0" }), /unsupported protocol version/);
});

test("action registries reject unknown values and contain no duplicates", () => {
  assert.equal(new Set(ACTION_NAMES).size, ACTION_NAMES.length);
  assert.equal(isKnownActionName("move_to_location"), true);
  assert.equal(isKnownActionName("not_an_action"), false);
  assert.equal(isActionAckStatus("completed"), true);
  assert.equal(isActionAckStatus("pending"), false);
});

test("every craft slug is both an action and a world event type", () => {
  const actions = new Set<string>(ACTION_NAMES);
  for (const slug of listCraftSlugs()) {
    assert.equal(actions.has(slug), true, `${slug} must be listed in ACTION_NAMES`);
    assert.equal(isKnownWorldEventType(slug), true, `${slug} must be a known world event type`);
  }
});

test("Godot action runner has a dispatch path for every backend action", () => {
  const runner = readFileSync(resolve(repoRoot, "src/characters/parts/backend_action_runner.gd"), "utf8");
  const farming = readFileSync(resolve(repoRoot, "src/characters/parts/backend_actions/farming_handlers.gd"), "utf8");
  const combined = `${runner}\n${farming}`;
  const craftActions = new Set<string>(listCraftSlugs());

  assert.match(runner, /Crafts\.is_action\(action\)/, "craft actions must route through Crafts.is_action(action)");

  for (const action of ACTION_NAMES) {
    if (craftActions.has(action)) {
      continue;
    }
    assert.match(combined, new RegExp(`"${escapeRegExp(action)}"`), `${action} must be handled by Godot dispatch`);
  }
});

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
