// Single source of truth for the `world_events.data` column shape, per event type.
// Lua mechs (data/mechanics/*.lua) and GDScript emit sites must produce these exact
// shapes. Backend readers cast event.data to the matching type and read by single key.
//
// Rules:
//  - All event data sets `actorId` (backend extracts to event.actorId at write time).
//  - All event data sets `affectedCharacterIds: string[]` — used by both
//    BackendRuntimeClient.send_world_event for snapshot-flush AND by readers for
//    visibility/audience filtering. Single canonical name; no `visibleTo*` alias.
//  - camelCase everywhere. No snake_case duplicates. No `to`/`qty`/`count` aliases.
//  - Logical "actor" appears exactly once. Don't also write `characterId` as
//    a synonym for actorId — that's the rot the previous schema accumulated.
//
// These types are NOT runtime-validated (Godot is the authority per
// [feedback_godot_is_authority]); they're a compile-time contract for readers.

import type { GameTimeSnapshot } from "./protocol.js";
import type { TradeLine } from "./actions.js";

// Common base fields present in every event payload.
export type WorldEventDataBase = {
  actorId: string;
  affectedCharacterIds: string[];
  gameTime?: GameTimeSnapshot;
};

// ─── say_to ──────────────────────────────────────────────────────────
// Speaker says something at `volume`. The spoken words live on
// WorldEventRecord.spokenText (single canonical home). `targetCharacterId`
// absent = ambient broadcast, present = directed line. Display names are
// resolved from `actorId` via the i18n catalog at render time — never
// shipped on the wire (Godot has no locale awareness).
export type SayToEventData = WorldEventDataBase & {
  volume: "near" | "far" | "shout";
  targetCharacterId?: string;
};

// ─── trade ───────────────────────────────────────────────────────────
// Buyer makes offer to seller. actorId = buyer for offer, actorId = seller for respond.
// Renderers use buyer/seller directly — no actor/target aliasing.
export type OfferTradeEventData = WorldEventDataBase & {
  buyerCharacterId: string;
  sellerCharacterId: string;
  tradeId: string;
  offer: TradeLine[];
  request: TradeLine[];
};

export type RespondToTradeEventData = WorldEventDataBase & {
  buyerCharacterId: string;
  sellerCharacterId: string;
  tradeId: string;
  response: "accept" | "reject" | "cancelled";
  offer?: TradeLine[];
  request?: TradeLine[];
};

// ─── give ────────────────────────────────────────────────────────────
// 单向赠送（offer 工具 request:[] 触发）。actorId = giver。
// recipient 和 giver 都进 affectedCharacterIds 让感知分类分别处理：
// giver=ignored（tool response sync 返回）/ recipient=direct_speech 触发 turn。
// items 只列实际 transferred>0 的项；leftover 留在 giver 背包不在事件里报。
export type GiveEventData = WorldEventDataBase & {
  recipientCharacterId: string;
  items: Array<{ itemId: string; quantity: number }>;
};

// ─── sleep ───────────────────────────────────────────────────────────
export type WentToSleepEventData = WorldEventDataBase & {
  durationGameMinutes: number;
};

export type WokeUpEventData = WorldEventDataBase & {
  durationGameMinutes: number;
  reason?: string;
};

// ─── container ───────────────────────────────────────────────────────
// deposited/withdrawn carry the moved item; inspected reports itemCount only.
export type ContainerInspectedEventData = WorldEventDataBase & {
  containerId: string;
  itemCount: number;
};

export type ContainerMoveEventData = WorldEventDataBase & {
  containerId: string;
  itemId: string;
  quantity: number;
};

// ─── shelf ───────────────────────────────────────────────────────────
export type ShelfUpdatedEventData = WorldEventDataBase & {
  shelfId: string;
  locationId?: string;
  changes: string[];
};

export type ShelfItemSoldEventData = WorldEventDataBase & {
  shelfId: string;
  listingId: string;
  buyerCharacterId: string;
  sellerCharacterId: string;
  item: Record<string, unknown>;
  quantity: number;
  // priceCenti 是 DB / wire 真值（int, 1 silver = 100 centi）。
  // priceSilver = priceCenti / 100 是用于显示的 float silver。
  priceCenti: number;
  priceSilver: number;
  locationId?: string;
  tradeId?: string;
};

// ─── item / workstation ──────────────────────────────────────────────
export type UseItemEventData = WorldEventDataBase & {
  itemId: string;
  targetId?: string;
};

