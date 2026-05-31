import { getActiveLocale, type Locale, t } from "../../../../i18n/index.js";
import type { WorldEventRecord } from "../../../../godot-link/protocol.js";
import { isCharacterContextEvent } from "../../../../agent-shared/prompt-context/events.js";
import { renderEventLine } from "../../../../agent-shared/event-descriptions/index.js";
import type {
  AgentCurrentContext,
  GameAgentContext,
  WorkingMemorySnapshot,
} from "../../../../agent-shared/prompt-context/types.js";
import {
  displayLocationContextEntry,
  renderInteractiveSitesSection,
  renderNearbyEnvironmentSections,
  renderProficiencySection,
} from "../../../../agent-shared/prompt-context/sections.js";
import { characterName, localizeText, locationDescription } from "../../../../agent-shared/name-resolver/index.js";
import { getCommonSense, getFactBoundaryRules } from "../../../../agent-shared/entity-descriptions/lore.js";
import { getSkillForBook } from "../../../../agent-shared/entity-descriptions/skill-catalog.js";
import type { PromptMemoryRecord } from "../../../../agent-shared/prompt-context/types.js";
import {
  formatGameDate,
  formatGameTime,
  gameTimeFromRecord,
  gameTimeSortValue,
  normalizeGameTime,
  pad2,
  type NormalizedGameTime,
} from "../../../../agent-shared/prompt-context/time.js";

export function renderAgentContext(context: GameAgentContext): string {
  return [
    renderAgentSystemContext(context),
    renderAgentEventsContext(context),
    renderAgentTurnContext(context),
  ]
    .filter((section) => section.length > 0)
    .join("\n\n");
}

export function renderAgentSystemContext(context: GameAgentContext): string {
  const sections: string[] = [];

  const locale = getActiveLocale();
  appendSection(sections, t("prompt.context.label.world_lore", locale), context.worldLore.map((line) => `- ${line}`).join("\n"));
  appendSection(sections, t("prompt.context.label.common_sense", locale), renderMemoryLines(getCommonSense()));
  appendSection(sections, t("prompt.context.label.fact_boundary", locale), renderMemoryLines(getFactBoundaryRules()));
  // working_memory 不在这里渲染 —— 它每次 thinking 都会变（默认 15 game-min 一次），
  // 放进 system prompt 会污染 prompt cache。改由 user message 头每 turn 重新拼装，见
  // renderTwoTrackAgentWorkingMemoryBlock / messages.ts 的 turn user message 装配。
  // 长期 Memory 也不在这里渲染 —— update_memory 调用会改它，进 system 同样污染 cache。
  // 改由一条置顶 pinned user message 承载，见 renderAgentMemoryPinnedUserMessage 与
  // action-session/messages.ts 的 prefix 装配。

  return sections.join("\n\n");
}

// 长期 Memory（self_knowledge / skill / other）——抽到 system 之外，作为消息序列里
// 一条固定 pinned user message。update_memory 改它只会让 messages 段 cache 失效，
// 不连累 system/tools 段的 cache。空时返回 undefined（不送空块）。
export function renderAgentMemoryPinnedUserMessage(context: GameAgentContext): string | undefined {
  const locale = getActiveLocale();
  const body = renderMemorySection(context, locale);
  if (!body.trim()) return undefined;
  const label = t("prompt.context.label.memory", locale);
  return `# ${label}\n${body}`;
}

// 给 user message 端用：把 working_memory 整成一段独立块，每 turn 重新拼。
export function renderTwoTrackAgentWorkingMemoryBlock(context: GameAgentContext): string | undefined {
  if (!context.workingMemory) return undefined;
  const locale = getActiveLocale();
  const label = t("prompt.context.label.working_memory", locale);
  const body = renderWorkingMemory(context.workingMemory, locale);
  return `# ${label}\n${body}`;
}

function renderWorkingMemory(memory: WorkingMemorySnapshot, locale: Locale): string {
  const updatedAt = formatGameTime(memory.gameTime) ?? memory.updatedAt;
  const meta = t("prompt.context.label.working_memory_meta_format", locale, {
    updatedAt,
    reason: memory.triggerReason ?? "scheduled",
  });
  const body = memory.content.trim();
  if (!body) {
    return t("prompt.context.label.working_memory_empty", locale);
  }
  return `${meta}\n\n${body}`;
}

