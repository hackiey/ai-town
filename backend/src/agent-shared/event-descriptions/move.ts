// move_to_location renderer. Public finish event emitted when an actor's
// move-to completes — they reached their target.
// Data shape: PublicFinishEventData with target = MoveToLocationTarget
// (locationId | characterId | itemId | regionId).

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { PublicFinishEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderMoveToLocationEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<PublicFinishEventData>;
  const location = resolveTargetLabel(data.target, locale);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.move_to_location.self_format", locale, { location })
    : t("prompt.context.event.move_to_location.other_format", locale, { actor, location });
  return composeEventLine(event, viewerId, locale, main, {
    attributeChanges: (data.result as Record<string, unknown> | undefined)?.character_changes,
  });
}

function resolveTargetLabel(target: unknown, locale: Locale): string {
  if (!target || typeof target !== "object") {
    return t("prompt.context.event.move_to_location.unknown_target", locale);
  }
  const row = target as Record<string, unknown>;
  for (const key of ["locationId", "characterId", "itemId", "regionId"]) {
    const value = row[key];
    if (typeof value === "string" && value.length > 0) {
      return localizeStringValue(value) ?? value;
    }
  }
  return t("prompt.context.event.move_to_location.unknown_target", locale);
}
