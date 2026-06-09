import { getActiveLocale, has, type Locale, t } from "../../../../i18n/index.js";
import type { ActionLogRecord, WorldEventRecord } from "../../../../godot-link/protocol.js";
import { SAY_TO_ACTION } from "../../../../godot-link/actions.js";
import { renderActionResultCharacterChangeLines } from "../../../../agent-shared/game-tools/character-changes.js";
import { isCharacterContextEvent } from "../../../../agent-shared/prompt-context/events.js";
import { renderEventLine } from "../../../../agent-shared/event-descriptions/index.js";
import type {
  AgentCurrentContext,
  GameAgentContext,
  TimelineCursor,
  WorkingMemorySnapshot,
} from "../../../../agent-shared/prompt-context/types.js";
import {
  displayLocationContextEntry,
  renderInteractiveSitesSection,
  renderNearbyEnvironmentSections,
  renderProficiencySection,
  renderTownMap,
} from "../../../../agent-shared/prompt-context/sections.js";
import { characterDisplayName, characterName, localizeText, locationDescription } from "../../../../agent-shared/name-resolver/index.js";
import { getFactBoundaryRules } from "../../../../agent-shared/entity-descriptions/lore.js";
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

export const RAW_TIMELINE_TAIL_KEEP = 10;
export const UNSUMMARIZED_TIMELINE_TRIGGER_COUNT = 30;

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
  // 「常识」不再写在 system —— 已改成每个角色 kind=common_sense 的可变 memory（可被 update_memory
  // 增删改），渲染在下方 pinned memory message 的「常识」段，见 renderMemorySection。
  // 事实边界仍留 system：那是防幻觉硬约束，不该让 agent 自己改。
  appendSection(sections, t("prompt.context.label.fact_boundary", locale), renderMemoryLines(getFactBoundaryRules()));
  // 城镇地图：静态全城地点总览（按区分组），对所有 NPC 一致 → 放 system prompt（稳定可缓存）。
  // 纯数据驱动，不依赖 manifest / db；空时跳过。见 renderTownMap / [[project_town_map_zones]]。
  const townMap = renderTownMap(locale);
  if (townMap) appendSection(sections, t("prompt.context.townmap.title", locale), townMap);
  // working_memory 不在这里渲染 —— 它每次 thinking 都会变（默认 15 game-min 一次），
  // 放进 system prompt 会污染 prompt cache。改由 user message 头每 turn 重新拼装，见
  // renderTwoTrackAgentWorkingMemoryBlock / messages.ts 的 turn user message 装配。
  // 长期 Memory 也不在这里渲染 —— update_memory 调用会改它，进 system 同样污染 cache。
  // 改由一条置顶 pinned user message 承载，见 renderAgentMemoryPinnedUserMessage 与
  // action-session/messages.ts 的 prefix 装配。

  return sections.join("\n\n");
}

