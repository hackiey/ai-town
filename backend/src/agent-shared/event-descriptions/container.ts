// container_inspected / container_deposited / container_withdrawn renderers.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ContainerInspectedEventData, ContainerMoveEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderContainerInspectedEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ContainerInspectedEventData>;
  const container = data.containerId ? (localizeStringValue(data.containerId) ?? data.containerId) : "";
  const count = Number(data.itemCount ?? 0);
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.container_inspected.self_format", locale, { container, count })
    : t("prompt.context.event.container_inspected.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
        container,
        count,
      });
  return composeEventLine(event, viewerId, locale, main);
}

export function renderContainerDepositedEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  return renderContainerMove(event, viewerId, locale, "deposited");
}

export function renderContainerWithdrawnEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  return renderContainerMove(event, viewerId, locale, "withdrawn");
}

function renderContainerMove(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
  kind: "deposited" | "withdrawn",
): string {
  const data = (event.data ?? {}) as Partial<ContainerMoveEventData>;
  const container = data.containerId ? (localizeStringValue(data.containerId) ?? data.containerId) : "";
  const item = data.itemId ? (localizeStringValue(data.itemId) ?? data.itemId) : "";
  const count = Number(data.quantity ?? 0);
  const baseKey = kind === "deposited"
    ? "prompt.context.event.container_deposited"
    : "prompt.context.event.container_withdrawn";
  const main = isSelfActor(event.actorId, viewerId)
    ? t(`${baseKey}.self_format`, locale, { container, item, count })
    : t(`${baseKey}.other_format`, locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
        container,
        item,
        count,
      });
  return composeEventLine(event, viewerId, locale, main);
}
