// 游戏时间渲染。GAME_HOURS_PER_DAY=24, GAME_DAYS_PER_REIGN_YEAR=360（一年12月×30天）。
// 周次按"绝对天数 mod 7"算，因为 360 不能整除 7。
//
// 关于游戏时间尺度（real-time vs game-time）见 [[project_game_time_scale]]。

import { getActiveLocale, t } from "../../i18n/index.js";
import type { GameTimeSnapshot } from "../../godot-link/protocol.js";
import { getDefaultReignEraName } from "../entity-descriptions/lore.js";
import { numberValue, objectValue, pickString } from "../utils/primitives.js";

export const GAME_HOURS_PER_DAY = 24;
export const GAME_DAYS_PER_REIGN_YEAR = 360;
export const INITIAL_GAME_YEAR = 5;
export const INITIAL_GAME_DAY_OF_YEAR = 64;
export const INITIAL_GAME_ABSOLUTE_DAY = ((INITIAL_GAME_YEAR - 1) * GAME_DAYS_PER_REIGN_YEAR) + (INITIAL_GAME_DAY_OF_YEAR - 1);
export const INITIAL_GAME_HOUR = 6;
export const INITIAL_GAME_MINUTE = 0;
const GAME_WEEKDAY_OFFSET = 3; // 统治五年3月4日（absolute day 1503）是周二，而 weekday_0 是周一

export type NormalizedGameTime = {
  eraName: string;
  year: number;
  dayOfYear: number;
  absoluteDay: number;
  hour: number;
  minute: number;
};

export function formatGameTime(value: unknown): string | undefined {
  const gameTime = normalizeGameTime(value);
  if (!gameTime) return undefined;
  return `${formatGameDate(gameTime)} ${gameTime.hour}:${pad2(gameTime.minute)}`;
}

export function formatGameDate(gameTime: NormalizedGameTime): string {
  const month = Math.floor((gameTime.dayOfYear - 1) / 30) + 1;
  const dayOfMonth = ((gameTime.dayOfYear - 1) % 30) + 1;
  const weekdayIndex = (((gameTime.absoluteDay + GAME_WEEKDAY_OFFSET) % 7) + 7) % 7;
  return t("prompt.context.time.date_format", getActiveLocale(), {
    era: gameTime.eraName,
    year: formatEraYear(gameTime.year),
    month,
    day: dayOfMonth,
    weekday: t(`prompt.context.time.weekday_${weekdayIndex}`, getActiveLocale()),
  });
}

export function normalizeGameTime(value: unknown): NormalizedGameTime | undefined {
  const record = objectValue(value);
  if (!record) return undefined;

  const totalMinutes = numberValue(record.totalGameMinutes ?? record.total_game_minutes);
  const totalHours = numberValue(record.totalGameHours ?? record.total_game_hours);
  const dayFromTotal = totalMinutes != null
    ? Math.floor(totalMinutes / (GAME_HOURS_PER_DAY * 60))
    : totalHours != null
      ? Math.floor(totalHours / GAME_HOURS_PER_DAY)
      : undefined;
  const day = numberValue(record.day ?? record.gameDay ?? record.game_day) ?? dayFromTotal ?? 0;
  const hour = totalMinutes != null
    ? Math.floor(totalMinutes / 60) % GAME_HOURS_PER_DAY
    : numberValue(record.hour ?? record.gameHour ?? record.game_hour) ?? (totalHours != null ? totalHours % GAME_HOURS_PER_DAY : 0);
  const minute = totalMinutes != null
    ? totalMinutes % 60
    : numberValue(record.minute ?? record.gameMinute ?? record.game_minute) ?? 0;
  const year = numberValue(record.year ?? record.reignYear ?? record.reign_year) ?? Math.floor(day / GAME_DAYS_PER_REIGN_YEAR) + 1;
  const dayOfYear = numberValue(record.dayOfYear ?? record.day_of_year) ?? (day % GAME_DAYS_PER_REIGN_YEAR) + 1;
  const eraName = pickString(record, ["eraName", "era_name"]) ?? getDefaultReignEraName();

  return {
    eraName,
    year: Math.max(1, Math.floor(year)),
    dayOfYear: Math.max(1, Math.floor(dayOfYear)),
    absoluteDay: Math.max(0, Math.floor(day)),
    hour: clampTimePart(hour, 0, 23),
    minute: clampTimePart(minute, 0, 59),
  };
}

export function gameTimeSortValue(gameTime: NormalizedGameTime): number {
  return ((((gameTime.year * GAME_DAYS_PER_REIGN_YEAR) + gameTime.dayOfYear) * GAME_HOURS_PER_DAY) + gameTime.hour) * 60 + gameTime.minute;
}

function formatEraYear(year: number): string {
  if (year === 1) return t("prompt.context.time.era_year_one", getActiveLocale());
  return CHINESE_ERA_YEAR_NAMES[year] ?? String(year);
}

const CHINESE_ERA_YEAR_NAMES: Record<number, string> = {
  2: "二",
  3: "三",
  4: "四",
  5: "五",
  6: "六",
  7: "七",
  8: "八",
  9: "九",
  10: "十",
};

export function initialGameTimeSnapshot(): GameTimeSnapshot {
  const totalGameHours = (INITIAL_GAME_ABSOLUTE_DAY * GAME_HOURS_PER_DAY) + INITIAL_GAME_HOUR;
  return {
    totalGameMinutes: (totalGameHours * 60) + INITIAL_GAME_MINUTE,
    totalGameHours,
    day: INITIAL_GAME_ABSOLUTE_DAY,
    hour: INITIAL_GAME_HOUR,
    minute: INITIAL_GAME_MINUTE,
    year: INITIAL_GAME_YEAR,
    dayOfYear: INITIAL_GAME_DAY_OF_YEAR,
    eraName: getDefaultReignEraName(),
  };
}

export function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

function clampTimePart(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.min(max, Math.max(min, Math.floor(value)));
}

export function gameTimeFromRecord(data: Record<string, unknown> | undefined): GameTimeSnapshot | undefined {
  const value = data?.gameTime ?? data?.game_time;
  return objectValue(value) as GameTimeSnapshot | undefined;
}
