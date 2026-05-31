import type { AppDb } from "../db/sqlite.js";
import { parseJsonColumn } from "../db/sqlite.js";
import type { RuntimeStorage, RuntimeStorageValue } from "./storage.js";

export type SqliteRuntimeStorageOptions = {
  runtimeName: string;
  townId: string;
  characterId: string;
  now?: () => Date;
};

export class SqliteRuntimeStorage implements RuntimeStorage {
  private readonly runtimeName: string;
  private readonly townId: string;
  private readonly characterId: string;
  private readonly now: () => Date;

  constructor(private readonly db: AppDb, options: SqliteRuntimeStorageOptions) {
    this.runtimeName = options.runtimeName;
    this.townId = options.townId;
    this.characterId = options.characterId;
    this.now = options.now ?? (() => new Date());
  }

  async get(key: string): Promise<RuntimeStorageValue | undefined> {
    const row = this.db
      .prepare(
        `SELECT value FROM runtime_storage
         WHERE runtimeName = ? AND townId = ? AND characterId = ? AND key = ?`,
      )
      .get(this.runtimeName, this.townId, this.characterId, key) as { value?: string } | undefined;
    if (!row?.value) {
      return undefined;
    }
    return parseJsonColumn<RuntimeStorageValue>(row.value);
  }

  async set(key: string, value: RuntimeStorageValue): Promise<void> {
    this.db.prepare(
      `INSERT INTO runtime_storage (runtimeName, townId, characterId, key, value, updatedAt)
       VALUES (@runtimeName, @townId, @characterId, @key, @value, @updatedAt)
       ON CONFLICT(runtimeName, townId, characterId, key) DO UPDATE SET
         value = excluded.value,
         updatedAt = excluded.updatedAt`,
    ).run({
      runtimeName: this.runtimeName,
      townId: this.townId,
      characterId: this.characterId,
      key,
      value: JSON.stringify(value),
      updatedAt: this.now().toISOString(),
    });
  }

  async delete(key: string): Promise<void> {
    this.db.prepare(
      `DELETE FROM runtime_storage
       WHERE runtimeName = ? AND townId = ? AND characterId = ? AND key = ?`,
    ).run(this.runtimeName, this.townId, this.characterId, key);
  }

  async list(prefix = ""): Promise<Array<{ key: string; value: RuntimeStorageValue }>> {
    const rows = this.db
      .prepare(
        `SELECT key, value FROM runtime_storage
         WHERE runtimeName = ? AND townId = ? AND characterId = ? AND key LIKE ? ESCAPE '\\'
         ORDER BY key ASC`,
      )
      .all(this.runtimeName, this.townId, this.characterId, `${escapeLike(prefix)}%`) as Array<{ key: string; value: string }>;
    return rows.map((row) => ({
      key: row.key,
      value: parseJsonColumn<RuntimeStorageValue>(row.value) ?? null,
    }));
  }
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (match) => `\\${match}`);
}
