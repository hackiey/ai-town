// container_put_take renderer —— 货架/容器统一存取事件（货架=无锁容器）。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ContainerPutTakeEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

function formatMoves(moves: Array<{ itemId: string; quantity: number }> | undefined): string {
  if (!moves || moves.length === 0) return "";
  return moves
    .map((m) => `${localizeStringValue(m.itemId) ?? m.itemId} x${m.quantity}`)
    .join("、");
}

export function renderContainerPutTakeEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ContainerPutTakeEventData>;
  const container = data.containerId ? (localizeStringValue(data.containerId) ?? data.containerId) : "";
  const putText = formatMoves(data.puts);
  const takeText = formatMoves(data.takes);
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  const parts: string[] = [];
  if (putText) {
    parts.push(self
      ? t("prompt.context.event.container_put_take.put_self", locale, { container, items: putText })
      : t("prompt.context.event.container_put_take.put_other", locale, { actor, container, items: putText }));
  }
  if (takeText) {
    parts.push(self
      ? t("prompt.context.event.container_put_take.take_self", locale, { container, items: takeText })
      : t("prompt.context.event.container_put_take.take_other", locale, { actor, container, items: takeText }));
  }
  const main = parts.length > 0
    ? parts.join("；")
    : (self
        ? t("prompt.context.event.container_put_take.noop_self", locale, { container })
        : t("prompt.context.event.container_put_take.noop_other", locale, { actor, container }));
  return composeEventLine(event, viewerId, locale, main);
}
