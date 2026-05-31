// Resolve "who did this" label per viewer perspective.
// actor === viewer → "你"; otherwise display name; missing → "某人".
// Per-type renderers MUST go through this — never inline characterName() —
// so the self-pronoun rule lives in one place.

import { t, type Locale } from "../../../i18n/index.js";
import { characterName } from "../../name-resolver/index.js";

export function isSelfActor(actorId: string | undefined, viewerId: string): boolean {
  return Boolean(actorId) && actorId === viewerId;
}

export function renderActorLabel(actorId: string | undefined, viewerId: string, locale: Locale): string {
  if (isSelfActor(actorId, viewerId)) {
    return t("prompt.context.event.self_pronoun", locale);
  }
  if (actorId) {
    return characterName(actorId);
  }
  return t("prompt.context.event.actor_unknown", locale);
}
