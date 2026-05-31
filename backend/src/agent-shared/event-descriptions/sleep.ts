// went_to_sleep / woke_up renderers.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { WentToSleepEventData, WokeUpEventData } from "../../godot-link/world-events.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderWentToSleepEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<WentToSleepEventData>;
  const minutes = Number(data.durationGameMinutes ?? 0);
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.went_to_sleep.self_format", locale, { minutes: Math.max(0, Math.round(minutes)) })
    : t("prompt.context.event.went_to_sleep.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
      });
  return composeEventLine(event, viewerId, locale, main);
}

export function renderWokeUpEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<WokeUpEventData>;
  const self = isSelfActor(event.actorId, viewerId);
  const reason = data.reason?.trim();
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  let main: string;
  if (reason) {
    main = self
      ? t("prompt.context.event.woke_up.self_with_reason_format", locale, { reason })
      : t("prompt.context.event.woke_up.other_with_reason_format", locale, { actor, reason });
  } else {
    main = self
      ? t("prompt.context.event.woke_up.self_format", locale)
      : t("prompt.context.event.woke_up.other_format", locale, { actor });
  }
  return composeEventLine(event, viewerId, locale, main);
}
