// shelf_updated / shelf_item_sold renderers.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ShelfItemSoldEventData, ShelfUpdatedEventData } from "../../godot-link/world-events.js";
import { localizeStringValue, localizeText } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderShelfUpdatedEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ShelfUpdatedEventData>;
  const shelf = data.shelfId ? (localizeStringValue(data.shelfId) ?? data.shelfId) : "";
  const summary = Array.isArray(data.changes) && data.changes.length > 0
    ? data.changes
        .filter((c): c is string => typeof c === "string" && c.length > 0)
        .map((c) => localizeText(c))
        .join("；")
    : t("prompt.context.event.shelf_updated.empty_summary", locale);
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.shelf_updated.self_format", locale, { shelf, summary })
    : t("prompt.context.event.shelf_updated.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
        shelf,
        summary,
      });
  return composeEventLine(event, viewerId, locale, main);
}

export function renderShelfItemSoldEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ShelfItemSoldEventData>;
  const itemId = extractItemId(data.item);
  const item = itemId ? (localizeStringValue(itemId) ?? itemId) : "";
  const count = Number(data.quantity ?? 1);
  // Godot emits both priceCenti (int) and priceSilver (float). Format to 2 decimals for display.
  const priceSilver = Number(data.priceSilver ?? 0);
  const price = priceSilver.toFixed(2);
  const sellerId = data.sellerCharacterId ?? "";
  const buyerId = data.buyerCharacterId ?? "";
  const seller = sellerId ? (localizeStringValue(sellerId) ?? sellerId) : "";
  const buyer = buyerId ? (localizeStringValue(buyerId) ?? buyerId) : "";
  let main: string;
  if (buyerId === viewerId) {
    main = t("prompt.context.event.shelf_item_sold.self_buyer_format", locale, { seller, item, count, price });
  } else if (sellerId === viewerId) {
    main = t("prompt.context.event.shelf_item_sold.self_seller_format", locale, { buyer, item, count, price });
  } else {
    main = t("prompt.context.event.shelf_item_sold.other_format", locale, { buyer, seller, item, count, price });
  }
  return composeEventLine(event, viewerId, locale, main);
}

function extractItemId(item: unknown): string | undefined {
  if (!item || typeof item !== "object") return undefined;
  const row = item as Record<string, unknown>;
  for (const key of ["itemId", "item_id", "id"]) {
    const v = row[key];
    if (typeof v === "string" && v.length > 0) return v;
  }
  return undefined;
}
