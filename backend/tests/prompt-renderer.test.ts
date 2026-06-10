import assert from "node:assert/strict";
import test from "node:test";
import type { GameAgentContext } from "../src/agent-shared/prompt-context/types.js";
import type { ActionLogRecord, WorldEventRecord } from "../src/godot-link/protocol.js";
import { gameTimeSortValue, normalizeGameTime } from "../src/agent-shared/prompt-context/time.js";
import { renderAgentEventsContext, renderAgentTurnContext } from "../src/runtimes/two-track-agent/prompt/context/renderer.js";
import { renderTwoTrackAgentTurnUserMessage } from "../src/runtimes/two-track-agent/prompt/messages.js";

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

  assert.match(rendered, /# 近期事件（尚无工作记忆总结，最近 8 小时）/);
  assert.match(rendered, /10:05 （未成）你想对 Oren 说「not now」：target is asleep/);
  assert.match(rendered, /→ 行动理由：想告诉 Oren 暂时不行/);
});

test("action prompt timeline keeps compacted entries as covered details", () => {
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

  assert.match(rendered, /# 近期事件（已在工作记忆中总结过，仅保留最近 10 条供核对细节）/);
  assert.match(rendered, /old failure/);
  assert.match(rendered, /# 工作记忆之后新发生的事件/);
  assert.match(rendered, /new failure/);
  assert.ok(rendered.indexOf("old failure") < rendered.indexOf("# 工作记忆之后新发生的事件"));
  assert.ok(rendered.indexOf("# 工作记忆之后新发生的事件") < rendered.indexOf("new failure"));
});

test("action prompt keeps only latest 10 covered timeline details", () => {
  const actions: ActionLogRecord[] = Array.from({ length: 12 }, (_, index) => ({
    id: `action_covered_failed_${index}`,
    townId: "town_001",
    characterId: "mira_blacksmith",
    action: "say_to",
    target: { targetCharacterId: "Oren", text: `covered ${index}`, volume: "near" },
    priority: 0.5,
    createdAt: `2026-01-01T00:${String(index).padStart(2, "0")}:00.000Z`,
    gameTime: { totalGameMinutes: 10 * 60 + index },
    status: "failed",
    failedAt: `2026-01-01T00:${String(index).padStart(2, "0")}:00.000Z`,
    error: `covered-error-${String(index).padStart(2, "0")}`,
  }));
  const latestAction = actions[actions.length - 1];
  const context = {
    townId: "town_001",
    characterId: "mira_blacksmith",
    assembledAt: "2026-01-01T00:20:00.000Z",
    relevantEventWindowHours: 8,
    worldLore: [],
    current: {
      gameTime: { totalGameMinutes: 10 * 60 + 20 },
      selfDrunk: 0,
      selfDrunkTier: "",
    } as GameAgentContext["current"],
    memory: { selfKnowledge: [], commonSense: [], skills: [], other: [], all: [] },
    relevantEvents: [],
    pendingEvents: [],
    workingMemory: {
      content: "这些事已经总结。",
      updatedAt: "2026-01-01T00:20:00.000Z",
      compactedThrough: {
        kind: "action",
        id: latestAction.id,
        gameMinutes: gameTimeSortValue(normalizeGameTime(latestAction.gameTime)!),
        createdAt: latestAction.createdAt,
      },
    },
    selfActionResults: actions,
  } as GameAgentContext;

  const rendered = renderAgentEventsContext(context);

  assert.doesNotMatch(rendered, /covered-error-00/);
  assert.doesNotMatch(rendered, /covered-error-01/);
  assert.match(rendered, /covered-error-02/);
  assert.match(rendered, /covered-error-11/);
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

test("action turn prompt places working memory before event details", () => {
  const event: WorldEventRecord = {
    id: "event_after_memory",
    townId: "town_001",
    type: "move_to_location",
    actorId: "mira_blacksmith",
    data: {
      actorId: "mira_blacksmith",
      affectedCharacterIds: ["mira_blacksmith"],
      target: { locationId: "forge" },
    },
    occurredAt: "2026-01-01T00:00:00.000Z",
    createdAt: "2026-01-01T00:00:00.000Z",
    gameTime: { totalGameMinutes: 10 * 60 + 6 },
  };
  const context = {
    townId: "town_001",
    characterId: "mira_blacksmith",
    assembledAt: "2026-01-01T00:00:00.000Z",
    relevantEventWindowHours: 8,
    worldLore: [],
    current: baseCurrentContext(),
    memory: { selfKnowledge: [], commonSense: [], skills: [], other: [], all: [] },
    relevantEvents: [event],
    pendingEvents: [],
    workingMemory: {
      content: "我已经整理过之前的事，现在要留意新变化。",
      updatedAt: "2026-01-01T00:00:00.000Z",
      compactedThrough: {
        kind: "event",
        id: "event_before_memory",
        gameMinutes: gameTimeSortValue(normalizeGameTime({ totalGameMinutes: 10 * 60 + 1 })!),
        createdAt: "2026-01-01T00:00:00.000Z",
      },
    },
    selfActionResults: [],
  } as GameAgentContext;

  const rendered = renderTwoTrackAgentTurnUserMessage("working_memory", [], [], context);

  const memoryIndex = rendered.indexOf("# 工作记忆（来自思考模块）");
  const eventsIndex = rendered.indexOf("# 工作记忆之后新发生的事件");
  assert.ok(memoryIndex >= 0);
  assert.ok(eventsIndex >= 0);
  assert.ok(memoryIndex < eventsIndex);
});

test("action turn prompt labels non-direct interactive sites as distant", () => {
  const context = {
    townId: "town_001",
    characterId: "mira_blacksmith",
    assembledAt: "2026-01-01T00:00:00.000Z",
    relevantEventWindowHours: 8,
    worldLore: [],
    current: {
      ...baseCurrentContext(),
      interactiveSites: [
        {
          id: "market_shelf_1",
          displayName: "货架",
          kind: "shelf",
          directlyInteractable: false,
          availableActions: ["view_container", "put_take"],
          summary: "空货架",
        },
      ],
    },
    memory: { selfKnowledge: [], commonSense: [], skills: [], other: [], all: [] },
    relevantEvents: [],
    pendingEvents: [],
    selfActionResults: [],
  } as GameAgentContext;

  const rendered = renderAgentTurnContext(context);

  assert.match(rendered, /## 远处（10米）/);
  assert.doesNotMatch(rendered, /需前往交互/);
});

function baseCurrentContext(): GameAgentContext["current"] {
  return {
    currentLocation: "forge",
    gameTime: { totalGameMinutes: 10 * 60 + 10 },
    visibleLocations: [],
    availableActions: [],
    characterAttributes: [],
    selfDrunk: 0,
    selfDrunkTier: "",
    proficiency: [],
    groups: [],
    nearbyBuildings: { near: [], far: [] },
    nearbyCharacters: { near: [], far: [] },
    nearbyItems: { near: [], far: [] },
    nearbyFarms: [],
    nearbyWorkstations: [],
    nearbyShelves: [],
    interactiveSites: [],
    inventory: [],
    backpack: [],
    itemIndex: { backpack: [], equipment: [], nearby: [], containers: {}, shelves: {}, flat: [] },
    walletCenti: 0,
  };
}
