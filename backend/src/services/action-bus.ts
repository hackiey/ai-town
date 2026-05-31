import type { Redis } from "ioredis";

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

export async function publishActionToBus(redis: Redis, townId: string, actionId: string): Promise<number> {
  return redis.publish(actionBusChannel(townId), JSON.stringify({ kind: "deliver", actionId } satisfies ActionBusPayload));
}

export async function publishActionCancelToBus(redis: Redis, townId: string, actionId: string): Promise<number> {
  return redis.publish(actionBusChannel(townId), JSON.stringify({ kind: "cancel", actionId } satisfies ActionBusPayload));
}

export function parseActionBusPayload(raw: string): ActionBusPayload {
  const payload = JSON.parse(raw) as Partial<ActionBusPayload>;
  const actionId = payload.actionId;
  if (!actionId || typeof actionId !== "string") {
    throw new Error("action bus payload missing actionId");
  }
  if (payload.kind !== undefined && payload.kind !== "deliver" && payload.kind !== "cancel") {
    throw new Error("action bus payload has unsupported kind");
  }
  return { kind: payload.kind ?? "deliver", actionId };
}
