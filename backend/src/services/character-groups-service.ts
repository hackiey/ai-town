import type { AppDb } from "../db/sqlite.js";
import type { CharacterGroupRecord } from "../agents/types.js";

// 角色 ↔ group 的多对多成员关系。SQLite 是真值，初始种子来自 npcs.json 每个 NPC 的 groups[]
// (由 Godot Db autoload 在首次 boot 时灌入)。
// better-sqlite3 是 sync API，所有调用现在都是同步的（service 不再 async）。

export function getCharacterGroups(db: AppDb, townId: string, characterId: string): string[] {
  const rows = db
    .prepare("SELECT groupId FROM character_groups WHERE townId = ? AND characterId = ?")
    .all(townId, characterId) as { groupId: string }[];
  return rows.map((r) => r.groupId);
}

export function getGroupMembers(db: AppDb, townId: string, groupId: string): string[] {
  const rows = db
    .prepare("SELECT characterId FROM character_groups WHERE townId = ? AND groupId = ?")
    .all(townId, groupId) as { characterId: string }[];
  return rows.map((r) => r.characterId);
}

export function isMember(db: AppDb, townId: string, characterId: string, groupId: string): boolean {
  const row = db
    .prepare("SELECT 1 FROM character_groups WHERE townId = ? AND characterId = ? AND groupId = ?")
    .get(townId, characterId, groupId);
  return row != null;
}

export function addMember(
  db: AppDb,
  townId: string,
  characterId: string,
  groupId: string,
  source: CharacterGroupRecord["source"] = "runtime",
): void {
  const now = new Date().toISOString();
  db.prepare(
    `INSERT OR IGNORE INTO character_groups (townId, characterId, groupId, joinedAt, source)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(townId, characterId, groupId, now, source ?? null);
}

export function removeMember(db: AppDb, townId: string, characterId: string, groupId: string): void {
  db.prepare("DELETE FROM character_groups WHERE townId = ? AND characterId = ? AND groupId = ?").run(
    townId,
    characterId,
    groupId,
  );
}
