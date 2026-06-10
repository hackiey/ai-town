import type { AppDb } from "../db/sqlite.js";

// 角色 ↔ group 的多对多成员关系。SQLite 是真值，初始种子来自 npcs.json 每个 NPC 的 groups[]
// (由 Godot Db autoload 在首次 boot 时灌入)。
// better-sqlite3 是 sync API，所有调用现在都是同步的（service 不再 async）。

export function getCharacterGroups(db: AppDb, townId: string, characterId: string): string[] {
  const rows = db
    .prepare("SELECT groupId FROM character_groups WHERE townId = ? AND characterId = ?")
    .all(townId, characterId) as { groupId: string }[];
  return rows.map((r) => r.groupId);
}