// 事件段：历史在前、近期在后（时间正序）。从 renderAgentTurnContext 拆出，方便
// messages.ts 在事件块和「现状」块之间插入 working_memory（user message 顺序：
// 历史事件 → 近期事件 → working_memory → 现状）。两段都空则返回 ""。
export function renderAgentEventsContext(context: GameAgentContext): string {
  const sections: string[] = [];
  const locale = getActiveLocale();
  const { recentEvents, historicalEvents } = splitContextEvents(context);
  const recentHours = context.recentEventWindowMinutes / 60;
  appendSection(
    sections,
    t("prompt.context.label.historical_events_format", locale, {
      startHours: formatHours(recentHours),
      endHours: formatHours(context.relevantEventWindowHours),
    }),
    renderEventTimeline(historicalEvents, context.characterId, locale),
  );
  appendSection(
    sections,
    t("prompt.context.label.recent_events_format", locale, { hours: formatHours(recentHours) }),
    renderEventTimeline(recentEvents, context.characterId, locale),
  );
  return sections.join("\n\n");
}

// 现状块：playing role + 位置 / 属性 / 手艺 / 周围 / 背包 / 当前时间。
// 不含事件段——事件段由 renderAgentEventsContext 单独渲染。
export function renderAgentTurnContext(context: GameAgentContext): string {
  const sections: string[] = [];
  const locale = getActiveLocale();

  sections.push(t("prompt.context.label.playing_role_format", locale, { name: renderCharacterIdentity(context.characterId) }));

  appendSection(sections, t("prompt.context.label.current_location_with_colon", locale), renderCurrentLocationText(context.current));

  if (context.current.characterAttributes.length > 0) {
    appendSection(sections, t("prompt.context.label.character_attributes", locale), renderMemoryLines(context.current.characterAttributes));
  }

  // 手艺紧跟在角色属性后面 —— LLM 决定"接什么活/学什么"时这两块要一起看。
  const proficiencySection = renderProficiencySection(context.current, locale);
  appendSection(sections, proficiencySection.title, proficiencySection.body);

  for (const section of renderNearbyEnvironmentSections(context.current, locale)) {
    appendSection(sections, section.title, section.body);
  }

  if (context.current.ownedShelves.length > 0) {
    appendSection(sections, t("prompt.context.label.owned_shelves", locale), renderOwnedShelfLines(context.current, locale));
  }

  const interactiveSection = renderInteractiveSitesSection(context.current, locale);
  if (interactiveSection) {
    appendSection(sections, interactiveSection.title, interactiveSection.body);
  }

  if (context.current.inventory.length > 0) {
    appendSection(sections, t("prompt.context.label.current_holding", locale), renderMemoryLines(context.current.inventory));
  }

  appendSection(sections, t("prompt.context.label.backpack", locale), renderMemoryLines(context.current.backpack));

  appendSection(sections, t("prompt.context.label.current_time", locale), formatGameTime(context.current.gameTime) ?? t("error.default_unknown_age", locale));

  return sections.join("\n\n");
}

function renderMemoryLines(lines: string[]): string {
  if (lines.length === 0) {
    return "- none";
  }
  return lines.map((line) => `- ${line}`).join("\n");
}

function renderMemorySection(context: GameAgentContext, locale: Locale): string {
  return [
    t("prompt.context.memory.description", locale),
    "",
    `## ${t("prompt.context.memory.self_knowledge", locale)}`,
    renderPromptMemories(context.memory.selfKnowledge, locale),
    "",
    `## ${t("prompt.context.memory.skill", locale)}`,
    renderSkillMemoriesByAxis(context.memory.skills, locale),
    "",
    `## ${t("prompt.context.memory.other", locale)}`,
    renderPromptMemories(context.memory.other, locale),
  ].join("\n");
}

function renderPromptMemories(memories: GameAgentContext["memory"]["all"], locale: Locale): string {
  if (memories.length === 0) {
    return `- ${t("prompt.context.distance_band_none", locale)}`;
  }
  return memories.map((memory) => `- ${memory.text}`).join("\n");
}

