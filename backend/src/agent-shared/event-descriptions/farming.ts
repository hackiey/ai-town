// Granular farming events emitted as singletons (plant_seed / water_crop /
// harvest_crop / remove_pest). These are AmbientOrUnhandledEventType — no
// typed data shape — so we read fields defensively.

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import { localizeStringValue } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderPlantSeedEventLine(event: WorldEventRecord, viewerId: string, locale: Locale): string {
  const seedId = readSeedId(event.data);
  const seed = seedId ? (localizeStringValue(seedId) ?? seedId) : "";
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.plant_seed.self_format", locale, { seed })
    : t("prompt.context.event.plant_seed.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
        seed,
      });
  return composeEventLine(event, viewerId, locale, main, {
    attributeChanges: readCharacterChanges(event.data),
  });
}

export function renderWaterCropEventLine(event: WorldEventRecord, viewerId: string, locale: Locale): string {
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.water_crop.self_format", locale)
    : t("prompt.context.event.water_crop.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
      });
  return composeEventLine(event, viewerId, locale, main, {
    attributeChanges: readCharacterChanges(event.data),
  });
}

export function renderHarvestCropEventLine(event: WorldEventRecord, viewerId: string, locale: Locale): string {
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.harvest_crop.self_format", locale)
    : t("prompt.context.event.harvest_crop.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
      });
  return composeEventLine(event, viewerId, locale, main, {
    attributeChanges: readCharacterChanges(event.data),
  });
}

export function renderRemovePestEventLine(event: WorldEventRecord, viewerId: string, locale: Locale): string {
  const main = isSelfActor(event.actorId, viewerId)
    ? t("prompt.context.event.remove_pest.self_format", locale)
    : t("prompt.context.event.remove_pest.other_format", locale, {
        actor: renderActorLabel(event.actorId, viewerId, locale),
      });
  return composeEventLine(event, viewerId, locale, main, {
    attributeChanges: readCharacterChanges(event.data),
  });
}

function readSeedId(data: unknown): string | undefined {
  if (!data || typeof data !== "object") return undefined;
  const row = data as Record<string, unknown>;
  const target = row.target;
  if (target && typeof target === "object") {
    const t = target as Record<string, unknown>;
    for (const key of ["seedItemId", "seed_id", "itemId", "item_id"]) {
      const v = t[key];
      if (typeof v === "string" && v.length > 0) return v;
    }
  }
  for (const key of ["seedItemId", "seed_id", "itemId", "item_id"]) {
    const v = row[key];
    if (typeof v === "string" && v.length > 0) return v;
  }
  return undefined;
}

function readCharacterChanges(data: unknown): unknown {
  if (!data || typeof data !== "object") return undefined;
  const result = (data as Record<string, unknown>).result;
  if (!result || typeof result !== "object") return undefined;
  return (result as Record<string, unknown>).character_changes;
}
