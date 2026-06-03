// action_failed renderer. An actor's action was rejected (mechanic refused,
// distance check failed, pre-submit validation failed…). Self-only by
// construction (affectedCharacterIds = [actor]), so this line only ever renders
// for the viewer-as-actor; observers never receive the event.
//
// say_to failures get a dedicated phrasing that surfaces the attempted words and
// the (resolved) target name; every other action falls back to a generic
// "你尝试{动作}没成：{原因}" line. Per [[feedback_llm_id_name_boundary]] the raw
// reject reason often embeds a character slug (e.g. "...out of near range:
// garr_hollow") — we resolve that trailing slug to a display name.

import { has, t, type Locale } from "../../i18n/index.js";
import { SAY_TO_ACTION } from "../../godot-link/actions.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { ActionFailedEventData } from "../../godot-link/world-events.js";
import { characterDisplayName, localizeText } from "../name-resolver/index.js";
import { composeEventLine } from "./shared/compose.js";

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

// Reject reasons from lua/Godot can end with ": <character-slug>". Swap that
// trailing slug for a human name so the LLM never sees a raw id
// ([[feedback_llm_id_name_boundary]]). characterDisplayName returns the slug
// unchanged for non-characters, so a differing result means it resolved.
function humanizeReason(reason: string, locale: Locale): string {
  const trimmed = reason.trim();
  if (!trimmed) return t("prompt.context.event.action_failed.reason_unknown", locale);
  const m = trimmed.match(/^(.*:\s*)([a-z0-9_]+)$/i);
  if (!m) return trimmed;
  const name = characterDisplayName(m[2], locale);
  return name && name !== m[2] ? `${m[1]}${name}` : trimmed;
}

export function renderActionFailedEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<ActionFailedEventData>;
  const target = (data.target ?? {}) as Record<string, unknown>;
  const reason = humanizeReason(str(data.error), locale);

  let main: string;
  if (data.action === SAY_TO_ACTION) {
    const spokenRaw = str(data.spokenText) || str(target.text);
    const text = spokenRaw ? localizeText(spokenRaw) : "";
    const targetId = str(target.targetCharacterId);
    if (targetId) {
      const targetLabel = targetId === viewerId
        ? t("prompt.context.event.self_pronoun", locale)
        : characterDisplayName(targetId, locale);
      main = t("prompt.context.event.action_failed.say_to_format", locale, {
        target: targetLabel, text, reason,
      });
    } else {
      main = t("prompt.context.event.action_failed.say_to_no_target_format", locale, {
        text, reason,
      });
    }
  } else {
    const labelKey = `prompt.context.action_label.${str(data.action)}`;
    const actionLabel = str(data.action) && has(labelKey, locale) ? t(labelKey, locale) : str(data.action);
    main = t("prompt.context.event.action_failed.generic_format", locale, {
      action: actionLabel, reason,
    });
  }

  // Self-only event: no witness suffix, no attribute suffix.
  return composeEventLine(event, viewerId, locale, main.trim(), { appendWitnesses: false });
}
