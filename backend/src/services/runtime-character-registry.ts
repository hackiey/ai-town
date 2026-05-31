// Runtime-registered characters (currently: connected players) — entries that
// don't live in the static data/town/npcs.json catalog but must still be
// resolvable by name/id wherever NPCs are. Godot pushes character.register on
// connect and character.unregister on disconnect; on reconnect Godot replays
// the current set so the backend rehydrates after a restart.
//
// In-memory only and global. If the project ever runs multiple towns in one
// process this should become a `Map<townId, ...>` instead.

export type RuntimeCharacterKind = "player" | "npc" | "other";

export type RuntimeCharacterEntry = {
  characterId: string;
  displayName: string;
  kind: RuntimeCharacterKind;
  aliases: string[];
};

const registry = new Map<string, RuntimeCharacterEntry>();

export type RegisterInput = {
  characterId: string;
  displayName?: string;
  kind?: RuntimeCharacterKind;
  aliases?: string[];
};

export function registerRuntimeCharacter(input: RegisterInput): RuntimeCharacterEntry {
  const characterId = input.characterId.trim();
  if (!characterId) {
    throw new Error("registerRuntimeCharacter: characterId is required");
  }
  const entry: RuntimeCharacterEntry = {
    characterId,
    displayName: (input.displayName ?? characterId).trim() || characterId,
    kind: input.kind ?? "other",
    aliases: (input.aliases ?? []).map((a) => a.trim()).filter(Boolean),
  };
  registry.set(characterId, entry);
  return entry;
}

export function unregisterRuntimeCharacter(characterId: string): void {
  registry.delete(characterId.trim());
}

export function getRuntimeCharacter(characterId: string): RuntimeCharacterEntry | undefined {
  return registry.get(characterId.trim());
}

export function allRuntimeCharacters(): RuntimeCharacterEntry[] {
  return Array.from(registry.values());
}

export function clearRuntimeCharacters(): void {
  registry.clear();
}
