// Fallback renderer for event types without a dedicated renderer (typically
// new Lua-emitted mechanic events or AmbientOrUnhandledEventType not yet
// covered). Renders `[type] <actor> 做了一件事` — does NOT dump event.data
// (the old behavior was to deep-walk arrays/objects, which produced the
// `result: character_changes=attributes=after=55, before=51, field=stamina`
// soup the LLM couldn't parse).
//
// When you see a fallback line in the prompt, the action is to add a
// dedicated renderer for that type.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderFallbackEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  let main: string;
  if (!event.actorId) {
    main = t("prompt.context.event.fallback.actor_unknown_format", locale, { type: event.type });
  } else if (isSelfActor(event.actorId, viewerId)) {
    main = t("prompt.context.event.fallback.self_format", locale, { type: event.type });
  } else {
    main = t("prompt.context.event.fallback.other_format", locale, {
      type: event.type,
      actor: renderActorLabel(event.actorId, viewerId, locale),
    });
  }
  // Fallback keys embed the [type] tag themselves, so suppress the auto prefix.
  return composeEventLine(event, viewerId, locale, main, { skipTypePrefix: true });
}
