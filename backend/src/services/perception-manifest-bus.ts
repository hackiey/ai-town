import type { Redis } from "ioredis";
import type { PerceptionManifestPayload } from "../godot-link/perception-manifest.js";

// Redis pub/sub channel：fastify HTTP 进程接到 Godot push 后发，worker 进程订阅入 cache。
// 同 character-snapshot-bus 一一对应；P7 删 snapshot bus 后这是唯一的 perception 通道。
export const PERCEPTION_MANIFEST_BUS_PATTERN = "character.perception_manifest:*";

export type PerceptionManifestBusPayload = {
  characterId: string;
  manifest: PerceptionManifestPayload;
};

export function perceptionManifestBusChannel(townId: string): string {
  return `character.perception_manifest:${townId}`;
}

export function parsePerceptionManifestBusChannel(channel: string): string | null {
  const match = /^character\.perception_manifest:(.+)$/.exec(channel);
  return match?.[1] ?? null;
}

export async function publishPerceptionManifestToBus(
  redis: Redis,
  townId: string,
  manifest: PerceptionManifestPayload,
): Promise<number> {
  return redis.publish(perceptionManifestBusChannel(townId), JSON.stringify({
    characterId: manifest.characterId,
    manifest,
  } satisfies PerceptionManifestBusPayload));
}

export function parsePerceptionManifestBusPayload(raw: string): PerceptionManifestBusPayload {
  const payload = JSON.parse(raw) as Partial<PerceptionManifestBusPayload>;
  if (!payload.characterId || typeof payload.characterId !== "string") {
    throw new Error("perception manifest bus payload missing characterId");
  }
  if (!payload.manifest || typeof payload.manifest !== "object") {
    throw new Error("perception manifest bus payload missing manifest");
  }
  return {
    characterId: payload.characterId,
    manifest: payload.manifest as PerceptionManifestPayload,
  };
}
