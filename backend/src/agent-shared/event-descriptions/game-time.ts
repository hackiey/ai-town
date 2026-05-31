// Game-time label helper for event timelines: "{date} {hour}:{minute}".
// Kept alongside event renderers since every call site that renders an event
// also wants the timestamp.

import { getActiveLocale, t } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import {
  formatGameDate,
  gameTimeFromRecord,
  normalizeGameTime,
  pad2,
  type NormalizedGameTime,
} from "../prompt-context/time.js";

export function renderEventGameTimeLabel(event: WorldEventRecord): string {
  const locale = getActiveLocale();
  const gameTime = eventNormalizedGameTime(event);
  if (!gameTime) {
    return t("prompt.context.time.unknown", locale);
  }
  const date = formatGameDate(gameTime);
  return `${date} ${gameTime.hour}:${pad2(gameTime.minute)}`;
}

export function eventNormalizedGameTime(event: WorldEventRecord): NormalizedGameTime | undefined {
  return normalizeGameTime(event.gameTime ?? gameTimeFromRecord(event.data));
}
