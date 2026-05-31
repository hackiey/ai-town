import type { Redis } from "ioredis";

const DEBUG_AGENT_ENABLED_CHARACTER_IDS_KEY = "debug:agent:enabled-character-ids";

export type DebugAgentRunFilter = {
  configured: boolean;
  enabledCharacterIds: Set<string>;
};

export async function getDebugAgentRunFilter(redis: Redis): Promise<DebugAgentRunFilter> {
  const raw = await redis.get(DEBUG_AGENT_ENABLED_CHARACTER_IDS_KEY);
  if (raw == null) {
    return { configured: false, enabledCharacterIds: new Set() };
  }
  try {
    const parsed = JSON.parse(raw) as unknown;
    const ids = Array.isArray(parsed)
      ? parsed.filter((id): id is string => typeof id === "string" && id.length > 0)
      : [];
    return { configured: true, enabledCharacterIds: new Set(ids) };
  } catch {
    return { configured: false, enabledCharacterIds: new Set() };
  }
}

export async function setDebugAgentRunFilter(redis: Redis, characterIds: string[]): Promise<string[]> {
  const ids = Array.from(new Set(characterIds.map((id) => id.trim()).filter(Boolean))).sort();
  await redis.set(DEBUG_AGENT_ENABLED_CHARACTER_IDS_KEY, JSON.stringify(ids));
  return ids;
}

export function isCharacterEnabledByDebugFilter(filter: DebugAgentRunFilter, characterId: string): boolean {
  return !filter.configured || filter.enabledCharacterIds.has(characterId);
}
