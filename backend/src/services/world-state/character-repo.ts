import type { AppDb } from "../../db/sqlite.js";
import type { CharacterPresenceView, CharacterStateView } from "./types.js";

// character_states 表由 Godot Db autoload 拥有；backend 只 SELECT。
// 该表行不存在（角色未生成 / 未持久化）→ 返回 undefined，caller 自行兜底。

const SELECT_CHARACTER_STATE = `
  SELECT characterId, currentLocationId, posX, posY, posZ, animState,
         hp, maxHp, stamina, maxStamina, hunger, maxHunger, rest, maxRest,
         drunk, sickness, drunkTier, sicknessTier,
         carryWeight, maxCarry, carryTier,
         sleepNeededHours, temperature, burning, alive,
         equippedRightHand, equippedLeftHand, equippedBody, equippedHead,
         activeStatuses, silverCentiBalance
  FROM character_states
  WHERE townId = ? AND characterId = ?
`;

const SELECT_CHARACTER_PRESENCE_IN = `
  SELECT characterId, animState, hp, hunger, alive, activeStatuses,
         currentActivityKind, currentActivityTarget
  FROM character_states
  WHERE townId = ? AND characterId IN
`;

export function getCharacterState(db: AppDb, townId: string, characterId: string): CharacterStateView | undefined {
  const row = safeGet(db, SELECT_CHARACTER_STATE, [townId, characterId]);
  if (!row) return undefined;
  return rowToCharacterStateView(row as Record<string, unknown>);
}

export function getCharacterPresences(db: AppDb, townId: string, characterIds: string[]): CharacterPresenceView[] {
  if (characterIds.length === 0) return [];
  const placeholders = characterIds.map(() => "?").join(",");
  const sql = `${SELECT_CHARACTER_PRESENCE_IN} (${placeholders})`;
  const rows = safeAll(db, sql, [townId, ...characterIds]);
  return rows.map((r) => rowToPresenceView(r as Record<string, unknown>));
}

function rowToCharacterStateView(r: Record<string, unknown>): CharacterStateView {
  return {
    characterId: String(r.characterId ?? ""),
    currentLocationId: String(r.currentLocationId ?? ""),
    position: {
      x: numberOr(r.posX, 0),
      y: numberOr(r.posY, 0),
      z: numberOr(r.posZ, 0),
    },
    animState: String(r.animState ?? ""),
    hp: numberOr(r.hp, 0),
    maxHp: numberOr(r.maxHp, 100),
    stamina: numberOr(r.stamina, 0),
    maxStamina: numberOr(r.maxStamina, 100),
    hunger: numberOr(r.hunger, 0),
    maxHunger: numberOr(r.maxHunger, 100),
    rest: numberOr(r.rest, 100),
    maxRest: numberOr(r.maxRest, 100),
    drunk: numberOr(r.drunk, 0),
    sickness: numberOr(r.sickness, 0),
    // 档位 key 由 Godot 算好持久化（""/tipsy/drunk/wasted、""/mild/moderate/severe）；backend 不重判阈值。
    drunkTier: typeof r.drunkTier === "string" ? r.drunkTier : "",
    sicknessTier: typeof r.sicknessTier === "string" ? r.sicknessTier : "",
    // 负重：档位 key 由 Godot 算好持久化（""/laden/heavy/overloaded）；backend 不重判阈值。
    carryWeight: numberOr(r.carryWeight, 0),
    maxCarry: numberOr(r.maxCarry, 50),
    carryTier: typeof r.carryTier === "string" ? r.carryTier : "",
    sleepNeededHours: numberOr(r.sleepNeededHours, 0),
    temperature: numberOr(r.temperature, 36.5),
    burning: Number(r.burning ?? 0) !== 0,
    alive: Number(r.alive ?? 1) !== 0,
    equipped: {
      rightHand: String(r.equippedRightHand ?? ""),
      leftHand: String(r.equippedLeftHand ?? ""),
      body: String(r.equippedBody ?? ""),
      head: String(r.equippedHead ?? ""),
    },
    activeStatuses: parseJsonArray(r.activeStatuses),
    walletCenti: numberOr(r.silverCentiBalance, 0),
  };
}

function rowToPresenceView(r: Record<string, unknown>): CharacterPresenceView {
  return {
    characterId: String(r.characterId ?? ""),
    animState: String(r.animState ?? ""),
    hp: numberOr(r.hp, 0),
    hunger: numberOr(r.hunger, 0),
    alive: Number(r.alive ?? 1) !== 0,
    isSleeping: hasSleepingStatus(r.activeStatuses),
    currentActivityKind: emptyToUndefined(r.currentActivityKind),
    currentActivityTarget: emptyToUndefined(r.currentActivityTarget),
  };
}

function emptyToUndefined(value: unknown): string | undefined {
  if (value == null) return undefined;
  const s = String(value);
  return s.length === 0 ? undefined : s;
}

function hasSleepingStatus(value: unknown): boolean {
  for (const entry of parseJsonArray(value)) {
    if (entry && typeof entry === "object") {
      const type = (entry as Record<string, unknown>).type;
      if (type === "sleeping") return true;
    } else if (entry === "sleeping") {
      return true;
    }
  }
  return false;
}

function numberOr(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseJsonArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (typeof value !== "string" || value.length === 0) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

// 表可能不存在（Godot 还没起 / 测试场景）；用 try 让 SELECT 失败时返回 undefined/[]，
// 不让 caller 因为底层 SQLite "no such table" 崩。
function safeGet(db: AppDb, sql: string, params: unknown[]): unknown {
  try {
    return db.prepare(sql).get(...params);
  } catch {
    return undefined;
  }
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
