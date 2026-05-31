// Per-event-type renderer dispatch. Single entry point: renderEventLine(event,
// viewerId, locale) returns the full prompt line including the [type] tag,
// attribute-change suffix, and 在场 list — all viewpoint-aware (actor === viewer
// becomes "你").
//
// Architecture: Godot/Lua ship pure structured event.data — no prose, no
// `text` field. Per-type renderers in this directory compose readable prose
// from the structured fields. New event types must register a renderer here;
// otherwise they get the fallback line `[type] {actor} 做了一件事`, which is
// a signal to add a dedicated renderer.

import type { Locale } from "../../i18n/index.js";
import { SAY_TO_ACTION } from "../../godot-link/actions.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import {
  renderContainerDepositedEventLine,
  renderContainerInspectedEventLine,
  renderContainerWithdrawnEventLine,
} from "./container.js";
import { renderFallbackEventLine } from "./fallback.js";
import { renderPlanFarmWorkEventLine } from "./farm.js";
import {
  renderHarvestCropEventLine,
  renderPlantSeedEventLine,
  renderRemovePestEventLine,
  renderWaterCropEventLine,
} from "./farming.js";
import { renderGiveEventLine } from "./give.js";
import { renderDropItemEventLine, renderUseItemEventLine } from "./item.js";
import { renderMoveToLocationEventLine } from "./move.js";
import { renderSayToEventLine } from "./say.js";
import { renderShelfItemSoldEventLine, renderShelfUpdatedEventLine } from "./shelf.js";
import { renderWentToSleepEventLine, renderWokeUpEventLine } from "./sleep.js";
import { renderOfferTradeEventLine, renderRespondToTradeEventLine } from "./trade.js";
import { renderUseWorkstationEventLine } from "./workstation.js";

type EventLineRenderer = (event: WorldEventRecord, viewerId: string, locale: Locale) => string;

const RENDERERS: Record<string, EventLineRenderer> = {
  say_to: renderSayToEventLine,
  offer_trade: renderOfferTradeEventLine,
  respond_to_trade: renderRespondToTradeEventLine,
  went_to_sleep: renderWentToSleepEventLine,
  woke_up: renderWokeUpEventLine,
  container_inspected: renderContainerInspectedEventLine,
  container_deposited: renderContainerDepositedEventLine,
  container_withdrawn: renderContainerWithdrawnEventLine,
  shelf_updated: renderShelfUpdatedEventLine,
  shelf_item_sold: renderShelfItemSoldEventLine,
  use_item: renderUseItemEventLine,
  // 9 个 axis event + draw_water 全部走同一个 workstation 渲染器（事件数据 shape 相同）。
  // 见 docs/proficiency_system.md + agent-shared/game-tools/craft-registry.ts。
  mine: renderUseWorkstationEventLine,
  woodwork: renderUseWorkstationEventLine,
  burn_charcoal: renderUseWorkstationEventLine,
  smelt: renderUseWorkstationEventLine,
  smith: renderUseWorkstationEventLine,
  assemble: renderUseWorkstationEventLine,
  cook: renderUseWorkstationEventLine,
  mill_grain: renderUseWorkstationEventLine,
  boil_salt: renderUseWorkstationEventLine,
  draw_water: renderUseWorkstationEventLine,
  drop_item: renderDropItemEventLine,
  give: renderGiveEventLine,
  move_to_location: renderMoveToLocationEventLine,
  plan_farm_work: renderPlanFarmWorkEventLine,
  plant_seed: renderPlantSeedEventLine,
  water_crop: renderWaterCropEventLine,
  harvest_crop: renderHarvestCropEventLine,
  remove_pest: renderRemovePestEventLine,
};

export function renderEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const renderer = RENDERERS[event.type] ?? renderFallbackEventLine;
  return renderer(event, viewerId, locale);
}

export function isSayToEventType(type: string): boolean {
  return type === SAY_TO_ACTION;
}

// Game-time label helper kept on this module since it pairs with event
// rendering at most call sites.
export { renderEventGameTimeLabel, eventNormalizedGameTime } from "./game-time.js";
