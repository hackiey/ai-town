// Game time 相关纯函数。所有 agent 共用同一份 game-time 语义。
// 关于游戏时间尺度见 backend/docs（time_scale=7×，1 real-day = 1 game-week）。

import type { GameTimeSnapshot, WorldEventRecord } from "../../godot-link/protocol.js";
import { finiteNumber, objectValue } from "./primitives.js";

export function gameTimeTotalMinutes(value: GameTimeSnapshot | undefined): number | undefined {
  if (!value) {
    return undefined;
  }
  if (finiteNumber(value.totalGameMinutes)) {
    return value.totalGameMinutes;
  }
  if (finiteNumber(value.totalGameHours)) {
    return (value.totalGameHours * 60) + (finiteNumber(value.minute) ? value.minute : 0);
  }
  if (finiteNumber(value.day) && finiteNumber(value.hour) && finiteNumber(value.minute)) {
    return (((value.day * 24) + value.hour) * 60) + value.minute;
  }
  return undefined;
}

export function eventGameMinuteValue(event: WorldEventRecord): number | undefined {
  const gameTime = event.gameTime ?? gameTimeFromEventData(event.data);
  if (!gameTime) {
    return undefined;
  }
  const totalGameSeconds = (gameTime as { totalGameSeconds?: unknown }).totalGameSeconds;
  if (finiteNumber(totalGameSeconds)) {
    return totalGameSeconds / 60;
  }
  return gameTimeTotalMinutes(gameTime);
}

export function gameTimeFromEventData(data: Record<string, unknown> | undefined): GameTimeSnapshot | undefined {
  const value = objectValue(data?.gameTime);
  return value as GameTimeSnapshot | undefined;
}