// 身份 + 长期 Memory（self_knowledge / skill / other）——抽到 system 之外，作为消息序列里
// 一条固定 pinned user message。update_memory 改它只会让 messages 段 cache 失效，
// 不连累 system/tools 段的 cache。
export function renderAgentMemoryPinnedUserMessage(context: GameAgentContext): string | undefined {
  const locale = getActiveLocale();
  const identity = t("prompt.context.label.playing_role_format", locale, { name: renderCharacterIdentity(context.characterId) });
  const body = renderMemorySection(context, locale);
  const label = t("prompt.context.label.memory", locale);
  if (!body.trim()) return identity;
  return `${identity}\n\n# ${label}\n${body}`;
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

// 事件段：world event + backend 内部失败 action 按时间合并成一条 actor-private 时间线。
// 从 renderAgentTurnContext 拆出，方便 messages.ts 在事件块和「现状」块之间插入
// working_memory（user message 顺序：近期事件 → working_memory → 现状）。
export function renderAgentEventsContext(context: GameAgentContext): string {
  const sections: string[] = [];
  const locale = getActiveLocale();
  const entries = filterTimelineEntriesAfterCursor(
    buildAgentTimelineEntries(context),
    context.workingMemory?.compactedThrough,
  );
  appendSection(
    sections,
    t("prompt.context.label.recent_events_format", locale, { hours: formatHours(context.relevantEventWindowHours) }),
    renderAgentTimelineEntries(entries, context, locale),
  );
  return sections.join("\n\n");
}

// 现状块：位置 / 属性 / 手艺 / 周围 / 背包 / 当前时间。
// 不含事件段——事件段由 renderAgentEventsContext 单独渲染。
export function renderAgentTurnContext(context: GameAgentContext): string {
  const sections: string[] = [];
  const locale = getActiveLocale();

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

  const interactiveSection = renderInteractiveSitesSection(context.current, locale);
  if (interactiveSection) {
    appendSection(sections, interactiveSection.title, interactiveSection.body);
  }

  if (context.current.inventory.length > 0) {
    appendSection(sections, t("prompt.context.label.current_holding", locale), renderMemoryLines(context.current.inventory));
  }

  appendSection(sections, renderBackpackSectionTitle(context.current, locale), renderMemoryLines(context.current.backpack));

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
    renderPromptMemories(context.memory.selfKnowledge, context.current.gameTime, locale),
    "",
    `## ${t("prompt.context.memory.common_sense", locale)}`,
    renderPromptMemories(context.memory.commonSense, context.current.gameTime, locale),
    "",
    `## ${t("prompt.context.memory.skill", locale)}`,
    renderSkillMemoriesByAxis(context.memory.skills, context.current.gameTime, locale),
    "",
    `## ${t("prompt.context.memory.other", locale)}`,
    renderPromptMemories(context.memory.other, context.current.gameTime, locale),
  ].join("\n");
}

function renderPromptMemories(
  memories: GameAgentContext["memory"]["all"],
  currentGameTime: AgentCurrentContext["gameTime"],
  locale: Locale,
): string {
  if (memories.length === 0) {
    return t("prompt.context.distance_band_none", locale);
  }
  return memories.map((memory) => renderPromptMemoryLine(memory, currentGameTime, locale)).join("\n");
}

// 把 skill 段按 skill_id 分组渲染。seed 来的 skill memory 通过 id pattern
// (seed:skill:<bookId>:...) 反查 bookId，再通过 skill-catalog.getSkillForBook
// 拿对应 skill_id。玩家/LLM 后期手写的 skill memory 没这套 id → 落"其他"组兜底。
function renderSkillMemoriesByAxis(
  skills: PromptMemoryRecord[],
  currentGameTime: AgentCurrentContext["gameTime"],
  locale: Locale,
): string {
  if (skills.length === 0) {
    return t("prompt.context.distance_band_none", locale);
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
    parts.push(list.map((m) => renderPromptMemoryLine(m, currentGameTime, locale)).join("\n"));
  }
  if (orphan.length > 0) {
    parts.push(`### ${t("prompt.context.memory.skill_other_group", locale)}`);
    parts.push(orphan.map((m) => renderPromptMemoryLine(m, currentGameTime, locale)).join("\n"));
  }
  return parts.join("\n");
}

function renderPromptMemoryLine(
  memory: PromptMemoryRecord,
  currentGameTime: AgentCurrentContext["gameTime"],
  locale: Locale,
): string {
  if (memory.timeDisplay === "none") {
    return `[${memory.promptIndex}] ${memory.text}`;
  }
  return `[${memory.promptIndex}] [${formatPromptMemoryTime(memory, currentGameTime, locale)}] ${memory.text}`;
}

function formatPromptMemoryTime(
  memory: PromptMemoryRecord,
  currentGameTime: AgentCurrentContext["gameTime"],
  locale: Locale,
): string {
  const memoryGameTime = normalizeGameTime(memory.updatedGameTime ?? memory.createdGameTime);
  if (!memoryGameTime) {
    return t("prompt.context.time.game_time_unknown", locale);
  }
  const current = normalizeGameTime(currentGameTime);
  if (!current) {
    return formatPromptMemoryExactTime(memoryGameTime);
  }
  const ageGameMinutes = gameTimeSortValue(current) - gameTimeSortValue(memoryGameTime);
  if (ageGameMinutes < 0 || ageGameMinutes < 24 * 60) {
    return formatPromptMemoryExactTime(memoryGameTime);
  }
  if (ageGameMinutes < 72 * 60) {
    return `${formatGameDate(memoryGameTime)} ${formatPromptMemoryDayPeriod(memoryGameTime.hour, locale)}`;
  }
  return formatGameDate(memoryGameTime);
}

