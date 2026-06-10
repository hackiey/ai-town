// use_item / drop_item renderers.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { DropItemEventData, ReadEventData, UseItemEventData, WriteEventData } from "../../godot-link/world-events.js";
import { localizeStringValue, localizeText } from "../name-resolver/index.js";
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

export function renderWriteEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<WriteEventData>;
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const target = data.title || data.itemName || t("prompt.context.event.item.unknown_object", locale);
  const failed = data.outcome === "failure";
  const reason = self && data.error ? t("prompt.context.event.item.reason_format", locale, { reason: localizeText(data.error) }) : "";
  const main = failed
    ? (self
        ? t("prompt.context.event.write.failure_self_format", locale, { target, reason })
        : t("prompt.context.event.write.failure_other_format", locale, { actor, target }))
    : (self
        ? t("prompt.context.event.write.success_self_format", locale, { target })
        : t("prompt.context.event.write.success_other_format", locale, { actor, target }));
  return composeEventLine(event, viewerId, locale, main);
}

export function renderReadEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ReadEventData>;
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const target = data.title || t("prompt.context.event.item.unknown_object", locale);
  const failed = data.outcome === "failure";
  const reason = self && data.error ? t("prompt.context.event.item.reason_format", locale, { reason: localizeText(data.error) }) : "";
  const main = failed
    ? (self
        ? t("prompt.context.event.read.failure_self_format", locale, { target, reason })
        : t("prompt.context.event.read.failure_other_format", locale, { actor, target }))
    : (self
        ? t("prompt.context.event.read.success_self_format", locale, { target })
        : t("prompt.context.event.read.success_other_format", locale, { actor, target }));
  return composeEventLine(event, viewerId, locale, main);
}
