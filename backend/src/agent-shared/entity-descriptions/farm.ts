// 农场状态描述：显示名 + 单行摘要（"共8格，空地3格，可收2格，待浇水3格"）+ slot 细节
// "第N块农田" 这种 fallback 名字也走 i18n。

import { getActiveLocale, t, type Locale } from "../../i18n/index.js";
import { locationName } from "../name-resolver/location.js";
import type { FarmContext, FarmSlotContext } from "../prompt-context/types.js";

export function farmDisplayName(farm: FarmContext, index: number): string {
  const displayId = farm.locationId ?? farm.id;
  const localized = locationName(displayId);
  return localized === displayId
    ? t("prompt.context.farm.name_default_format", getActiveLocale(), { n: index + 1 })
    : localized;
}

export function formatFarmSummary(farm: FarmContext): string | undefined {
  const locale = getActiveLocale();
  const explicitSummary = farm.statusSummary?.trim();
  const summary = explicitSummary || defaultFarmSummary(farm, locale);
  const slotDetails = formatFarmSlotDetails(farm, locale);
  if (summary && slotDetails) {
    return `${summary}；${slotDetails}`;
  }
  return summary ?? slotDetails;
}

function defaultFarmSummary(farm: FarmContext, locale: Locale): string | undefined {
  const totalSlots = farm.totalSlots ?? farm.slots.length;
  if (totalSlots <= 0) return undefined;
  const emptySlots = farm.emptySlots ?? farm.slots.filter((slot) => !slot.occupied).length;
  const ripeSlots = farm.ripeSlots ?? farm.slots.filter((slot) => slot.canHarvest ?? slot.ripe).length;
  const pestSlots = farm.pestSlots ?? farm.slots.filter((slot) => slot.needsPestControl ?? slot.hasPest).length;
  const drySlots = farm.drySlots ?? farm.slots.filter((slot) => slot.needsWater).length;
  const occupiedSlots = farm.occupiedSlots ?? Math.max(totalSlots - emptySlots, 0);
  const parts = [t("prompt.context.farm.summary_total_format", locale, { n: totalSlots })];
  if (emptySlots > 0) parts.push(t("prompt.context.farm.summary_empty_format", locale, { n: emptySlots }));
  if (ripeSlots > 0) parts.push(t("prompt.context.farm.summary_ripe_format", locale, { n: ripeSlots }));
  if (pestSlots > 0) parts.push(t("prompt.context.farm.summary_pest_format", locale, { n: pestSlots }));
  if (drySlots > 0) parts.push(t("prompt.context.farm.summary_dry_format", locale, { n: drySlots }));
  if (occupiedSlots > 0 && ripeSlots === 0 && pestSlots === 0 && drySlots === 0) {
    parts.push(t("prompt.context.farm.summary_planted_stable_format", locale, { n: occupiedSlots }));
  }
  return parts.join("，");
}

function formatFarmSlotDetails(farm: FarmContext, locale: Locale): string | undefined {
  if (farm.slots.length === 0) return undefined;
  const occupiedSlots = farm.slots.filter((slot) => slot.occupied).length || farm.occupiedSlots || 0;
  if (occupiedSlots <= 0) return undefined;
  const slots = [...farm.slots].sort((a, b) => a.index - b.index);
  const details = slots.map((slot) => formatFarmSlot(slot, locale)).join("；");
  return `${t("prompt.context.farm.slot_details_prefix", locale)}：${details}`;
}

function formatFarmSlot(slot: FarmSlotContext, locale: Locale): string {
  const label = t("prompt.context.farm.slot_label_format", locale, { n: slot.index });
  const explicitStatus = slot.statusText?.trim();
  if (explicitStatus) {
    return t("prompt.context.farm.slot_status_format", locale, { label, status: explicitStatus });
  }
  if (!slot.occupied) {
    return t("prompt.context.farm.slot_empty", locale, { label });
  }
  const tags = (slot.statusTags ?? [])
    .map((tag) => tag.trim())
    .filter((tag) => tag.length > 0);
  if (tags.length === 0) {
    if (slot.needsWater) tags.push(t("prompt.context.farm.flag_needs_water", locale));
    if (slot.needsPestControl ?? slot.hasPest) tags.push(t("prompt.context.farm.flag_has_pest", locale));
    if (slot.canHarvest ?? slot.ripe) tags.push(t("prompt.context.farm.flag_can_harvest", locale));
  }
  const statusParts = [
    slot.displayName?.trim() || slot.variety?.trim(),
    slot.stageDisplay?.trim() || slot.stage?.trim(),
    tags.length > 0 ? tags.join(", ") : undefined,
  ].filter((part): part is string => Boolean(part));
  const status = statusParts.length > 0
    ? statusParts.join(" · ")
    : t("prompt.context.farm.slot_unknown_status", locale);
  return t("prompt.context.farm.slot_status_format", locale, { label, status });
}