function formatPromptMemoryExactTime(gameTime: NormalizedGameTime): string {
  return `${formatGameDate(gameTime)} ${gameTime.hour}:${pad2(gameTime.minute)}`;
}

function formatPromptMemoryDayPeriod(hour: number, locale: Locale): string {
  if (hour >= 23 || hour < 5) return t("prompt.context.time.period_midnight", locale);
  if (hour < 8) return t("prompt.context.time.period_dawn", locale);
  if (hour < 11) return t("prompt.context.time.period_morning", locale);
  if (hour < 13) return t("prompt.context.time.period_noon", locale);
  if (hour < 18) return t("prompt.context.time.period_afternoon", locale);
  return t("prompt.context.time.period_evening", locale);
}

const SKILL_SEED_ID_RE = /^seed:skill:([^:]+):/;
function parseSkillSeedBookId(memoryId: string): string | undefined {
  const m = memoryId.match(SKILL_SEED_ID_RE);
  return m ? m[1] : undefined;
}

// 把本角色 action_log（带 result）按 actionId 建索引，按 event.data.actionId 精确 join 到
// 自身授权的事件行上，产出成功效果子行（属性变动/背包变动）。匹配不到 → 不附（优雅降级）。
// 失败主行不在此处理：Godot 失败由 action_failed world_event 渲染，backend 内部失败
// 由 renderAgentTimelineEntries 作为 actor-private action_log 条目渲染。
class SelfActionResultMatcher {
  private readonly byActionId = new Map<string, ActionLogRecord>();

  constructor(results: ActionLogRecord[], private readonly viewerId: string, private readonly locale: Locale) {
    for (const rec of results) {
      // action_log 主键是 actionId（rec.id），全局唯一 → 直接覆盖式建表。
      if (rec.id) this.byActionId.set(rec.id, rec);
    }
  }

  effectSubLinesFor(event: WorldEventRecord): string[] {
    // 只给本角色自己授权的动作类事件补效果；他人事件/纯感知事件不动。
    if (!event.actorId || event.actorId !== this.viewerId) return [];
    const actionId = typeof event.data?.actionId === "string" ? event.data.actionId : "";
    if (!actionId) return [];
    const rec = this.byActionId.get(actionId);
    if (!rec) return [];
    return [
      renderActionReasonLine(rec.reason, this.locale),
      ...renderActionResultCharacterChangeLines(rec.result),
    ].filter((line): line is string => Boolean(line));
  }
}

export type AgentTimelineEntry =
  | { kind: "event"; event: WorldEventRecord; cursor: TimelineCursor }
  | { kind: "failed_action"; action: ActionLogRecord; cursor: TimelineCursor };

export function buildAgentTimelineEntries(context: GameAgentContext): AgentTimelineEntry[] {
  const pendingEvents = context.pendingEvents.filter((event) => !isCharacterContextEvent(event));
  const mergedEvents = mergeDistinctEvents(context.relevantEvents, pendingEvents);
  const eventActionIds = new Set(mergedEvents
    .map((event) => typeof event.data?.actionId === "string" ? event.data.actionId : undefined)
    .filter((id): id is string => Boolean(id)));
  return [
    ...mergedEvents.map((event) => ({ kind: "event" as const, event, cursor: eventCursor(event) })),
    ...failedActionsForTimeline(context, eventActionIds).map((action) => ({ kind: "failed_action" as const, action, cursor: actionCursor(action) })),
  ].sort((a, b) => compareTimelineCursors(a.cursor, b.cursor));
}

export function filterTimelineEntriesAfterCursor(entries: AgentTimelineEntry[], cursor: TimelineCursor | undefined): AgentTimelineEntry[] {
  if (!cursor) return entries;
  return entries.filter((entry) => compareTimelineCursors(entry.cursor, cursor) > 0);
}

export function countUncompactedTimelineEntries(context: GameAgentContext): number {
  return filterTimelineEntriesAfterCursor(buildAgentTimelineEntries(context), context.workingMemory?.compactedThrough).length;
}

export function latestTimelineCursor(entries: AgentTimelineEntry[]): TimelineCursor | undefined {
  return entries.length > 0 ? entries[entries.length - 1].cursor : undefined;
}

