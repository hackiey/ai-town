// container_put_take renderer —— 货架/容器统一存取事件（货架=无锁容器）。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ContainerPutTakeEventData, ViewContainerEventData } from "../../godot-link/world-events.js";
import { localizeStringValue, localizeText } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

function formatMoves(moves: Array<{ itemId?: string; content?: string; amount?: number }> | undefined, locale: Locale): string {
  if (!moves || moves.length === 0) return "";
  return moves
    .map((m) => {
      const id = m.itemId ?? m.content ?? "";
      const name = localizeStringValue(id) ?? id;
      return m.amount != null ? `${name} x${m.amount}` : name;
    })
    .join(t("prompt.context.event.list_separator", locale));
}

export function renderContainerPutTakeEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ContainerPutTakeEventData>;
  const moves = formatMoves(data.moves, locale);
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const main = moves
    ? (self
        ? t("prompt.context.event.container_put_take.move_self_format", locale, { items: moves })
        : t("prompt.context.event.container_put_take.move_other_format", locale, { actor, items: moves }))
    : (self
        ? t("prompt.context.event.container_put_take.noop_self", locale)
        : t("prompt.context.event.container_put_take.noop_other", locale, { actor }));
  return composeEventLine(event, viewerId, locale, main);
}

export function renderViewContainerEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ViewContainerEventData>;
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const label = data.label
    ? localizeText(data.label)
    : (data.containerId ? (localizeStringValue(data.containerId) ?? data.containerId) : t("prompt.context.event.view_container.container_fallback", locale));
  const failed = data.outcome === "failure";
  let main: string;
  if (failed) {
    const reason = self && data.error
      ? t("prompt.context.event.view_container.reason_format", locale, { reason: localizeText(data.error) })
      : "";
    main = self
      ? t("prompt.context.event.view_container.failure_self_format", locale, { label, reason })
      : t("prompt.context.event.view_container.failure_other_format", locale, { actor, label });
  } else if (self) {
    const detail = renderViewedItems(data.items, data.message, locale);
    main = detail
      ? t("prompt.context.event.view_container.success_self_items_format", locale, { label, items: detail })
      : t("prompt.context.event.view_container.success_self_empty_format", locale, { label });
  } else {
    main = t("prompt.context.event.view_container.success_other_format", locale, { actor, label });
  }
  return composeEventLine(event, viewerId, locale, main);
}

function renderViewedItems(items: unknown, message: unknown, locale: Locale): string {
  if (Array.isArray(items)) {
    const parts = items.map((item) => renderViewedItem(item, locale)).filter((part): part is string => Boolean(part));
    if (parts.length > 0) return parts.join(t("prompt.context.event.list_separator", locale));
  }
  if (typeof message === "string" && message.trim()) {
    return localizeText(message).replace(/\s*\n\s*/g, t("prompt.context.event.clause_separator", locale)).trim();
  }
  return "";
}

function renderViewedItem(value: unknown, locale: Locale): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const row = value as Record<string, unknown>;
  if (typeof row.line === "string" && row.line.trim()) return localizeText(row.line.trim());
  const itemId = typeof row.itemId === "string" ? row.itemId : typeof row.item_id === "string" ? row.item_id : "";
  if (!itemId) return undefined;
  const name = localizeStringValue(itemId) ?? itemId;
  const quantity = Number(row.quantity ?? row.count ?? 1);
  const qty = Number.isFinite(quantity) && quantity > 0 ? ` x${quantity}` : "";
  const price = Number(row.priceSilver ?? row.price_silver ?? NaN);
  const priceText = Number.isFinite(price) && price > 0
    ? t("prompt.context.event.view_container.price_silver_format", locale, { price: price.toFixed(2) })
    : "";
  const liquid = typeof row.content === "string" && Number(row.amount) > 0
    ? `（${localizeStringValue(row.content) ?? row.content} ${Number(row.amount)}L）`
    : "";
  return `${name}${qty}${liquid}${priceText}`;
}
