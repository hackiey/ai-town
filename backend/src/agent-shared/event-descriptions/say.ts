// say_to renderer. "X 对 Y 说（音量）:「内容」" with self → "你".
//
// Actor/target labels are resolved by id through the shared resolver — no
// display-name field on the wire. The spoken words live on
// WorldEventRecord.spokenText (single canonical home — no per-type duplication).

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { SayToEventData } from "../../godot-link/world-events.js";
import { characterDisplayName, localizeText } from "../name-resolver/index.js";
import { renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

// 听者烂醉（drunkTier === "wasted"）时连别人的话都听不清——逐字符糊成符号。听自己说的话不糊。
// 门槛走 Godot 算好的档位 key，不在这里复制阈值数（见 docs/architecture/impairment-system.md §2）。
// 乱码强度 viewerDrunk/120 是听者侧独有曲线（Godot 无对应），保留为本地常量。符号池与 GDScript 一致。
const GARBLE_POOL = "%^$#@&*";

function garbleHeard(text: string, viewerDrunk: number, viewerDrunkTier: string): string {
  if (viewerDrunkTier !== "wasted" || !text) return text;
  const p = Math.min(0.9, viewerDrunk / 120);
  let out = "";
  for (const ch of text) {
    if (ch === " " || ch === "\n" || ch === "\t") out += ch;
    else if (Math.random() < p) out += GARBLE_POOL[Math.floor(Math.random() * GARBLE_POOL.length)];
    else out += ch;
  }
  return out;
}

export function renderSayToEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
  viewerDrunk: number = 0,
  viewerDrunkTier: string = "",
): string {
  const data = (event.data ?? {}) as Partial<SayToEventData>;
  let spoken = event.spokenText ? localizeText(event.spokenText) : "";
  // 听自己说的不糊；听别人说的，烂醉时糊。
  if (event.actorId !== viewerId) spoken = garbleHeard(spoken, viewerDrunk, viewerDrunkTier);
  const actorLabel = renderActorLabel(event.actorId, viewerId, locale);
  const volumeLabel = data.volume ?? t("prompt.context.speak.volume_unknown", locale);

  let main: string;
  if (!data.targetCharacterId) {
    main = t("prompt.context.speak.simple_format", locale, {
      actor: actorLabel, volume: volumeLabel, text: spoken,
    });
  } else {
    const targetId = data.targetCharacterId;
    const targetLabel = targetId === viewerId
      ? t("prompt.context.event.self_pronoun", locale)
      : characterDisplayName(targetId, locale);
    main = t("prompt.context.speak.to_target_simple_format", locale, {
      actor: actorLabel, target: targetLabel, volume: volumeLabel, text: spoken,
    });
  }
  return composeEventLine(event, viewerId, locale, main.trim());
}
