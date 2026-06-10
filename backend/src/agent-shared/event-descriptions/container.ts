// container_transfer renderer —— 货架/容器/工作台储物统一存取事件。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ContainerTransferEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
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

export function renderContainerTransferEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ContainerTransferEventData>;
  const moves = formatMoves(data.moves, locale);
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const main = moves
    ? (self
        ? t("prompt.context.event.container_transfer.move_self_format", locale, { items: moves })
        : t("prompt.context.event.container_transfer.move_other_format", locale, { actor, items: moves }))
    : (self
        ? t("prompt.context.event.container_transfer.noop_self", locale)
        : t("prompt.context.event.container_transfer.noop_other", locale, { actor }));
  return composeEventLine(event, viewerId, locale, main);
}
