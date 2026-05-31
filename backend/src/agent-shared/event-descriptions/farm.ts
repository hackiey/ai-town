// plan_farm_work renderer. Collapses the per-op completed[] list into
// counts per (verb, target) — never dumps the raw 16-row array of
// kind=plant, slot_index=…, stamina_after=53.4 nonsense.
//
// Data shape: PublicFinishEventData with result.completed = [{
//   kind: "plant"|"water"|"harvest"|"uproot"|"pest",
//   result?: { message?, ok?, ... },
//   stamina_before, stamina_after, slot_index, ...
// }, ...] and result.interrupted: bool.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { PublicFinishEventData } from "../../godot-link/world-events.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

const VERB_KEY: Record<string, string> = {
  plant: "prompt.context.event.plan_farm_work.verb_plant",
  water: "prompt.context.event.plan_farm_work.verb_water",
  harvest: "prompt.context.event.plan_farm_work.verb_harvest",
  uproot: "prompt.context.event.plan_farm_work.verb_uproot",
  pest: "prompt.context.event.plan_farm_work.verb_pest",
};

export function renderPlanFarmWorkEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<PublicFinishEventData>;
  const result = (data.result ?? {}) as Record<string, unknown>;
  const completed = Array.isArray(result.completed) ? result.completed : [];
  const summary = summarizeOps(completed, locale)
    || t("prompt.context.event.plan_farm_work.empty_summary", locale);
  const interrupted = result.interrupted === true;
  const interruptSuffix = interrupted ? t("prompt.context.event.plan_farm_work.interrupted_suffix", locale) : "";
  const main = (isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.plan_farm_work.self_format", locale, { summary })
    : t("prompt.context.event.plan_farm_work.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
        summary,
      })) + interruptSuffix;
  return composeEventLine(event, viewerId, locale, main, {
    completedOps: completed,
  });
}

type OpBucket = { verb: string; target: string | undefined; count: number };

function summarizeOps(ops: unknown[], locale: Locale): string {
  const buckets = new Map<string, OpBucket>();
  for (const entry of ops) {
    if (!entry || typeof entry !== "object") continue;
    const op = entry as Record<string, unknown>;
    const kind = typeof op.kind === "string" ? op.kind : "";
    if (!kind) continue;
    const target = extractOpTarget(op);
    const key = `${kind}|${target ?? ""}`;
    const bucket = buckets.get(key) ?? { verb: kind, target, count: 0 };
    bucket.count += 1;
    buckets.set(key, bucket);
  }
  if (buckets.size === 0) return "";
  const parts: string[] = [];
  for (const bucket of buckets.values()) {
    const verbLabel = VERB_KEY[bucket.verb] ? t(VERB_KEY[bucket.verb], locale) : bucket.verb;
    if (bucket.target) {
      parts.push(t("prompt.context.event.plan_farm_work.op_format", locale, {
        verb: verbLabel,
        target: bucket.target,
        count: bucket.count,
      }));
    } else {
      parts.push(t("prompt.context.event.plan_farm_work.op_format_no_target", locale, {
        verb: verbLabel,
        count: bucket.count,
      }));
    }
  }
  return parts.join(t("prompt.context.event.attribute_changes.separator", locale));
}

function extractOpTarget(op: Record<string, unknown>): string | undefined {
  // Lua / GDScript may put the planted seed or harvest yield into different
  // fields depending on op kind. Inspect the per-op result message structure
  // when present; otherwise look for common id fields.
  const directIds = ["seedItemId", "seed_id", "item_id", "itemId"];
  for (const key of directIds) {
    const v = op[key];
    if (typeof v === "string" && v.length > 0) return localizeStringValue(v) ?? v;
  }
  const result = op.result;
  if (result && typeof result === "object") {
    const row = result as Record<string, unknown>;
    for (const key of directIds) {
      const v = row[key];
      if (typeof v === "string" && v.length > 0) return localizeStringValue(v) ?? v;
    }
  }
  return undefined;
}
