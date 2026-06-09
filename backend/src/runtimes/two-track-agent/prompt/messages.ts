import type { GameAgentContext } from "../../../agent-shared/prompt-context/types.js";
import type { WorldEventRecord } from "../../../godot-link/protocol.js";
import { getActiveLocale, t } from "../../../i18n/index.js";
import {
  renderAgentEventsContext,
  renderAgentMemoryPinnedUserMessage,
  renderAgentSystemContext,
  renderAgentTurnContext,
  renderEventGameTimeLabel,
  renderEventSummary,
  renderTwoTrackAgentWorkingMemoryBlock,
} from "./context/renderer.js";

const PLAYER_COMMAND_EVENT_TYPE = "player_command";

export function buildTwoTrackAgentBaseSystemPrompt(): string {
  const locale = getActiveLocale();
  return `${t("prompt.agent.two_track.system", locale)}\n${t("prompt.agent.two_track.output_language_instruction", locale)}`;
}

export function buildTwoTrackAgentTurnSystemPrompt(context: GameAgentContext): string {
  const locale = getActiveLocale();
  return [
    buildTwoTrackAgentBaseSystemPrompt(),
    t("prompt.context.section.stable_context", locale),
    renderAgentSystemContext(context),
  ].join("\n\n");
}

export function buildTwoTrackAgentEffectiveSystemPrompt(context: GameAgentContext): string {
  return buildTwoTrackAgentTurnSystemPrompt(context);
}

// 长期 Memory 的置顶 pinned user message。挂在 messages 数组开头（在 summary / continuity
// 之前），update_memory 触发的变更只会让 messages 段 cache 失效，不影响 system/tools。
// 空 Memory 时返回 undefined，由调用方决定要不要塞占位。
export function buildTwoTrackAgentMemoryPinnedUserMessage(context: GameAgentContext): string | undefined {
  return renderAgentMemoryPinnedUserMessage(context);
}

export function renderTwoTrackAgentTurnUserMessage(
  reason: string,
  pendingEvents: WorldEventRecord[],
  triggeringEvents: WorldEventRecord[],
  context: GameAgentContext,
  activeWorkLines: string[] = [],
): string {
  const locale = getActiveLocale();
  const trimmedContext = contextWithoutPlayerCommands(context);
  const sections: (string | undefined)[] = [];
  // user message 顺序：历史事件 → 近期事件 → working_memory → 现状（位置/属性/...）。
  // 时间轴语义：最远的过去先铺背景，然后近期事件，再 NPC 自己消化后的工作记忆，最后是当前世界快照。
  // 事件段拆出来单独渲染，方便夹住 working_memory；working_memory 由 thinking 轨每 15 game-min 刷一次，
  // 仍只挂在 user message（不放 system），避免污染 prompt cache。
  sections.push(renderAgentEventsContext(trimmedContext));
  sections.push(renderTwoTrackAgentWorkingMemoryBlock(context));
  sections.push(renderAgentTurnContext(trimmedContext));
  // active_work + tool_choice_hint 绑定：只有手上有活在跑时才出现，提醒 LLM 别随手调工具打断。
  // 空时整块跳过，避免每 turn 都塞「没活在跑」噪声 + 保持 prompt cache 稳定。
  sections.push(renderActiveWorkBlock(activeWorkLines, locale));
  sections.push(t("prompt.context.section.current_trigger", locale));
  sections.push(renderTwoTrackAgentTurnInstruction(reason, pendingEvents, triggeringEvents, context.characterId));
  return sections.filter((section): section is string => Boolean(section)).join("\n\n");
}

function renderActiveWorkBlock(
  activeWorkLines: string[],
  locale: ReturnType<typeof getActiveLocale>,
): string | undefined {
  if (activeWorkLines.length === 0) return undefined;
  return [
    t("prompt.agent.two_track.tick.active_work_header", locale),
    ...activeWorkLines,
    t("prompt.agent.two_track.tick.active_work_note", locale),
    t("prompt.agent.two_track.tick.interrupt_tool_choice_hint", locale),
  ].join("\n");
}

