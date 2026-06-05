import type { AppDb } from "../db/sqlite.js";

const DEBUG_AGENT_ENABLED_CHARACTER_IDS_KEY = "agent:enabled-character-ids";

export type DebugAgentRunFilter = {
  configured: boolean;
  enabledCharacterIds: Set<string>;
};

export function getDebugAgentRunFilter(db: AppDb): DebugAgentRunFilter {
  const row = db
    .prepare("SELECT value FROM debug_settings WHERE key = ?")
    .get(DEBUG_AGENT_ENABLED_CHARACTER_IDS_KEY) as { value: string } | undefined;
  if (row == null) {
    return { configured: false, enabledCharacterIds: new Set() };
  }
  try {
    const parsed = JSON.parse(row.value) as unknown;
    const ids = Array.isArray(parsed)
      ? parsed.filter((id): id is string => typeof id === "string" && id.length > 0)
      : [];
    return { configured: true, enabledCharacterIds: new Set(ids) };
  } catch {
    return { configured: false, enabledCharacterIds: new Set() };
  }
}

export function setDebugAgentRunFilter(db: AppDb, characterIds: string[]): string[] {
  const ids = Array.from(new Set(characterIds.map((id) => id.trim()).filter(Boolean))).sort();
  db.prepare(
    `INSERT INTO debug_settings (key, value) VALUES (?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
  ).run(DEBUG_AGENT_ENABLED_CHARACTER_IDS_KEY, JSON.stringify(ids));
  return ids;
}

export function isCharacterEnabledByDebugFilter(filter: DebugAgentRunFilter, characterId: string): boolean {
  return !filter.configured || filter.enabledCharacterIds.has(characterId);
}
