import type { WorldEvent } from "../godot-link/events.js";
import type { PerceptionManifestPayload } from "../godot-link/perception-manifest.js";

export type StateCacheOptions = {
  eventLimitPerTown?: number;
  now?: () => Date;
};

type ManifestEntry = {
  manifest: PerceptionManifestPayload;
  receivedAt: number;
};

export class AgentHostStateCache {
  private readonly eventsByTown = new Map<string, WorldEvent[]>();
  // key: `${townId}:${characterId}`
  // 仅"我感知到的实体 id 集合"——实体状态由 backend 当场 SELECT sqlite 拼 context。
  private readonly manifestByCharacter = new Map<string, ManifestEntry>();
  private readonly eventLimitPerTown: number;
  private readonly now: () => Date;

  constructor(options: StateCacheOptions = {}) {
    this.eventLimitPerTown = options.eventLimitPerTown ?? 500;
    this.now = options.now ?? (() => new Date());
  }

  pushEvent(townId: string, event: WorldEvent): void {
    const events = this.eventsByTown.get(townId) ?? [];
    events.push(event);
    if (events.length > this.eventLimitPerTown) {
      events.splice(0, events.length - this.eventLimitPerTown);
    }
    this.eventsByTown.set(townId, events);
  }

  recentEvents(townId: string, opts: { sinceMs?: number; limit?: number } = {}): WorldEvent[] {
    const events = this.eventsByTown.get(townId) ?? [];
    const since = opts.sinceMs == null ? undefined : this.now().getTime() - opts.sinceMs;
    const filtered = since == null
      ? events
      : events.filter((event) => Date.parse(event.occurredAt) >= since);
    return opts.limit == null ? [...filtered] : filtered.slice(-opts.limit);
  }

  recentEventsForCharacter(townId: string, characterId: string, opts: { sinceMs?: number; limit?: number } = {}): WorldEvent[] {
    return this.recentEvents(townId, opts).filter((event) => isEventVisibleToCharacter(event, characterId));
  }

  // WebSocket in-order 保证 same-character 的 manifest 不会乱。
  putManifest(townId: string, manifest: PerceptionManifestPayload): void {
    this.manifestByCharacter.set(snapshotKey(townId, manifest.characterId), {
      manifest,
      receivedAt: this.now().getTime(),
    });
  }

  getManifest(townId: string, characterId: string): PerceptionManifestPayload | undefined {
    return this.manifestByCharacter.get(snapshotKey(townId, characterId))?.manifest;
  }

  forgetManifest(townId: string, characterId: string): void {
    this.manifestByCharacter.delete(snapshotKey(townId, characterId));
  }
}

function snapshotKey(townId: string, characterId: string): string {
  // 名字保留 `snapshotKey` 是历史遗留；现在只服务 manifest cache。
  return `${townId}:${characterId}`;
}

function isEventVisibleToCharacter(event: WorldEvent, characterId: string): boolean {
  return event.actorId === characterId || event.data.affectedCharacterIds.includes(characterId);
}
