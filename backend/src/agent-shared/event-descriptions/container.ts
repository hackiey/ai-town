// container_put_take renderer —— 货架/容器统一存取事件（货架=无锁容器）。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ContainerPutTakeEventData, ViewContainerEventData } from "../../godot-link/world-events.js";
import { localizeStringValue, localizeText } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

function formatMoves(moves: Array<{ itemId?: string; content?: string; amount?: number }> | undefined): string {
  if (!moves || moves.length === 0) return "";
  return moves
    .map((m) => {
      const id = m.itemId ?? m.content ?? "";
      const name = localizeStringValue(id) ?? id;
      return m.amount != null ? `${name} x${m.amount}` : name;
    })
    .join("、");
}

export function renderContainerPutTakeEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ContainerPutTakeEventData>;
  const moves = formatMoves(data.moves);
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const main = moves
    ? (self ? `你搬运了 ${moves}` : `${actor} 搬运了 ${moves}`)
    : (self ? "你摆弄了一下容器" : `${actor} 摆弄了一下容器`);
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
  const label = data.label ? localizeText(data.label) : (data.containerId ? (localizeStringValue(data.containerId) ?? data.containerId) : "容器");
  const failed = data.outcome === "failure";
  let main: string;
  if (failed) {
    const reason = self && data.error ? `：${localizeText(data.error)}` : "";
    main = self ? `你试着查看${label}，但没看成${reason}` : `${actor}试着查看${label}，但没看成`;
  } else if (self) {
    const detail = renderViewedItems(data.items, data.message);
    main = detail ? `你查看了${label}，里面有：${detail}` : `你查看了${label}，里面是空的`;
  } else {
    main = `${actor}查看了${label}`;
  }
  return composeEventLine(event, viewerId, locale, main);
}

function renderViewedItems(items: unknown, message: unknown): string {
  if (Array.isArray(items)) {
    const parts = items.map(renderViewedItem).filter((part): part is string => Boolean(part));
    if (parts.length > 0) return parts.join("、");
  }
  if (typeof message === "string" && message.trim()) {
    return localizeText(message).replace(/\s*\n\s*/g, "；").replace(/^.*?里：\s*/, "").trim();
  }
  return "";
}

function renderViewedItem(value: unknown): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const row = value as Record<string, unknown>;
  if (typeof row.line === "string" && row.line.trim()) return localizeText(row.line.trim());
  const itemId = typeof row.itemId === "string" ? row.itemId : typeof row.item_id === "string" ? row.item_id : "";
  if (!itemId) return undefined;
  const name = localizeStringValue(itemId) ?? itemId;
  const quantity = Number(row.quantity ?? row.count ?? 1);
  const qty = Number.isFinite(quantity) && quantity > 0 ? ` x${quantity}` : "";
  const price = Number(row.priceSilver ?? row.price_silver ?? NaN);
  const priceText = Number.isFinite(price) && price > 0 ? ` @ ${price.toFixed(2)}银` : "";
  const liquid = typeof row.content === "string" && Number(row.amount) > 0
    ? `（${localizeStringValue(row.content) ?? row.content} ${Number(row.amount)}L）`
    : "";
  return `${name}${qty}${liquid}${priceText}`;
}
