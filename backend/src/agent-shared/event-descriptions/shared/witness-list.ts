// "在场: A、B" suffix for events. Lists witnesses excluding the actor and the
// viewer themselves. Empty when no third parties witnessed it.
//
// Why drop viewer: the viewer is reading their own history; "在场 includes 你"
// is noise. Why drop actor: actor is already named in the main sentence.

import { t, type Locale } from "../../../i18n/index.js";
import type { WorldEventRecord } from "../../../godot-link/protocol.js";
import { localizeStringValue } from "../../name-resolver/index.js";

export function renderWitnessSuffix(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const ids = affectedCharacterIds(event);
  const skip = new Set<string>();
  if (event.actorId) skip.add(event.actorId);
  skip.add(viewerId);
  const labels: string[] = [];
  for (const id of ids) {
    if (skip.has(id)) continue;
    labels.push(localizeStringValue(id) ?? id);
  }
  if (labels.length === 0) return "";
  return t("prompt.context.event.witness_list_format", locale, { names: labels.join(t("prompt.context.event.list_separator", locale)) });
}

function affectedCharacterIds(event: WorldEventRecord): string[] {
  const data = event.data ?? {};
  const raw = data.affectedCharacterIds;
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const entry of raw) {
    if (typeof entry === "string" && entry.length > 0) out.push(entry);
  }
  return out;
}
