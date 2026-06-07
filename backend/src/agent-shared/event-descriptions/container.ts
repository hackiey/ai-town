// container_put_take renderer —— 货架/容器统一存取事件（货架=无锁容器）。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ContainerPutTakeEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
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
