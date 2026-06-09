// use_item / drop_item renderers.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { DropItemEventData, PickUpItemEventData, ReadEventData, UseItemEventData, WriteEventData } from "../../godot-link/world-events.js";
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

export function renderPickUpItemEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<PickUpItemEventData>;
  const item = data.itemId ? (localizeStringValue(data.itemId) ?? data.itemId) : "东西";
  const count = Number(data.quantity ?? 1);
  const failed = data.outcome === "failure";
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const reason = self && data.error ? `：${localizeText(data.error)}` : "";
  const main = failed
    ? (self ? `你试着拾取${item}，但没拿成${reason}` : `${actor}试着拾取${item}，但没拿成`)
    : (self ? `你拾取了${item} x${count}` : `${actor}拾取了${item} x${count}`);
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
  const target = data.title || data.itemName || "某样东西";
  const failed = data.outcome === "failure";
  const reason = self && data.error ? `：${localizeText(data.error)}` : "";
  const main = failed
    ? (self ? `你试着书写${target}，但没写成${reason}` : `${actor}试着书写${target}，但没写成`)
    : (self ? `你书写了${target}` : `${actor}书写了${target}`);
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
  const target = data.title || "某样东西";
  const failed = data.outcome === "failure";
  const reason = self && data.error ? `：${localizeText(data.error)}` : "";
  const main = failed
    ? (self ? `你试着阅读${target}，但没读成${reason}` : `${actor}试着阅读${target}，但没读成`)
    : (self ? `你阅读了${target}` : `${actor}阅读了${target}`);
  return composeEventLine(event, viewerId, locale, main);
}
