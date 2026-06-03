// Runtime-registered characters (currently: connected players) — entries that
// don't live in the static data/town/npcs.json catalog but must still be
// resolvable by name/id wherever NPCs are. Godot pushes character.register on
// connect and character.unregister on disconnect; on reconnect Godot replays
// the current set so the backend rehydrates after a restart.
//
// The in-memory Map is the synchronous read cache the name resolver reads. It is
// per-process, so it does NOT cross the server↔worker process boundary on its
// own — registrations are persisted to the `runtime_characters` sqlite table
// (server writes on register/unregister) and the worker rehydrates its in-memory
// Map from that table before rendering prompts (syncRuntimeRegistryFromDb).
//
// Global (not per-town). If the project ever runs multiple towns in one process
// this should become a `Map<townId, ...>` instead.

import type { AppDb } from "../db/sqlite.js";
import { parseJsonColumn } from "../db/sqlite.js";

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

// ---------- sqlite 持久化（跨进程桥）----------
// server 进程在 register/unregister 时把行写进 runtime_characters；worker 进程渲染前
// 用 syncRuntimeRegistryFromDb 把整张表刷进内存 Map。两进程开同一个 sqlite 文件，故玩家
// 名能跨进程解析，且 worker 重启后无需等 Godot 重放也能恢复。

type RuntimeCharacterRow = {
  characterId: string;
  townId: string;
  displayName: string;
  kind: string;
  aliases: string;
};

export function upsertRuntimeCharacterRow(db: AppDb, townId: string, entry: RegisterInput): void {
  const characterId = entry.characterId.trim();
  if (!characterId) return;
  const displayName = (entry.displayName ?? characterId).trim() || characterId;
  const kind: RuntimeCharacterKind = entry.kind ?? "other";
  const aliases = (entry.aliases ?? []).map((a) => a.trim()).filter(Boolean);
  db.prepare(
    `INSERT INTO runtime_characters (characterId, townId, displayName, kind, aliases, updatedAt)
     VALUES (@characterId, @townId, @displayName, @kind, @aliases, @updatedAt)
     ON CONFLICT(characterId) DO UPDATE SET
       townId = excluded.townId,
       displayName = excluded.displayName,
       kind = excluded.kind,
       aliases = excluded.aliases,
       updatedAt = excluded.updatedAt`,
  ).run({
    characterId,
    townId,
    displayName,
    kind,
    aliases: JSON.stringify(aliases),
    updatedAt: new Date().toISOString(),
  });
}

export function deleteRuntimeCharacterRow(db: AppDb, characterId: string): void {
  const id = characterId.trim();
  if (!id) return;
  db.prepare(`DELETE FROM runtime_characters WHERE characterId = ?`).run(id);
}

// 把整张 runtime_characters 表刷进内存 registry（clear + repopulate）。
// 只在 worker 渲染前调用——worker 的 registry 完全由本函数驱动，clear 不会丢自身注册。
export function syncRuntimeRegistryFromDb(db: AppDb): void {
  const rows = db.prepare(
    `SELECT characterId, townId, displayName, kind, aliases FROM runtime_characters`,
  ).all() as RuntimeCharacterRow[];
  registry.clear();
  for (const row of rows) {
    registry.set(row.characterId, {
      characterId: row.characterId,
      displayName: row.displayName,
      kind: (row.kind as RuntimeCharacterKind) ?? "other",
      aliases: parseJsonColumn<string[]>(row.aliases) ?? [],
    });
  }
}
