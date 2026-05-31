import type { GameTimeSnapshot } from "./protocol.js";

// Godot 推上来的 perception 清单：演员主观感知 dump（带 perception band），
// 不携带世界客观状态（hp/库存/田里几格熟了）—— 那些 backend SELECT sqlite 当场拼。
//
// "band" 是演员相对位置算出来的事实（"我离这东西多近"、"我能不能直接动它"）。
// 这些事实 sqlite 存不下（不属于任一实体本身），也不能由 backend 重推（backend 没有
// approach marker 位置、视线、墙体）—— 只能 Godot 算好往 manifest 里塞。
//
// Band 语义：
//   - "direct"  仅交互站点（workstation/farm/shelf）：演员已在该 site 的 approach 距离内
//   - "near"    在感知近半径内，可以观察/交互（但 site 类还没到 approach）
//   - "far"     在感知远半径内，能看到但无法（直接）互动
// 地点感知严格按距离过滤——"NPC 知道哪些地点存在"另走 knownLocationIds，
// 与实时感知解耦，避免私人麦圃被 NPC 隔半张地图"看到"。
export type PerceptionBand = "direct" | "near" | "far";

export type PerceivedRef = {
  id: string;
  band: PerceptionBand;
};

export type PerceptionManifestPayload = {
  characterId: string;
  selfLocationId: string;
  selfIsAsleep: boolean;
  gameTime?: GameTimeSnapshot;
  characterGroupIds: string[];
  perceivedLocations: PerceivedRef[];
  // "演员知道存在但不一定看得见"的全 top-level location id 集合（含 Marker3D 顶层、
  // WorkstationNode、FarmGroup）。用来填 visibleLocations / move_to_location enum；
  // perceivedLocations 只承担"实时感知"语义，二者解耦。
  knownLocationIds: string[];
  perceivedCharacters: PerceivedRef[];
  perceivedItems: PerceivedRef[];
  perceivedFarms: PerceivedRef[];
  // 容器是 WorkstationNode 子类，统一走本字段；不再单独 perceivedContainerIds。
  perceivedWorkstations: PerceivedRef[];
  perceivedShelves: PerceivedRef[];
  occurredAt?: string;
};

export type PerceptionManifest = PerceptionManifestPayload & {
  receivedAt: number;
};

export type NormalizeManifestPayloadResult =
  | { ok: true; manifest: PerceptionManifestPayload; occurredAt: string }
  | { ok: false; error: string };

export function normalizeManifestPayload(payload: Record<string, unknown>, now = new Date().toISOString()): NormalizeManifestPayloadResult {
  const characterId = stringValue(payload.characterId) ?? stringValue(payload.character_id);
  if (!characterId) {
    return { ok: false, error: "perception manifest missing characterId" };
  }
  const manifest: PerceptionManifestPayload = {
    characterId,
    selfLocationId: stringValue(payload.selfLocationId) ?? stringValue(payload.currentLocationId) ?? "unknown",
    selfIsAsleep: payload.selfIsAsleep === true,
    gameTime: objectValue(payload.gameTime) as GameTimeSnapshot | undefined,
    characterGroupIds: stringArray(payload.characterGroupIds),
    perceivedLocations: perceivedRefArray(payload.perceivedLocations),
    knownLocationIds: stringArray(payload.knownLocationIds),
    perceivedCharacters: perceivedRefArray(payload.perceivedCharacters),
    perceivedItems: perceivedRefArray(payload.perceivedItems),
    perceivedFarms: perceivedRefArray(payload.perceivedFarms),
    perceivedWorkstations: perceivedRefArray(payload.perceivedWorkstations),
    perceivedShelves: perceivedRefArray(payload.perceivedShelves),
    occurredAt: stringValue(payload.occurredAt) ?? now,
  };
  return { ok: true, manifest, occurredAt: manifest.occurredAt! };
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((entry): entry is string => typeof entry === "string" && entry.length > 0);
}

function objectValue(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function perceivedRefArray(value: unknown): PerceivedRef[] {
  if (!Array.isArray(value)) return [];
  const out: PerceivedRef[] = [];
  for (const entry of value) {
    const record = objectValue(entry);
    if (!record) continue;
    const id = stringValue(record.id);
    if (!id) continue;
    const band = normalizeBand(record.band);
    out.push({ id, band });
  }
  return out;
}

function normalizeBand(value: unknown): PerceptionBand {
  if (value === "direct" || value === "near" || value === "far") return value;
  return "near";
}
