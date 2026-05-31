// Common scaffolding for per-event-type renderers:
//   "[type]: <main sentence> <(attribute-suffix)> <在场: ...>"
// Renderers return just the main sentence; this glue prepends the type tag and
// appends suffixes that apply uniformly across event types.

import type { Locale } from "../../../i18n/index.js";
import type { WorldEventRecord } from "../../../godot-link/protocol.js";
import { summarizeAttributeChangesSuffix } from "./attribute-changes.js";
import { renderWitnessSuffix } from "./witness-list.js";

export type ComposeOptions = {
  attributeChanges?: unknown;
  completedOps?: unknown;
  appendWitnesses?: boolean;
  // Skip the auto "[type]" prefix when the renderer already embeds the type
  // tag in its main sentence (only the fallback renderer needs this).
  skipTypePrefix?: boolean;
};

export function composeEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
  mainSentence: string,
  options: ComposeOptions = {},
): string {
  const parts: string[] = [];
  if (!options.skipTypePrefix) parts.push(`[${event.type}]`);
  if (mainSentence) parts.push(mainSentence);
  const attrSuffix = summarizeAttributeChangesSuffix(
    options.attributeChanges,
    options.completedOps,
    locale,
  );
  if (attrSuffix) parts.push(attrSuffix);
  if (options.appendWitnesses !== false) {
    const witness = renderWitnessSuffix(event, viewerId, locale);
    if (witness) parts.push(`〔${witness}〕`);
  }
  return parts.join(" ");
}
