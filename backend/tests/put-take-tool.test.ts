import assert from "node:assert/strict";
import test from "node:test";
import { buildPutTakeWire } from "../src/agent-shared/game-tools/tool-factories.js";
import { assembleAgentContextFromManifest } from "../src/agent-shared/prompt-context/assemble-from-manifest.js";
import type { AgentCurrentContext } from "../src/agent-shared/prompt-context/types.js";
import type { PerceptionManifestPayload } from "../src/godot-link/perception-manifest.js";
import { createTestDb } from "./helpers/test-db.js";

test("put_take resolves container item indices in that container scope", () => {
  const ctx = putTakeContext();

  const wire = buildPutTakeWire({
    transfers: [{
      kind: "item",
      amount: 1,
      from: { container: "酒馆柜台（酒馆）", item: { name: "麦芽酒", index: 1 } },
      to: {},
    }],
  }, ctx);

  assert.deepEqual(wire, [{
    kind: "item",
    itemId: "beer",
    amount: 1,
    from: { where: "node", containerId: "tavern_bar_shelf@tavern", slotIndex: 0, isShelf: true },
    to: { where: "backpack" },
  }]);
});

test("put_take validates global item index name matches", () => {
  const ctx = putTakeContext();

  assert.throws(() => buildPutTakeWire({
    transfers: [{
      kind: "item",
      amount: 1,
      from: { item: { name: "麦芽酒", index: 1 } },
      to: {},
    }],
  }, ctx), /麦芽酒|银币/);
});

test("non-owner shelf context hides shelf wallet index", () => {
  const db = createShelfDb();
  try {
    const context = assembleAgentContextFromManifest(db, "town_001", shelfManifest([]));

    assert.deepEqual(context.itemIndex.shelves["tavern_bar_shelf@tavern"].map((entry) => entry.itemDefId), ["beer"]);
  } finally {
    db.close();
  }
});

test("owner shelf context exposes shelf wallet index", () => {
  const db = createShelfDb();
  try {
    const context = assembleAgentContextFromManifest(db, "town_001", shelfManifest(["tavern"]));

    assert.deepEqual(context.itemIndex.shelves["tavern_bar_shelf@tavern"].map((entry) => entry.itemDefId), ["silver_coin", "beer"]);
  } finally {
    db.close();
  }
});

function putTakeContext(): AgentCurrentContext {
  return {
    interactiveSites: [{
      id: "tavern_bar_shelf@tavern",
      displayName: "酒馆柜台（酒馆）",
      kind: "shelf",
      directlyInteractable: true,
      availableActions: ["view_container", "put_take"],
    }],
    itemIndex: {
      backpack: [],
      equipment: [],
      nearby: [],
      containers: {},
      shelves: {
        "tavern_bar_shelf@tavern": [{ itemDefId: "beer", slotIndex: 0, scope: "shelf", containerId: "tavern_bar_shelf@tavern", globalIndex: 2 }],
      },
      flat: [
        { itemDefId: "silver_coin", scope: "backpack", globalIndex: 1 },
        { itemDefId: "beer", slotIndex: 0, scope: "shelf", containerId: "tavern_bar_shelf@tavern", globalIndex: 2 },
      ],
    },
  } as unknown as AgentCurrentContext;
}

function createShelfDb() {
  const db = createTestDb();
  db.exec(`
    CREATE TABLE shelves (
      townId TEXT NOT NULL,
      shelfId TEXT NOT NULL,
      ownerGroup TEXT,
      locationId TEXT,
      slotCount INTEGER NOT NULL DEFAULT 0,
      interactionRadius REAL,
      posX REAL, posY REAL, posZ REAL,
      updatedAt TEXT NOT NULL,
      PRIMARY KEY (townId, shelfId)
    );

    CREATE TABLE container_wallets (
      townId TEXT NOT NULL,
      containerId TEXT NOT NULL,
      silverCentiBalance INTEGER NOT NULL DEFAULT 0,
      updatedAt TEXT NOT NULL,
      PRIMARY KEY (townId, containerId)
    );

    CREATE TABLE player_accounts (
      townId TEXT NOT NULL,
      characterId TEXT NOT NULL,
      name TEXT NOT NULL,
      PRIMARY KEY (townId, characterId)
    );
  `);
  db.prepare(`INSERT INTO shelves (townId, shelfId, ownerGroup, locationId, slotCount, interactionRadius, posX, posY, posZ, updatedAt) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, ?)`)
    .run("town_001", "tavern_bar_shelf@tavern", "tavern", "tavern", 12, 3, "2026-01-01T00:00:00.000Z");
  db.prepare(`INSERT INTO container_wallets (townId, containerId, silverCentiBalance, updatedAt) VALUES (?, ?, ?, ?)`)
    .run("town_001", "tavern_bar_shelf@tavern", 100, "2026-01-01T00:00:00.000Z");
  db.prepare(`INSERT INTO item_instances (townId, ownerKind, ownerId, slotIndex, itemDefId, stackCount, quality, shapeType, tags, materials, listingPriceCenti) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run("town_001", "container", "tavern_bar_shelf@tavern", 0, "beer", 12, 70, "bottle", "[]", "{}", 100);
  return db;
}

function shelfManifest(characterGroupIds: string[]): PerceptionManifestPayload {
  return {
    characterId: "tomas_pike",
    selfIsAsleep: false,
    characterGroupIds,
    selfLocationId: "tavern",
    gameTime: { totalGameMinutes: 1 },
    knownLocationIds: [],
    perceivedCharacters: [],
    perceivedLocations: [],
    perceivedItems: [],
    perceivedGroundContainers: [],
    perceivedFarms: [],
    perceivedWorkstations: [],
    perceivedShelves: [{ id: "tavern_bar_shelf@tavern", band: "direct" }],
  } as PerceptionManifestPayload;
}