export function renderAgentTimelineEntries(entries: AgentTimelineEntry[], context: GameAgentContext, locale: Locale): string {
  if (entries.length === 0) {
    return t("prompt.context.distance_band_none", locale);
  }

  const matcher = new SelfActionResultMatcher(context.selfActionResults ?? [], context.characterId, locale);
  const grouped = new Map<string, string[]>();
  for (const entry of [...entries].sort((a, b) => compareTimelineCursors(a.cursor, b.cursor))) {
    const gameTime = timelineGameTime(entry);
    const date = gameTime ? formatGameDate(gameTime) : t("prompt.context.time.game_time_unknown", locale);
    const time = gameTime ? `${gameTime.hour}:${pad2(gameTime.minute)}` : t("prompt.context.time.unknown", locale);
    const lines = grouped.get(date) ?? [];
    if (entry.kind === "event") {
      lines.push(`${time} ${renderEventLine(entry.event, context.characterId, locale, context.current.selfDrunk, context.current.selfDrunkTier)}`);
      for (const sub of matcher.effectSubLinesFor(entry.event)) {
        lines.push(`  → ${sub}`);
      }
    } else {
      lines.push(`${time} ${renderFailedActionLine(entry.action, context.characterId, locale)}`);
      const reasonLine = renderActionReasonLine(entry.action.reason, locale);
      if (reasonLine) lines.push(`  → ${reasonLine}`);
    }
    grouped.set(date, lines);
  }

  return [...grouped.entries()]
    .map(([date, lines]) => `${date}：\n${lines.join("\n")}`)
    .join("\n\n");
}

