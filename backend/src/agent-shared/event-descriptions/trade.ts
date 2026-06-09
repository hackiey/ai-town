// Trade event renderers. Phrases trade in terms of buyer/seller, swapping in
// "你" when the viewer matches.
//
// Wire contract: TradeOfferEventData / TradeResponseEventData in
// world-events.ts. offer = lines the buyer pays; request = lines the buyer
// asks for back.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { TradeOfferEventData, TradeResponseEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { composeEventLine } from "./shared/compose.js";

export function renderTradeOfferEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<TradeOfferEventData>;
  const buyer = participantLabel(data.buyerCharacterId, viewerId, locale);
  const seller = participantLabel(data.sellerCharacterId, viewerId, locale);
  const offerPart = renderTradeLineList(data.offer, locale) || t("prompt.context.event.trade.none", locale);
  const requestPart = renderTradeLineList(data.request, locale) || t("prompt.context.event.trade.none", locale);
  const main = buyer && seller
    ? t("prompt.context.event.trade.offer_format", locale, { buyer, seller, offer: offerPart, request: requestPart })
    : t("prompt.context.event.trade.offer_no_participants_format", locale, { offer: offerPart, request: requestPart });
  return composeEventLine(event, viewerId, locale, main);
}

export function renderTradeResponseEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<TradeResponseEventData>;
  const seller = participantLabel(data.sellerCharacterId, viewerId, locale);
  const buyer = participantLabel(data.buyerCharacterId, viewerId, locale);
  const verb = data.response === "accept"
    ? t("prompt.context.event.trade.response_accept", locale)
    : data.response === "reject"
      ? t("prompt.context.event.trade.response_reject", locale)
      : data.response === "cancelled"
        ? t("prompt.context.event.trade.response_cancelled", locale)
        : t("prompt.context.event.trade.response_default", locale);
  const offer = renderTradeLineList(data.offer, locale);
  const request = renderTradeLineList(data.request, locale);
  const detail = offer || request
    ? t("prompt.context.event.trade.response_detail_format", locale, {
        offer: offer || t("prompt.context.event.trade.none", locale),
        request: request || t("prompt.context.event.trade.none", locale),
      })
    : "";
  const main = seller && buyer
    ? t("prompt.context.event.trade.response_format", locale, { seller, verb, buyer, detail })
    : t("prompt.context.event.trade.response_no_participants_format", locale, { verb, detail });
  return composeEventLine(event, viewerId, locale, main);
}

function participantLabel(id: string | undefined, viewerId: string, locale: Locale): string | undefined {
  if (!id) return undefined;
  if (id === viewerId) return t("prompt.context.event.self_pronoun", locale);
  return localizeStringValue(id) ?? id;
}

function renderTradeLineList(value: unknown, locale: Locale): string {
  if (!Array.isArray(value)) return "";
  const parts: string[] = [];
  for (const entry of value) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as { item?: unknown; count?: unknown };
    const item = typeof row.item === "string" ? row.item.trim() : "";
    const count = typeof row.count === "number" ? row.count : Number.NaN;
    if (!item || !Number.isFinite(count) || count <= 0) continue;
    const label = localizeStringValue(item) ?? item;
    parts.push(`${label}×${count}`);
  }
  return parts.join(t("prompt.context.event.list_separator", locale));
}