// 把 skill 段按 skill_id 分组渲染。seed 来的 skill memory 通过 id pattern
// (seed:skill:<bookId>:...) 反查 bookId，再通过 skill-catalog.getSkillForBook
// 拿对应 skill_id。玩家/LLM 后期手写的 skill memory 没这套 id → 落"其他"组兜底。
function renderSkillMemoriesByAxis(skills: PromptMemoryRecord[], locale: Locale): string {
  if (skills.length === 0) {
    return `- ${t("prompt.context.distance_band_none", locale)}`;
  }
  const bySkill = new Map<string, PromptMemoryRecord[]>();
  const orphan: PromptMemoryRecord[] = [];
  for (const mem of skills) {
    const bookId = parseSkillSeedBookId(mem.id);
    const skillId = bookId ? getSkillForBook(bookId) : undefined;
    if (skillId) {
      const list = bySkill.get(skillId) ?? [];
      list.push(mem);
      bySkill.set(skillId, list);
    } else {
      orphan.push(mem);
    }
  }
  const parts: string[] = [];
  for (const [skillId, list] of bySkill) {
    const label = t(`prompt.context.proficiency.skill.${skillId}`, locale);
    parts.push(`### ${label}`);
    parts.push(list.map((m) => `- ${m.text}`).join("\n"));
  }
  if (orphan.length > 0) {
    parts.push(`### ${t("prompt.context.memory.skill_other_group", locale)}`);
    parts.push(orphan.map((m) => `- ${m.text}`).join("\n"));
  }
  return parts.join("\n");
}

const SKILL_SEED_ID_RE = /^seed:skill:([^:]+):/;
function parseSkillSeedBookId(memoryId: string): string | undefined {
  const m = memoryId.match(SKILL_SEED_ID_RE);
  return m ? m[1] : undefined;
}

function renderEventTimeline(events: WorldEventRecord[], viewerId: string, locale: Locale): string {
  if (events.length === 0) {
    return t("prompt.context.distance_band_none", locale);
  }

  const grouped = new Map<string, string[]>();
  for (const event of [...events].sort((a, b) => eventSortValue(a) - eventSortValue(b))) {
    const gameTime = eventGameTime(event);
    const date = gameTime ? formatGameDate(gameTime) : t("prompt.context.time.game_time_unknown", locale);
    const time = gameTime ? `${gameTime.hour}:${pad2(gameTime.minute)}` : t("prompt.context.time.unknown", locale);
    const lines = grouped.get(date) ?? [];
    lines.push(`${time} ${renderEventLine(event, viewerId, locale)}`);
    grouped.set(date, lines);
  }

  return [...grouped.entries()]
    .map(([date, lines]) => `${date}：\n${lines.join("\n")}`)
    .join("\n\n");
}

function splitContextEvents(context: GameAgentContext): {
  recentEvents: WorldEventRecord[];
  historicalEvents: WorldEventRecord[];
} {
  const pendingEvents = context.pendingEvents.filter((event) => !isCharacterContextEvent(event));
  const mergedEvents = mergeDistinctEvents(context.relevantEvents, pendingEvents);
  const currentGameTime = normalizeGameTime(context.current.gameTime);
  const currentGameMinutes = currentGameTime ? gameTimeSortValue(currentGameTime) : undefined;
  const recentThresholdGameMinutes = currentGameMinutes != null
    ? currentGameMinutes - context.recentEventWindowMinutes
    : undefined;

  const recentEvents: WorldEventRecord[] = [];
  const historicalEvents: WorldEventRecord[] = [];
  for (const event of mergedEvents) {
    if (recentThresholdGameMinutes == null) {
      // 没有游戏时间锚点（极少见），全归近期段，避免空段误导
      recentEvents.push(event);
      continue;
    }
    const gameTime = eventGameTime(event);
    if (!gameTime) {
      // 事件缺 gameTime，按历史段处理（保守：不冒充近期）
      historicalEvents.push(event);
      continue;
    }
    if (gameTimeSortValue(gameTime) >= recentThresholdGameMinutes) {
      recentEvents.push(event);
    } else {
      historicalEvents.push(event);
    }
  }
  return { recentEvents, historicalEvents };
}