function failedActionsForTimeline(context: GameAgentContext, eventActionIds: Set<string>): ActionLogRecord[] {
  const actions = context.selfActionResults ?? [];
  const currentGameTime = normalizeGameTime(context.current.gameTime);
  const currentGameMinutes = currentGameTime ? gameTimeSortValue(currentGameTime) : undefined;
  const cutoffGameMinutes = currentGameMinutes != null
    ? currentGameMinutes - context.relevantEventWindowHours * 60
    : undefined;
  return actions.filter((action) => {
    if (action.characterId !== context.characterId) return false;
    if (action.status !== "failed") return false;
    if (eventActionIds.has(action.id)) return false;
    if (cutoffGameMinutes == null) return true;
    const gameTime = actionGameTime(action);
    if (!gameTime) return true;
    return gameTimeSortValue(gameTime) >= cutoffGameMinutes;
  });
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

function actionGameTime(action: ActionLogRecord): NormalizedGameTime | undefined {
  return normalizeGameTime(action.gameTime);
}

function timelineGameTime(entry: AgentTimelineEntry): NormalizedGameTime | undefined {
  return entry.kind === "event" ? eventGameTime(entry.event) : actionGameTime(entry.action);
}

function eventCursor(event: WorldEventRecord): TimelineCursor {
  const gameMinutes = eventGameTimeMinutes(event);
  return gameMinutes == null
    ? { kind: "event", id: event.id, createdAt: event.createdAt || event.occurredAt }
    : { kind: "event", id: event.id, createdAt: event.createdAt || event.occurredAt, gameMinutes };
}

function actionCursor(action: ActionLogRecord): TimelineCursor {
  const gameTime = actionGameTime(action);
  const gameMinutes = gameTime ? gameTimeSortValue(gameTime) : undefined;
  return gameMinutes == null
    ? { kind: "action", id: action.id, createdAt: action.createdAt }
    : { kind: "action", id: action.id, createdAt: action.createdAt, gameMinutes };
}

function compareTimelineCursors(a: TimelineCursor, b: TimelineCursor): number {
  const time = cursorSortTime(a) - cursorSortTime(b);
  if (time !== 0) return time;
  const created = a.createdAt.localeCompare(b.createdAt);
  if (created !== 0) return created;
  const kind = cursorKindOrder(a.kind) - cursorKindOrder(b.kind);
  if (kind !== 0) return kind;
  return a.id.localeCompare(b.id);
}

function cursorSortTime(cursor: TimelineCursor): number {
  if (cursor.gameMinutes != null) return cursor.gameMinutes;
  return Date.parse(cursor.createdAt) || 0;
}

function cursorKindOrder(kind: TimelineCursor["kind"]): number {
  return kind === "event" ? 0 : 1;
}

function renderFailedActionLine(action: ActionLogRecord, viewerId: string, locale: Locale): string {
  const target = action.target && typeof action.target === "object" && !Array.isArray(action.target)
    ? action.target as Record<string, unknown>
    : {};
  const reason = humanizeFailureReason(action.error ?? "", locale);
  if (action.action === SAY_TO_ACTION) {
    const text = localizeText(stringField(target, "text") ?? "");
    const targetId = stringField(target, "targetCharacterId");
    if (targetId) {
      const targetLabel = targetId === viewerId
        ? t("prompt.context.event.self_pronoun", locale)
        : characterDisplayName(targetId, locale);
      return t("prompt.context.event.action_failed.say_to_format", locale, { target: targetLabel, text, reason });
    }
    return t("prompt.context.event.action_failed.say_to_no_target_format", locale, { text, reason });
  }
  return t("prompt.context.event.action_failed.generic_format", locale, {
    action: actionLabel(action.action, locale),
    reason,
  });
}

function renderActionReasonLine(reason: string | undefined, locale: Locale): string | undefined {
  const cleaned = stripAgentToolReasonPrefix(reason, locale);
  if (!cleaned) return undefined;
  return t("prompt.context.event.action_reason_format", locale, { reason: cleaned });
}

function stripAgentToolReasonPrefix(reason: string | undefined, locale: Locale): string | undefined {
  const raw = reason?.trim();
  if (!raw) return undefined;
  const prefix = t("tool.common.agent_tool_reason_format", locale, { reason: "" }).trim();
  if (prefix && raw.startsWith(prefix)) {
    const stripped = raw.slice(prefix.length).trim();
    return stripped || undefined;
  }
  return raw;
}

function actionLabel(action: string, locale: Locale): string {
  const promptKey = `prompt.context.action_label.${action}`;
  if (has(promptKey, locale)) return t(promptKey, locale);
  const toolKey = `tool.action.name.${action}`;
  if (has(toolKey, locale)) return t(toolKey, locale);
  return action;
}

function humanizeFailureReason(reason: string, locale: Locale): string {
  const trimmed = reason.trim();
  if (!trimmed) return t("prompt.context.event.action_failed.reason_unknown", locale);
  const match = trimmed.match(/^(.*:\s*)([a-z0-9_]+)$/i);
  if (!match) return trimmed;
  const name = characterDisplayName(match[2], locale);
  return name && name !== match[2] ? `${match[1]}${name}` : trimmed;
}

function stringField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

// 渲染单条事件成 prompt 行。每个 event type 的具体 prose 在
// agent-shared/event-descriptions/<type>.ts 里，按 viewerId 决定要不要用"你"。
// 这里是给 messages.ts 等 interrupt-trigger 行复用的薄包装。
export function renderEventSummary(event: WorldEventRecord, viewerId: string): string {
  return renderEventLine(event, viewerId, getActiveLocale());
}

// 把 event.gameTime 转成时间线排序用的游戏分钟值。无 gameTime 返回 undefined。
export function eventGameTimeMinutes(event: WorldEventRecord): number | undefined {
  const gameTime = eventGameTime(event);
  return gameTime ? gameTimeSortValue(gameTime) : undefined;
}

// Re-export from shared so call sites keep one import surface.
export { renderEventGameTimeLabel } from "../../../../agent-shared/event-descriptions/index.js";

function renderCurrentLocationText(current: AgentCurrentContext): string {
  const parts = [
    displayLocationContextEntry(current.currentLocation, current),
    locationDescription(current.currentLocation),
  ].filter((part): part is string => Boolean(part));
  return parts.join("；");
}

function renderBackpackSectionTitle(current: AgentCurrentContext, locale: Locale): string {
  if (!current.backpackCarryText) return t("prompt.context.label.backpack", locale);
  return t("prompt.context.label.backpack_carry_format", locale, { carry: current.backpackCarryText });
}

function renderCharacterIdentity(characterId: string): string {
  return characterName(characterId);
}

function appendSection(sections: string[], title: string, body: string): void {
  sections.push(`# ${title}\n${body}`);
}

function formatHours(hours: number): string {
  return Number.isInteger(hours) ? String(hours) : hours.toFixed(1);
}
