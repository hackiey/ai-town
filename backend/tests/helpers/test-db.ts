import { openDatabase, type AppDb } from "../../src/db/sqlite.js";

export function createTestDb(): AppDb {
  const db = openDatabase(":memory:");
  installGameWorldTestSchema(db);
  return db;
}

function installGameWorldTestSchema(db: AppDb): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS world_events (
      id TEXT PRIMARY KEY,
      townId TEXT NOT NULL,
      type TEXT NOT NULL,
      actorId TEXT,
      spokenText TEXT,
      data TEXT,
      occurredAt TEXT NOT NULL,
      createdAt TEXT NOT NULL,
      gameTime TEXT
    );

    CREATE TABLE IF NOT EXISTS item_instances (
      townId TEXT NOT NULL,
      ownerKind TEXT NOT NULL,
      ownerId TEXT NOT NULL,
      slotIndex INTEGER NOT NULL,
      itemDefId TEXT NOT NULL,
      stackCount INTEGER NOT NULL,
      quality REAL,
      shapeType TEXT,
      tags TEXT,
      materials TEXT,
      physicsProps TEXT,
      containerAmount REAL,
      containerContent TEXT,
      transformAge REAL,
      fermentCeiling REAL,
      freshnessTier INTEGER,
      freshnessAgeHours REAL,
      durability REAL,
      baseEffects TEXT,
      displayedEffects TEXT,
      listingPriceCenti INTEGER,
      PRIMARY KEY (townId, ownerKind, ownerId, slotIndex)
    );
  `);
}
