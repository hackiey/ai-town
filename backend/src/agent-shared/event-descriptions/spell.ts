// spell_hit 渲染器。命中结算后发出，按视角渲染：目标看到"X 对你施放了…"，
// 旁观者看到"X 对 Y 施放了…"，施法者（理论上 ignored，不会到这）"你对 Y…"。
// 法术名走 prompt.context.spell.<id>，缺失则回退到原始 id（t() miss 返回 key）。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { SpellHitEventData } from "../../godot-link/world-events.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

function spellName(spellId: string | undefined, locale: Locale): string {
  const id = (spellId ?? "").trim();
  if (id === "") return t("prompt.context.spell.unknown", locale);
  const key = `prompt.context.spell.${id}`;
  const label = t(key, locale);
  return label === key ? id : label;
}

export function renderSpellHitEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<SpellHitEventData>;
  const self = isSelfActor(event.actorId, viewerId);
  const actor = renderActorLabel(event.actorId, viewerId, locale);
  // 目标标签复用 actor-label：目标 === viewer 渲染成"你"。
  const target = renderActorLabel(data.targetCharacterId, viewerId, locale);
  const spell = spellName(data.spellId, locale);
  const outcome = String(data.outcome ?? "hit");

  let suffix = "";
  if (outcome === "blocked") suffix = "_blocked";
  else if (outcome === "failed") suffix = "_failed";

  const variant = self ? "self" : "other";
  const main = t(`prompt.context.event.spell_hit.${variant}${suffix}_format`, locale, {
    actor,
    target,
    spell,
  });
  return composeEventLine(event, viewerId, locale, main);
}