// outcome="success"|"failure"; outputs/leftover lists when success; fail_mode_name
// names the lua-side failure category when failure. Renderer composes prose.
//
// Proficiency 字段两档（见 src/sim/workstations/workstation_action_runner.gd::_send_world_event）：
//   1. skillId / before / difficulty —— 任何带 skill 的反应（非 mining）都发。Renderer 用作
//      失败因果行 "（难度 X / 熟练度 Y / 料子状态）"，所有 viewer 可见。
//   2. after / delta —— 仅当 |delta| ≥ 0.5 才发。Renderer 用作"长进/突破/退步" suffix，
//      只对 actor 自己渲染（数值成长是私密反馈）。
//
// 9 个工作台手艺 axis（mine / woodwork / smelt / smith / assemble / cook / mill_grain /
// boil_salt / burn_charcoal）+ draw_water 全部共用这个 shape，event 类型名只
// 用来路由到对应 renderer key。详见 docs/proficiency_system.md 和 craft-registry.ts。
//
// 原料折损 / 退回信息不在这条 event 上 —— actor 自己在 tool_response 的
// character_changes.backpack 已经能看到（renderAgentBackpackChange "失去 X x1"）。
export type WorkstationEventData = WorldEventDataBase & {
  workstationId: string;
  verb?: string;
  outcome?: "success" | "failure";
  outputs?: string[];
  leftoverOutputs?: string[];
  failModeName?: string;
  proficiencySkillId?: string;
  proficiencyBefore?: number;
  proficiencyAfter?: number;
  proficiencyDelta?: number;
  difficulty?: number;
};

// 兼容别名 —— 现有 event renderer 仍叫 renderUseWorkstationEventLine，类型签名复用此名。
// 等 renderer/导入处全部 rename 后可删。
export type UseWorkstationEventData = WorkstationEventData;

export type DropItemEventData = WorldEventDataBase & {
  itemId: string;
  quantity: number;
};

// ─── public finish (move_to_location / plan_farm_work) ───────────────
// Emitted when actor finishes a durative action so others see "X arrived at Y".
// `target` echoes the original ActionTarget (already canonical via actions.ts).
export type PublicFinishEventData = WorldEventDataBase & {
  target: Record<string, unknown>;
  result?: Record<string, unknown>;
  error?: string;
};

// ─── player_command ──────────────────────────────────────────────────
// Emitted by backend (godot-message-handler.ts) when a player types a command.
// For player events, actor = player character itself; no separate target.
// The typed command text lives on WorldEventRecord.spokenText.
export type PlayerCommandEventData = WorldEventDataBase;

// ─── exhaustive map ──────────────────────────────────────────────────
export type WorldEventDataByType = {
  say_to: SayToEventData;
  offer_trade: OfferTradeEventData;
  respond_to_trade: RespondToTradeEventData;
  went_to_sleep: WentToSleepEventData;
  woke_up: WokeUpEventData;
  container_inspected: ContainerInspectedEventData;
  container_deposited: ContainerMoveEventData;
  container_withdrawn: ContainerMoveEventData;
  shelf_updated: ShelfUpdatedEventData;
  shelf_item_sold: ShelfItemSoldEventData;
  use_item: UseItemEventData;
  // 9 个 axis event + draw_water —— 全部共用 WorkstationEventData shape。
  mine: WorkstationEventData;
  woodwork: WorkstationEventData;
  burn_charcoal: WorkstationEventData;
  smelt: WorkstationEventData;
  smith: WorkstationEventData;
  assemble: WorkstationEventData;
  cook: WorkstationEventData;
  mill_grain: WorkstationEventData;
  boil_salt: WorkstationEventData;
  draw_water: WorkstationEventData;
  drop_item: DropItemEventData;
  give: GiveEventData;
  move_to_location: PublicFinishEventData;
  plan_farm_work: PublicFinishEventData;
  player_command: PlayerCommandEventData;
};

export type WorldEventDataType = keyof WorldEventDataByType;

export function isKnownWorldEventType(type: string): type is WorldEventDataType {
  return type in WORLD_EVENT_TYPE_MARKER;
}

const WORLD_EVENT_TYPE_MARKER: Record<WorldEventDataType, true> = {
  say_to: true,
  offer_trade: true,
  respond_to_trade: true,
  went_to_sleep: true,
  woke_up: true,
  container_inspected: true,
  container_deposited: true,
  container_withdrawn: true,
  shelf_updated: true,
  shelf_item_sold: true,
  use_item: true,
  mine: true,
  woodwork: true,
  burn_charcoal: true,
  smelt: true,
  smith: true,
  assemble: true,
  cook: true,
  mill_grain: true,
  boil_salt: true,
  draw_water: true,
  drop_item: true,
  give: true,
  move_to_location: true,
  plan_farm_work: true,
  player_command: true,
};
