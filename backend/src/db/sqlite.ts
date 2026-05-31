import Database, { type Database as DatabaseType } from "better-sqlite3";
import { dirname } from "node:path";
import { mkdirSync } from "node:fs";
import { MIGRATION_STATEMENTS, SCHEMA_STATEMENTS } from "./schema.js";

export type AppDb = DatabaseType;

export function openDatabase(path: string): AppDb {
  // 文件不存在时父目录可能也没建，先 mkdir 一下
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  // WAL：reader（backend）和 writer（同进程，未来可能 Godot 直连）能并发；
  // foreign_keys：默认关；项目里没用 FK 约束，先不开
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.pragma("busy_timeout = 5000");
  db.pragma("foreign_keys = OFF");
  for (const stmt of SCHEMA_STATEMENTS) {
    db.exec(stmt);
  }
  for (const stmt of MIGRATION_STATEMENTS) {
    try {
      db.exec(stmt);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      // SQLite ALTER TABLE ADD COLUMN 重复执行会报 "duplicate column name"；其它 error 仍要 throw
      if (!/duplicate column name/i.test(message)) {
        throw error;
      }
    }
  }
  return db;
}

// JSON 列辅助：写入时 stringify（null/undefined → null），读出时 parse；
// service 层处理 typed record 时不直接碰 string。
export function toJsonColumn(value: unknown): string | null {
  if (value === undefined || value === null) {
    return null;
  }
  return JSON.stringify(value);
}

export function parseJsonColumn<T = unknown>(value: unknown): T | undefined {
  if (value == null || value === "") {
    return undefined;
  }
  if (typeof value !== "string") {
    return value as T;
  }
  try {
    return JSON.parse(value) as T;
  } catch {
    return undefined;
  }
}