export function renderTwoTrackAgentActionNoticeUserMessage(noticeText: string): string {
  const locale = getActiveLocale();
  const body = noticeText.trim().startsWith("# ")
    ? noticeText
    : [t("prompt.context.section.action_notice", locale), noticeText].join("\n");
  return [
    body,
    t("prompt.agent.two_track.tick.action_notice_continuation", locale),
  ].join("\n");
}

function renderTwoTrackAgentTurnInstruction(
  reason: string,
  pendingEvents: WorldEventRecord[],
  triggeringEvents: WorldEventRecord[],
  viewerId: string,
): string {
  const locale = getActiveLocale();
  const playerCommand = latestPlayerCommand(pendingEvents);
  if (playerCommand) {
    return [
      t("prompt.context.section.player_command", locale),
      playerCommand,
    ].join("\n");
  }

  // 任何 reason 都先呈现「上次 LLM 调用之后新感知的事」（合并单段，不拆触发/背景）；空则整块省略。
  // 随后接 reason 专属指令。这样 action_notice / reflection turn 也能看到忙碌期间周围发生的事。
  const perceivedBlock = renderPerceivedEventsBlock(triggeringEvents, viewerId);
  const instruction = renderReasonInstruction(reason, locale, perceivedBlock !== "");
  return [perceivedBlock, instruction].filter(Boolean).join("\n");
}

// 感知事件块：非空时 header + 逐条事件；空则返回 ""（不再输出「暂无具体事件细节」）。
function renderPerceivedEventsBlock(events: WorldEventRecord[], viewerId: string): string {
  if (events.length === 0) return "";
  const locale = getActiveLocale();
  const lines: string[] = [
    t("prompt.agent.two_track.tick.interrupt_trigger_header", locale),
  ];
  for (const event of events) {
    lines.push(t("prompt.agent.two_track.tick.interrupt_trigger_line_format", locale, {
      time: renderEventGameTimeLabel(event),
      summary: renderEventSummary(event, viewerId),
    }));
  }
  return lines.join("\n");
}

function renderReasonInstruction(
  reason: string,
  locale: ReturnType<typeof getActiveLocale>,
  hasEvents: boolean,
): string {
  if (reason === "player_command") {
    return t("prompt.agent.two_track.tick.player_command_empty", locale);
  }
  if (reason === "interrupt" || reason === "sensory") {
    // 有新感知 → 提示回应；空（如本 turn 迭代-2，事件已被迭代-1 清空）→ 续行提示。
    return hasEvents
      ? t("prompt.agent.two_track.tick.interrupt_response_prompt", locale)
      : t("prompt.agent.two_track.tick.continuation_prompt", locale);
  }
  if (reason === "idle") {
    return t("prompt.agent.two_track.tick.idle_prompt", locale);
  }
  if (reason === "reflection") {
    return t("prompt.agent.two_track.tick.reflection_prompt", locale);
  }
  if (reason === "action_notice") {
    return t("prompt.agent.two_track.tick.action_notice_prompt", locale);
  }
  return t("prompt.agent.two_track.tick.generic_prompt", locale, { reason });
}

function contextWithoutPlayerCommands(context: GameAgentContext): GameAgentContext {
  return {
    ...context,
    pendingEvents: context.pendingEvents.filter((event) => event.type !== PLAYER_COMMAND_EVENT_TYPE),
    relevantEvents: context.relevantEvents.filter((event) => event.type !== PLAYER_COMMAND_EVENT_TYPE),
  };
}

function latestPlayerCommand(events: WorldEventRecord[]): string | undefined {
  // Wire contract: player_command events carry typed words on event.spokenText.
  // See world-events.ts PlayerCommandEventData.
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (event.type !== PLAYER_COMMAND_EVENT_TYPE) continue;
    const command = event.spokenText?.trim();
    if (command) return command;
  }
  return undefined;
}
