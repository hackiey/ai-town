// World event type registry + discriminated union.
//
// Per-event-type data shapes live in world-events.ts (the wire contract).
// This file glues them into the discriminated `WorldEvent` union the runtime
// uses, plus tracks "known type" ambient/unhandled event names.

import type { GameTimeSnapshot } from "./protocol.js";
import {
  isKnownWorldEventType as isKnownTypedEventType,
  type WorldEventDataByType,
  type WorldEventDataType,
} from "./world-events.js";

export const WENT_TO_SLEEP_EVENT = "went_to_sleep";
export const WOKE_UP_EVENT = "woke_up";

// Types that are recognized but don't have a typed data shape in world-events.ts
// — ambient broadcasts and bookkeeping events.
const AMBIENT_OR_UNHANDLED_EVENT_TYPES = [
  "pick_up_item",
  "plant_seed",
  "water_crop",
  "harvest_crop",
  "remove_pest",
  "write",
  "read",
  "create_item",
  "weather_changed",
  "market_price_changed",
  "time_advanced",
  // Control-plane events for player AI takeover. No perception meaning — handled
  // specially at the top of handleCharacterWorldEvent (like player_command) and
  // never enter pendingEvents. Listed here so the event-adapter allowlist passes
  // them through on both ingress and bus-replay. Carries agentType/actionModel/
  // thinkingModel on data (takeover); release only needs actorId.
  "ai_takeover",
  "ai_release",
] as const;

export type AmbientOrUnhandledEventType = (typeof AMBIENT_OR_UNHANDLED_EVENT_TYPES)[number];
export type WorldEventType = WorldEventDataType | AmbientOrUnhandledEventType;

export const WORLD_EVENT_TYPES: readonly WorldEventType[] = [
  ...AMBIENT_OR_UNHANDLED_EVENT_TYPES,
  ...(Object.keys({} as WorldEventDataByType) as WorldEventDataType[]),
  // Below list keeps WORLD_EVENT_TYPES enumerable for runtime checks.
  // Concrete values come from isKnownWorldEventType which delegates to world-events.ts.
];

type TypedEventBase<TType extends WorldEventDataType> = {
  eventId: string;
  type: TType;
  actorId?: string;
  spokenText?: string;
  data: WorldEventDataByType[TType];
  occurredAt: string;
  gameTime?: GameTimeSnapshot;
};

type AmbientEventBase = {
  eventId: string;
  type: AmbientOrUnhandledEventType;
  actorId?: string;
  spokenText?: string;
  data: Record<string, unknown> & {
    affectedCharacterIds: string[];
    gameTime?: GameTimeSnapshot;
  };
  occurredAt: string;
  gameTime?: GameTimeSnapshot;
};

type TypedWorldEvent = {
  [TType in WorldEventDataType]: TypedEventBase<TType>;
}[WorldEventDataType];

export type WorldEvent = TypedWorldEvent | AmbientEventBase;

export type UnknownWorldEvent = {
  eventId: string;
  type: string;
  actorId?: string;
  spokenText?: string;
  data?: Record<string, unknown>;
  occurredAt: string;
  gameTime?: GameTimeSnapshot;
};

const AMBIENT_TYPE_SET = new Set<string>(AMBIENT_OR_UNHANDLED_EVENT_TYPES);

export function isKnownWorldEventType(type: string): type is WorldEventType {
  return isKnownTypedEventType(type) || AMBIENT_TYPE_SET.has(type);
}
