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
  const offerPart = renderTradeLineList(data.offer) || "（无）";
  const requestPart = renderTradeLineList(data.request) || "（无）";
  const main = buyer && seller
    ? `${buyer} 向 ${seller} 提出交易：付 ${offerPart}，换 ${requestPart}`
    : `交易：付 ${offerPart}，换 ${requestPart}`;
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
    ? "接受"
    : data.response === "reject"
      ? "拒绝"
      : data.response === "cancelled"
        ? "取消"
        : "回应";
  const offer = renderTradeLineList(data.offer);
  const request = renderTradeLineList(data.request);
  const detail = offer || request ? `：付 ${offer || "（无）"}，换 ${request || "（无）"}` : "";
  const main = seller && buyer
    ? `${seller} ${verb}了 ${buyer} 的交易${detail}`
    : `${verb}交易${detail}`;
  return composeEventLine(event, viewerId, locale, main);
}

function participantLabel(id: string | undefined, viewerId: string, locale: Locale): string | undefined {
  if (!id) return undefined;
  if (id === viewerId) return t("prompt.context.event.self_pronoun", locale);
  return localizeStringValue(id) ?? id;
}

function renderTradeLineList(value: unknown): string {
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
  return parts.join("、");
}