function mergeDistinctEvents(...eventGroups: WorldEventRecord[][]): WorldEventRecord[] {
  const deduped = new Map<string, WorldEventRecord>();
  for (const group of eventGroups) {
    for (const event of group) {
      deduped.set(event.id, event);
    }
  }
  return [...deduped.values()];
}

function eventGameTime(event: WorldEventRecord): NormalizedGameTime | undefined {
  return normalizeGameTime(event.gameTime ?? gameTimeFromRecord(event.data));
}

function eventSortValue(event: WorldEventRecord): number {
  const gameTime = eventGameTime(event);
  if (gameTime) {
    return gameTimeSortValue(gameTime);
  }
  return Date.parse(event.occurredAt || event.createdAt) || 0;
}

// 渲染单条事件成 prompt 行。每个 event type 的具体 prose 在
// agent-shared/event-descriptions/<type>.ts 里，按 viewerId 决定要不要用"你"。
// 这里是给 messages.ts 等 interrupt-trigger 行复用的薄包装。
export function renderEventSummary(event: WorldEventRecord, viewerId: string): string {
  return renderEventLine(event, viewerId, getActiveLocale());
}

// 把 event.gameTime 转成"分钟"单位，便于按 cutoff 切分。无 gameTime 返回 undefined。
export function eventGameTimeMinutes(event: WorldEventRecord): number | undefined {
  const gameTime = eventGameTime(event);
  return gameTime ? gameTimeSortValue(gameTime) : undefined;
}

// 给 thinking 轨用：按 cutoff 把事件分成"自上次思考以来"和"更早"两段（都按时间正序）。
// 无 gameTime 的事件归到"自上次思考以来"段（保守：宁可让模型多看到也不漏看新事件）。
export function splitEventsAtCutoff(
  events: WorldEventRecord[],
  cutoffGameMinutes: number | undefined,
): { since: WorldEventRecord[]; before: WorldEventRecord[] } {
  const sorted = [...events].sort((a, b) => eventSortValue(a) - eventSortValue(b));
  if (cutoffGameMinutes == null) {
    return { since: sorted, before: [] };
  }
  const since: WorldEventRecord[] = [];
  const before: WorldEventRecord[] = [];
  for (const event of sorted) {
    const minutes = eventGameTimeMinutes(event);
    if (minutes == null || minutes >= cutoffGameMinutes) {
      since.push(event);
    } else {
      before.push(event);
    }
  }
  return { since, before };
}

export { renderEventTimeline };

// Re-export from shared so call sites keep one import surface.
export { renderEventGameTimeLabel } from "../../../../agent-shared/event-descriptions/index.js";

function renderCurrentLocationText(current: AgentCurrentContext): string {
  const parts = [
    displayLocationContextEntry(current.currentLocation, current),
    locationDescription(current.currentLocation),
  ].filter((part): part is string => Boolean(part));
  return parts.join("；");
}

function renderCharacterIdentity(characterId: string): string {
  return characterName(characterId);
}

function renderOwnedShelfLines(
  current: AgentCurrentContext,
  locale: Locale,
): string {
  if (current.ownedShelves.length === 0) {
    return t("prompt.context.distance_band_none", locale);
  }
  return current.ownedShelves.map((shelf) => {
    const name = shelf.displayName?.trim() || shelf.id;
    const nearby = shelf.directlyInteractable
      ? t("prompt.context.shelf.owner_nearby_yes", locale)
      : t("prompt.context.shelf.owner_nearby_no", locale);
    const listings = shelf.listings.length === 0
      ? t("prompt.context.shelf.summary_empty", locale)
      : shelf.listings
        .map((listing) => `[${listing.index ?? "?"}] ${localizeText(listing.displayName ?? listing.itemId ?? listing.listingId)} x${listing.quantity} @ ${listing.priceText ?? `${listing.priceSilver.toFixed(2)} 银`}`)
        .join("；");
    return `${name}（${shelf.id}，${nearby}）：${listings}`;
  }).map((line) => `- ${line}`).join("\n");
}

function appendSection(sections: string[], title: string, body: string): void {
  sections.push(`# ${title}\n${body}`);
}

function formatHours(hours: number): string {
  return Number.isInteger(hours) ? String(hours) : hours.toFixed(1);
}
