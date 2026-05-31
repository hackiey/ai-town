// say_to renderer. "X 对 Y 说（音量）:「内容」" with self → "你".
//
// Actor/target labels are resolved by id through the shared resolver — no
// display-name field on the wire. The spoken words live on
// WorldEventRecord.spokenText (single canonical home — no per-type duplication).

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { SayToEventData } from "../../godot-link/world-events.js";
import { characterDisplayName, localizeText } from "../name-resolver/index.js";
import { renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderSayToEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<SayToEventData>;
  const spoken = event.spokenText ? localizeText(event.spokenText) : "";
  const actorLabel = renderActorLabel(event.actorId, viewerId, locale);
  const volumeLabel = data.volume ?? t("prompt.context.speak.volume_unknown", locale);

  let main: string;
  if (!data.targetCharacterId) {
    main = t("prompt.context.speak.simple_format", locale, {
      actor: actorLabel, volume: volumeLabel, text: spoken,
    });
  } else {
    const targetId = data.targetCharacterId;
    const targetLabel = targetId === viewerId
      ? t("prompt.context.event.self_pronoun", locale)
      : characterDisplayName(targetId, locale);
    main = t("prompt.context.speak.to_target_simple_format", locale, {
      actor: actorLabel, target: targetLabel, volume: volumeLabel, text: spoken,
    });
  }
  return composeEventLine(event, viewerId, locale, main.trim());
}
