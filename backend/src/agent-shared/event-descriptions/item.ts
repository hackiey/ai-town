// use_item / drop_item renderers.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { DropItemEventData, UseItemEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderUseItemEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<UseItemEventData>;
  const item = data.itemId ? (localizeStringValue(data.itemId) ?? data.itemId) : "";
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.use_item.self_format", locale, { item })
    : t("prompt.context.event.use_item.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
        item,
      });
  return composeEventLine(event, viewerId, locale, main);
}

export function renderDropItemEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<DropItemEventData>;
  const item = data.itemId ? (localizeStringValue(data.itemId) ?? data.itemId) : "";
  const count = Number(data.quantity ?? 1);
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.drop_item.self_format", locale, { item, count })
    : t("prompt.context.event.drop_item.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
        item,
        count,
      });
  return composeEventLine(event, viewerId, locale, main);
}
