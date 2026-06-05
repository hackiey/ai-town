import type { MessageBus } from "../plugins/message-bus.js";

export const ACTION_BUS_PATTERN = "town:*:actions";

type ActionBusPayload = {
  kind?: "deliver" | "cancel";
  actionId: string;
};

export function actionBusChannel(townId: string): string {
  return `town:${townId}:actions`;
}

export function parseActionBusChannel(channel: string): string | null {
  const match = /^town:(.+):actions$/.exec(channel);
  return match?.[1] ?? null;
}

export function publishActionToBus(bus: MessageBus, townId: string, actionId: string): number {
  return bus.publish(actionBusChannel(townId), { kind: "deliver", actionId } satisfies ActionBusPayload);
}

export function publishActionCancelToBus(bus: MessageBus, townId: string, actionId: string): number {
  return bus.publish(actionBusChannel(townId), { kind: "cancel", actionId } satisfies ActionBusPayload);
}

export function parseActionBusPayload(raw: unknown): ActionBusPayload {
  const payload = (raw ?? {}) as Partial<ActionBusPayload>;
  const actionId = payload.actionId;
  if (!actionId || typeof actionId !== "string") {
    throw new Error("action bus payload missing actionId");
  }
  if (payload.kind !== undefined && payload.kind !== "deliver" && payload.kind !== "cancel") {
    throw new Error("action bus payload has unsupported kind");
  }
  return { kind: payload.kind ?? "deliver", actionId };
}
