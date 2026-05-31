// give renderer：单向赠送（offer 工具 request:[] 路径触发）。
// 三视角：actor=送出方→"你把 X 递给 Y"；recipient=收件人→"X 把 Y 递给了你"；旁观者→"X 把 Y 递给 Z"。
//
// Wire contract: GiveEventData in world-events.ts。actorId = giver、recipientCharacterId = recipient、
// items = 实际 transferred>0 的清单（leftover 留 giver 不上事件）。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { GiveEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderGiveEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<GiveEventData>;
  const itemsText = renderGiveItemList(data.items);
  const recipientId = data.recipientCharacterId;
  const isGiver = isSelfActor(event.actorId, viewerId);
  const isRecipient = Boolean(recipientId) && recipientId === viewerId;

  let main: string;
  if (isGiver) {
    const recipientLabel = participantLabel(recipientId, viewerId, locale);
    main = `你 把 ${itemsText} 递给 ${recipientLabel}`;
  } else if (isRecipient) {
    const giverLabel = renderActorLabel(event.actorId, viewerId, locale);
    main = `${giverLabel} 把 ${itemsText} 递给了你`;
  } else {
    const giverLabel = renderActorLabel(event.actorId, viewerId, locale);
    const recipientLabel = participantLabel(recipientId, viewerId, locale);
    main = `${giverLabel} 把 ${itemsText} 递给 ${recipientLabel}`;
  }
  return composeEventLine(event, viewerId, locale, main);
}

function participantLabel(id: string | undefined, viewerId: string, locale: Locale): string {
  if (!id) return t("prompt.context.event.actor_unknown", locale);
  if (id === viewerId) return t("prompt.context.event.self_pronoun", locale);
  return localizeStringValue(id) ?? id;
}

function renderGiveItemList(value: unknown): string {
  if (!Array.isArray(value) || value.length === 0) return "（无）";
  const parts: string[] = [];
  for (const entry of value) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as { itemId?: unknown; quantity?: unknown };
    const itemId = typeof row.itemId === "string" ? row.itemId.trim() : "";
    const quantity = typeof row.quantity === "number" ? row.quantity : Number.NaN;
    if (!itemId || !Number.isFinite(quantity) || quantity <= 0) continue;
    const label = localizeStringValue(itemId) ?? itemId;
    parts.push(`${label}×${quantity}`);
  }
  return parts.length > 0 ? parts.join("、") : "（无）";
}
