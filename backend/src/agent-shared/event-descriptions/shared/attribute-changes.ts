// Summarize raw character-attribute deltas into a parenthesized prose suffix.
//
// Source shape (Godot/Lua produce this on action results):
//   character_changes: { attributes: [{ field, before, after }, ...] }
// Two entry points:
//   - summarizeCharacterChanges(data.result?.character_changes)  for direct attributes
//   - aggregateOpStaminaDeltas(data.result?.completed)            for plan_farm_work
//     which carries per-op stamina_before/stamina_after instead of a single change.
//
// Numbers are rounded to integers — stamina is a float internally but the LLM
// doesn't need 2.65 of a stamina point.

import { t, type Locale } from "../../../i18n/index.js";

type AttributeField = "stamina" | "hunger" | "rest";

const KNOWN_FIELDS: AttributeField[] = ["stamina", "hunger", "rest"];

export function summarizeAttributeChangesSuffix(
  changes: unknown,
  completed: unknown,
  locale: Locale,
): string {
  const totals = new Map<AttributeField, number>();
  applyAttributesList(changes, totals);
  aggregateCompletedStamina(completed, totals);
  const parts: string[] = [];
  for (const field of KNOWN_FIELDS) {
    const delta = totals.get(field);
    if (delta == null || delta === 0) continue;
    parts.push(formatDelta(field, delta, locale));
  }
  if (parts.length === 0) return "";
  const sep = t("prompt.context.event.attribute_changes.separator", locale);
  return t("prompt.context.event.attribute_changes.wrap_format", locale, { parts: parts.join(sep) });
}

function applyAttributesList(changes: unknown, totals: Map<AttributeField, number>): void {
  if (!changes || typeof changes !== "object") return;
  const attrs = (changes as Record<string, unknown>).attributes;
  if (!Array.isArray(attrs)) return;
  for (const entry of attrs) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    const field = typeof row.field === "string" ? row.field : "";
    if (!KNOWN_FIELDS.includes(field as AttributeField)) continue;
    const before = Number(row.before);
    const after = Number(row.after);
    if (!Number.isFinite(before) || !Number.isFinite(after)) continue;
    const delta = Math.round(after - before);
    totals.set(field as AttributeField, (totals.get(field as AttributeField) ?? 0) + delta);
  }
}

function aggregateCompletedStamina(completed: unknown, totals: Map<AttributeField, number>): void {
  if (!Array.isArray(completed)) return;
  let earliestBefore: number | undefined;
  let latestAfter: number | undefined;
  for (const op of completed) {
    if (!op || typeof op !== "object") continue;
    const row = op as Record<string, unknown>;
    const before = Number(row.stamina_before);
    const after = Number(row.stamina_after);
    if (Number.isFinite(before)) {
      earliestBefore ??= before;
    }
    if (Number.isFinite(after)) {
      latestAfter = after;
    }
  }
  if (earliestBefore == null || latestAfter == null) return;
  const delta = Math.round(latestAfter - earliestBefore);
  if (delta === 0) return;
  totals.set("stamina", (totals.get("stamina") ?? 0) + delta);
}

function formatDelta(field: AttributeField, delta: number, locale: Locale): string {
  const abs = Math.abs(delta);
  switch (field) {
    case "stamina":
      return t(
        delta < 0
          ? "prompt.context.event.attribute_changes.stamina_decrease_format"
          : "prompt.context.event.attribute_changes.stamina_increase_format",
        locale,
        { n: abs },
      );
    case "hunger":
      return t(
        delta < 0
          ? "prompt.context.event.attribute_changes.hunger_decrease_format"
          : "prompt.context.event.attribute_changes.hunger_increase_format",
        locale,
        { n: abs },
      );
    case "rest":
      return t(
        delta < 0
          ? "prompt.context.event.attribute_changes.rest_decrease_format"
          : "prompt.context.event.attribute_changes.rest_increase_format",
        locale,
        { n: abs },
      );
  }
}
