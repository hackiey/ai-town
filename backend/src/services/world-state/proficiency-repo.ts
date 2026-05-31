import type { AppDb } from "../../db/sqlite.js";
import type { ProficiencyRowView } from "./types.js";

// npc_proficiency 表由 Godot Db autoload 拥有；backend 只 SELECT 用于 prompt context。
// 行不存在 → 空 dict（公式按 0 处理 = 生手）。
// 真值与公式见 docs/proficiency_system.md。

const SELECT_BY_CHARACTER = `
  SELECT skillId, value
  FROM npc_proficiency
  WHERE townId = ? AND characterId = ?
  ORDER BY value DESC, skillId ASC
`;

export function getProficiencyForCharacter(db: AppDb, townId: string, characterId: string): ProficiencyRowView[] {
  if (!townId || !characterId) return [];
  const rows = safeAll(db, SELECT_BY_CHARACTER, [townId, characterId]);
  return rows.map((r) => {
    const rec = r as Record<string, unknown>;
    return {
      skillId: String(rec.skillId ?? ""),
      value: Number(rec.value ?? 0),
    };
  }).filter((r) => r.skillId.length > 0);
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
