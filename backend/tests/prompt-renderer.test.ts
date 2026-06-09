import assert from "node:assert/strict";
import test from "node:test";
import type { GameAgentContext } from "../src/agent-shared/prompt-context/types.js";
import type { ActionLogRecord, WorldEventRecord } from "../src/godot-link/protocol.js";
import { gameTimeSortValue, normalizeGameTime } from "../src/agent-shared/prompt-context/time.js";
import { renderAgentEventsContext } from "../src/runtimes/two-track-agent/prompt/context/renderer.js";

test("action prompt timeline includes backend-owned failed actions", () => {
  const failedAction: ActionLogRecord = {
    id: "action_failed_internal_1",
    townId: "town_001",
    characterId: "mira_blacksmith",
    action: "say_to",
    target: { targetCharacterId: "Oren", text: "not now", volume: "near" },
    priority: 0.5,
    createdAt: "2026-01-01T00:00:00.000Z",
    gameTime: { totalGameMinutes: 10 * 60 + 5 },
    status: "failed",
    failedAt: "2026-01-01T00:00:00.000Z",
    error: "target is asleep",
    reason: "agent 工具：想告诉 Oren 暂时不行",
  };
  const context = {
    townId: "town_001",
    characterId: "mira_blacksmith",
    assembledAt: "2026-01-01T00:00:00.000Z",
    relevantEventWindowHours: 8,
    worldLore: [],
    current: {
      gameTime: { totalGameMinutes: 10 * 60 + 10 },
      selfDrunk: 0,
      selfDrunkTier: "",
    } as GameAgentContext["current"],
    memory: { selfKnowledge: [], commonSense: [], skills: [], other: [], all: [] },
    relevantEvents: [],
    pendingEvents: [],
    selfActionResults: [failedAction],
  } as GameAgentContext;

  const rendered = renderAgentEventsContext(context);

  assert.match(rendered, /# 近期事件（尚未总结）/);
  assert.match(rendered, /10:05 （未成）你想对 Oren 说「not now」：target is asleep/);
  assert.match(rendered, /→ 行动理由：想告诉 Oren 暂时不行/);
});

test("action prompt timeline hides entries compacted into working memory", () => {
  const oldAction: ActionLogRecord = {
    id: "action_old_failed",
    townId: "town_001",
    characterId: "mira_blacksmith",
    action: "say_to",
    target: { targetCharacterId: "Oren", text: "old", volume: "near" },
    priority: 0.5,
    createdAt: "2026-01-01T00:00:00.000Z",
    gameTime: { totalGameMinutes: 10 * 60 + 1 },
    status: "failed",
    failedAt: "2026-01-01T00:00:00.000Z",
    error: "old failure",
  };
  const newAction: ActionLogRecord = {
    ...oldAction,
    id: "action_new_failed",
    target: { targetCharacterId: "Oren", text: "new", volume: "near" },
    gameTime: { totalGameMinutes: 10 * 60 + 2 },
    error: "new failure",
  };
  const context = {
    townId: "town_001",
    characterId: "mira_blacksmith",
    assembledAt: "2026-01-01T00:00:00.000Z",
    relevantEventWindowHours: 8,
    worldLore: [],
    current: {
      gameTime: { totalGameMinutes: 10 * 60 + 10 },
      selfDrunk: 0,
      selfDrunkTier: "",
    } as GameAgentContext["current"],
    memory: { selfKnowledge: [], commonSense: [], skills: [], other: [], all: [] },
    relevantEvents: [],
    pendingEvents: [],
    workingMemory: {
      content: "旧事已经总结。",
      updatedAt: "2026-01-01T00:00:00.000Z",
      compactedThrough: {
        kind: "action",
        id: "action_old_failed",
        gameMinutes: gameTimeSortValue(normalizeGameTime({ totalGameMinutes: 10 * 60 + 1 })!),
        createdAt: "2026-01-01T00:00:00.000Z",
      },
    },
    selfActionResults: [oldAction, newAction],
  } as GameAgentContext;

  const rendered = renderAgentEventsContext(context);

  assert.doesNotMatch(rendered, /old failure/);
  assert.match(rendered, /new failure/);
});

test("action prompt timeline adds self action reason under matching world event", () => {
  const event: WorldEventRecord = {
    id: "event_1",
    townId: "town_001",
    type: "move_to_location",
    actorId: "mira_blacksmith",
    data: {
      actorId: "mira_blacksmith",
      affectedCharacterIds: ["mira_blacksmith"],
      actionId: "action_move_1",
      target: { locationId: "forge" },
    },
    occurredAt: "2026-01-01T00:00:00.000Z",
    createdAt: "2026-01-01T00:00:00.000Z",
    gameTime: { totalGameMinutes: 10 * 60 + 6 },
  };
  const action: ActionLogRecord = {
    id: "action_move_1",
    townId: "town_001",
    characterId: "mira_blacksmith",
    action: "move_to_location",
    target: { locationId: "forge" },
    priority: 0.5,
    createdAt: "2026-01-01T00:00:00.000Z",
    gameTime: { totalGameMinutes: 10 * 60 + 6 },
    status: "completed",
    completedAt: "2026-01-01T00:00:00.000Z",
    reason: "agent 工具：去铁匠铺取木炭",
  };
  const context = {
    townId: "town_001",
    characterId: "mira_blacksmith",
    assembledAt: "2026-01-01T00:00:00.000Z",
    relevantEventWindowHours: 8,
    worldLore: [],
    current: {
      gameTime: { totalGameMinutes: 10 * 60 + 10 },
      selfDrunk: 0,
      selfDrunkTier: "",
    } as GameAgentContext["current"],
    memory: { selfKnowledge: [], commonSense: [], skills: [], other: [], all: [] },
    relevantEvents: [event],
    pendingEvents: [],
    selfActionResults: [action],
  } as GameAgentContext;

  const rendered = renderAgentEventsContext(context);

  assert.match(rendered, /10:06/);
  assert.match(rendered, /→ 行动理由：去铁匠铺取木炭/);
});
