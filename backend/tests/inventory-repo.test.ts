import assert from "node:assert/strict";
import test from "node:test";
import { getInventoryForCharacter, getInventoryForContainer } from "../src/services/world-state/inventory-repo.js";
import { createTestDb } from "./helpers/test-db.js";

test("inventory repo maps item_instances typed columns and JSON aspects", () => {
  const db = createTestDb();
  try {
    db.prepare(`
      INSERT INTO item_instances (
        townId, ownerKind, ownerId, slotIndex, itemDefId, stackCount, quality,
        shapeType, tags, materials, physicsProps, baseEffects, displayedEffects, listingPriceCenti
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      "town_001",
      "character",
      "mira_blacksmith",
      2,
      "bread",
      3,
      88,
      "loaf",
      JSON.stringify(["food", 7, "baked"]),
      JSON.stringify({ body: "wheat", invalid: 7 }),
      JSON.stringify({ weight: 0.4 }),
      JSON.stringify({ hunger: 20, note: "ignore" }),
      JSON.stringify({ hunger: 18 }),
      125,
    );
    db.prepare(`
      INSERT INTO item_instances (
        townId, ownerKind, ownerId, slotIndex, itemDefId, stackCount,
        shapeType, tags, materials, containerAmount, containerContent, transformAge, fermentCeiling,
        freshnessTier, freshnessAgeHours, durability
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      "town_001",
      "character",
      "mira_blacksmith",
      1,
      "water_bucket",
      1,
      "bucket",
      "not json",
      "not json",
      4.5,
      "water",
      2,
      24,
      1,
      3.5,
      75,
    );

    const inventory = getInventoryForCharacter(db, "town_001", "mira_blacksmith");
    assert.equal(inventory.length, 2);
    assert.equal(inventory[0].slotIndex, 1);
    assert.deepEqual(inventory[0].tags, []);
    assert.deepEqual(inventory[0].materials, {});
    assert.deepEqual(inventory[0].container, { amount: 4.5, content: "water", fermenting: true, ceiling: 24 });
    assert.deepEqual(inventory[0].freshness, { tier: 1, ageHours: 3.5 });
    assert.equal(inventory[0].durability, 75);

    assert.equal(inventory[1].slotIndex, 2);
    assert.deepEqual(inventory[1].tags, ["food", "baked"]);
    assert.deepEqual(inventory[1].materials, { body: "wheat" });
    assert.deepEqual(inventory[1].physicsProps, { weight: 0.4 });
    assert.deepEqual(inventory[1].baseEffects, { hunger: 20 });
    assert.deepEqual(inventory[1].displayedEffects, { hunger: 18 });
    assert.equal(inventory[1].listingPriceCenti, 125);
  } finally {
    db.close();
  }
});

test("inventory repo scopes by owner kind and id", () => {
  const db = createTestDb();
  try {
    const insert = db.prepare(`
      INSERT INTO item_instances (townId, ownerKind, ownerId, slotIndex, itemDefId, stackCount)
      VALUES (?, ?, ?, ?, ?, ?)
    `);
    insert.run("town_001", "container", "pantry", 1, "flour", 5);
    insert.run("town_001", "character", "pantry", 1, "bread", 1);
    insert.run("town_002", "container", "pantry", 1, "salt", 2);

    const contents = getInventoryForContainer(db, "town_001", "pantry");
    assert.equal(contents.length, 1);
    assert.equal(contents[0].itemDefId, "flour");
    assert.equal(contents[0].stackCount, 5);
  } finally {
    db.close();
  }
});
