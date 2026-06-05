import type { MessageBus } from "../plugins/message-bus.js";
import type { PerceptionManifestPayload } from "../godot-link/perception-manifest.js";

// 进程内 bus channel：Godot push 上来的 perception manifest 经此发给 agent runtime 入 cache。
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

export function publishPerceptionManifestToBus(
  bus: MessageBus,
  townId: string,
  manifest: PerceptionManifestPayload,
): number {
  return bus.publish(perceptionManifestBusChannel(townId), {
    characterId: manifest.characterId,
    manifest,
  } satisfies PerceptionManifestBusPayload);
}

export function parsePerceptionManifestBusPayload(raw: unknown): PerceptionManifestBusPayload {
  const payload = (raw ?? {}) as Partial<PerceptionManifestBusPayload>;
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
