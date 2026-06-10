import type { AgentToolResult } from "@mariozechner/pi-agent-core";
import type { AgentActionHost } from "../../agent-host/runtime.js";
import type { ActionName, ActionTarget } from "../../godot-link/actions.js";
import type { ActionLogRecord, GameTimeSnapshot } from "../../godot-link/protocol.js";
import {
  characterName,
  localizeStringValue,
  localizeText,
  localizeValue,
  workstationName,
} from "../name-resolver/index.js";
import { renderInteractiveSitesSection, renderNearbyEnvironmentSections } from "../prompt-context/sections.js";
import { formatGameTime } from "../prompt-context/time.js";
import type { AgentCurrentContext } from "../prompt-context/types.js";
import { renderActionResultCharacterChangeLines } from "./character-changes.js";
import { td } from "./i18n.js";
import { normalizeLocationInput } from "./targets.js";
import type {
  CharacterActionToolDetails,
  MoveToLocationToolDetails,
  SubmitToolActionOptions,
} from "./types.js";

export async function submitToolAction<TName extends ActionName, TDetails = CharacterActionToolDetails>(
  actions: AgentActionHost,
  characterId: string,
  action: TName,
  target: ActionTarget<TName>,
  reason: string,
  options: SubmitToolActionOptions<TDetails> = {} as SubmitToolActionOptions<TDetails>,
): Promise<AgentToolResult<TDetails>> {
  const wireTarget = target as Record<string, unknown>;
  const record = await actions.submit({
    characterId,
    action,
    target: wireTarget,
    reason: td("common.agent_tool_reason_format", { reason }),
    gameTime: options.gameTime,
  });
  const toolName = options.toolName ?? action;
  const formatResult = options.formatResult ?? defaultActionResultFormatter<TDetails>;
  options.onUpdate?.(await formatResult(record, {
    toolName,
    target: wireTarget,
    resultNote: td("common.runtime_pending_note"),
    displayTarget: options.displayTarget,
  }));
  const completed = await waitForActionOrInterrupt(actions, record, options);
  return await formatResult(completed.record, {
    toolName,
    target: wireTarget,
    resultNote: completed.resultNote ?? options.resultNote,
    displayTarget: options.displayTarget,
  });
}

type ActionWaitResult = {
  record: ActionLogRecord;
  resultNote?: string;
};

// race: Godot 返回 terminal vs InterruptWindow 发起 release。
// release 胜：tool 立刻关闭 tool_use（用当前进度作为 tool_result），但 action 在 Godot 端继续跑
// （Detached → ContinuedActionManager 监听，完成时通过新 user message 回到下个 turn）。
// 不再调 actions.cancel —— 打断不停活，NPC 能边干边回话。
// events 不从 tool_result 注入，统一走 user message 通道（agent.steer 或新 turn prompt）。
async function waitForActionOrInterrupt<TDetails = CharacterActionToolDetails>(
  actions: AgentActionHost,
  record: ActionLogRecord,
  options: SubmitToolActionOptions<TDetails>,
): Promise<ActionWaitResult> {
  const terminal = actions.waitForTerminal(record, { signal: options.signal, timeoutMs: options.timeoutMs });
  if (!options.interrupts) {
    return { record: await terminal };
  }

  const waitController = new AbortController();
  const winner = await Promise.race([
    terminal.then((action) => ({ kind: "terminal" as const, action })),
    options.interrupts.waitForInterrupt(waitController.signal).then((interrupt) => ({ kind: "interrupt" as const, interrupt })),
  ]);
  // race 结束后，loser 的 waitForInterrupt promise 永远不会 settle；abort signal 让 controller
  // 把这个 waiter 从队列里 delete，否则会积累成僵尸 waiter。
  waitController.abort();
  if (winner.kind === "terminal") {
    return { record: winner.action };
  }
  // release：取最新 progress 快照（Godot 通过 action.ack accepted 推到 action_log.result）
  const latest = await actions.get(record.id) ?? record;
  return {
    record: latest,
    resultNote: td("action.intermediate_note"),
  };
}

function defaultActionResultFormatter<TDetails = CharacterActionToolDetails>(
  record: ActionLogRecord,
  context: {
    toolName: string;
    target: Record<string, unknown> | string;
    resultNote?: string;
    displayTarget?: string;
  },
): AgentToolResult<TDetails> {
  return formatActionToolResult(
    context.toolName,
    record,
    context.target,
    context.resultNote,
    context.displayTarget,
  ) as AgentToolResult<TDetails>;
}

function formatActionToolResult(
  toolName: string,
  record: ActionLogRecord,
  target: Record<string, unknown> | string,
  resultNote?: string,
  displayTarget?: string,
): AgentToolResult<CharacterActionToolDetails> {
  const completion = isTerminalActionStatus(record.status) ? "runtime_terminal" : "runtime_pending";
  const interrupted = isInterruptedAction(record);
  const text = renderGenericActionContext(toolName, record, target, displayTarget, resultNote);
  return {
    content: [{ type: "text", text }],
    details: {
      actionId: record.id,
      status: record.status,
      error: record.error,
      completion,
      interrupted,
      result: record.result,
    },
  };
}

function renderGenericActionContext(
  toolName: string,
  record: ActionLogRecord,
  target: Record<string, unknown> | string,
  displayTarget?: string,
  resultNote?: string,
): string {
  const targetText = renderToolTarget(target, displayTarget) || td("action.default_target");
  const lines = [
    td("action.result.header"),
    td("action.result.action_format", { action: genericActionName(toolName) }),
    targetText,
  ];
  const timeText = actionGameTimeText(record);
  const summary = genericActionSummary(toolName, record, target, displayTarget);
  if (summary) {
    lines.push(td("action.result.summary_format", { time: timeText, summary }));
  } else if (record.status === "failed" || record.status === "cancelled") {
    const status = record.status === "failed" ? td("action.result.status_failed") : td("action.result.status_cancelled");
    lines.push(td("action.result.terminal_no_summary_format", { time: timeText, action: genericActionName(toolName), status }));
  }
  lines.push(...renderActionResultCharacterChangeLines(record.result));
  if (record.error) {
    lines.push(td("action.result.reason_format", { reason: renderToolError(record.error) }));
  }
  if (resultNote && !isTerminalActionStatus(record.status)) {
    lines.push(td("action.result.detached_work_note"));
  }
  return lines.join("\n");
}

function genericActionName(toolName: string): string {
  return tdOr(`action.name.${toolName}`, toolName);
}

function genericActionSummary(
  toolName: string,
  record: ActionLogRecord,
  target: Record<string, unknown> | string,
  displayTarget?: string,
): string | undefined {
  if (record.status === "failed" || record.status === "cancelled") {
    return undefined;
  }
  if (!isTerminalActionStatus(record.status)) {
    return td("action.summary.pending_format", { action: genericActionName(toolName) });
  }
  const resultMessage = stringField(record.result ?? {}, ["message", "summary"]);
  if (resultMessage) {
    return localizeText(resultMessage);
  }
  switch (toolName) {
    case "drop_item": return td("action.summary.drop_item_format", { item: targetItemLabel(target, displayTarget) });
    case "use_item": return td("action.summary.use_item_format", { item: targetItemLabel(target, displayTarget) });
    case "put": return td("action.summary.put_completed");
    case "take": return td("action.summary.take_completed");
    case "offer": return td("action.summary.offer_submitted");
    case "respond": return respondSummary(record.result, target);
    case "sleep": return sleepSummary(record.result, target);
    default: return td("action.summary.default_completed_format", { action: genericActionName(toolName) });
  }
}

function targetItemLabel(target: Record<string, unknown> | string, displayTarget?: string): string {
  if (displayTarget?.trim()) {
    return localizeText(displayTarget);
  }
  if (typeof target === "string") {
    return localizeStringValue(target) ?? target;
  }
  const item = stringField(target, ["item", "itemId", "item_id", "seed"]);
  return item ? localizeStringValue(item) : stripToolTargetPrefix(renderToolTarget(target));
}

function inspectContainerSummary(result: Record<string, unknown> | undefined): string {
  const snapshot = objectField(result, ["snapshot"]);
  const items = recordListValue(snapshot?.items ?? result?.items);
  if (items.length === 0) {
    return td("action.summary.container.empty");
  }
  return td("action.summary.container.items_format", { items: items.map(containerItemLabel).join(td("action.list_separator")) });
}

function containerItemLabel(entry: Record<string, unknown>): string {
  const item = stringField(entry, ["itemId", "item_id", "item"]);
  const quantity = numberField(entry, ["quantity", "qty", "count"]);
  const quality = numberField(entry, ["quality"]);
  const base = item ? localizeStringValue(item) : JSON.stringify(localizeValue(entry));
  const quantityText = quantity == null ? "" : ` x${quantity}`;
  const qualityText = quality == null ? "" : td("action.summary.container.quality_format", { quality });
  return `${base}${quantityText}${qualityText}`;
}

// respond 目前只覆盖 kind=trade（accept/reject 交易）。未来扩 kind 时按 target.kind 分支。
function respondSummary(result: Record<string, unknown> | undefined, target: Record<string, unknown> | string): string {
  const response = stringField(result ?? {}, ["response"])
    ?? (typeof target === "string" ? undefined : stringField(target, ["response"]));
  if (response === "accept") {
    return td("action.summary.respond_accept");
  }
  if (response === "reject") {
    return td("action.summary.respond_reject");
  }
  return td("action.summary.respond_submitted");
}

function sleepSummary(result: Record<string, unknown> | undefined, target: Record<string, unknown> | string): string {
  const duration = numberField(result ?? {}, ["duration_game_minutes", "durationGameMinutes"])
    ?? (typeof target === "string" ? undefined : numberField(target, ["duration_game_minutes", "durationGameMinutes"]));
  const interrupted = result?.interrupted === true;
  if (duration == null) {
    return interrupted ? td("action.summary.sleep_interrupted") : td("action.summary.sleep_finished");
  }
  return interrupted
    ? td("action.summary.sleep_interrupted_duration_format", { duration })
    : td("action.summary.sleep_duration_format", { duration });
}

function numberField(record: Record<string, unknown>, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value)) {
      return value;
    }
  }
  return undefined;
}

function objectField(record: Record<string, unknown> | undefined, keys: string[]): Record<string, unknown> | undefined {
  if (!record) {
    return undefined;
  }
  for (const key of keys) {
    const value = record[key];
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
  }
  return undefined;
}

function objectValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

export function formatMoveToLocationToolResult(
  record: ActionLogRecord,
  target: Record<string, unknown> | string,
  displayTarget?: string,
  currentContext?: AgentCurrentContext,
): AgentToolResult<MoveToLocationToolDetails> {
  const targetType = moveTargetType(target);
  const destination = moveDestinationLabel(target, targetType, displayTarget);
  const elapsedGameMinutes = moveElapsedGameMinutes(record);
  const elapsedText = elapsedGameMinutes == null ? undefined : formatGameDurationMinutes(elapsedGameMinutes);
  const nearbyEnvironmentText = moveNearbyEnvironmentText(currentContext);
  const interrupted = isInterruptedAction(record);
  const timeText = actionGameTimeText(record);
  let text: string;

  if (record.status === "completed") {
    const elapsedPrefix = elapsedText ? td("action.move.elapsed_prefix_format", { elapsed: elapsedText }) : "";
    text = td("action.move.completed_format", {
      time: timeText,
      elapsedPrefix,
      arrival: moveArrivalText(destination, targetType),
    }) + (nearbyEnvironmentText ? `\n\n${nearbyEnvironmentText}` : "");
  } else if (record.status === "failed") {
    const reason = record.error
      ? td("action.move.reason_format", { reason: renderToolError(record.error) })
      : td("action.move.reason_not_arrived");
    text = td("action.move.failed_format", { time: timeText, destination, reason });
  } else if (record.status === "cancelled") {
    const reason = record.error
      ? td("action.move.reason_format", { reason: renderToolError(record.error) })
      : td("action.move.reason_cancelled");
    text = interrupted
      ? td("action.move.interrupted_format", { time: timeText, destination, reason })
      : td("action.move.cancelled_format", { time: timeText, destination, reason });
  } else {
    text = td("action.move.pending_format", { time: timeText, destination });
  }
  text = appendActionResultCharacterChangeText(text, record);

  return {
    content: [{ type: "text", text }],
    details: {
      actionId: record.id,
      status: record.status,
      error: record.error,
      completion: isTerminalActionStatus(record.status) ? "runtime_terminal" : "runtime_pending",
      interrupted,
      result: record.result,
      destination,
      targetType,
      elapsedGameMinutes,
      elapsedText,
    },
  };
}

export function formatSayToToolResult(
  record: ActionLogRecord,
  context: {
    toolName: string;
    target: Record<string, unknown> | string;
  },
): AgentToolResult<CharacterActionToolDetails> {
  const targetCharacterId = sayToTargetCharacterId(record, context.target);
  const targetLabel = localizeStringValue(targetCharacterId ?? "") ?? targetCharacterId ?? td("action.default_target");
  const text = sayToText(record, context.target);
  const heardBy = sayToHeardBy(record)
    .filter((listenerId) => listenerId !== targetCharacterId)
    .map((listenerId) => localizeStringValue(listenerId) ?? listenerId);
  const timeText = actionGameTimeText(record);
  const interrupted = isInterruptedAction(record);
  let contentText: string;

  if (record.status === "completed") {
    const heardByText = heardBy.length > 0
      ? td("action.say.heard_by_format", { listeners: heardBy.join(td("action.list_separator")) })
      : "";
    contentText = td("action.say.completed_format", { time: timeText, target: targetLabel, text, heardByText });
  } else if (record.status === "failed") {
    const reason = record.error ? renderToolError(record.error) : td("action.say.reason_not_spoken");
    contentText = td("action.say.failed_format", { time: timeText, target: targetLabel, text, reason });
  } else if (record.status === "cancelled") {
    const reason = record.error ? renderToolError(record.error) : td("action.say.reason_cancelled");
    contentText = interrupted
      ? td("action.say.interrupted_format", { time: timeText, target: targetLabel, reason })
      : td("action.say.cancelled_format", { time: timeText, target: targetLabel, reason });
  } else {
    contentText = td("action.say.pending_format", { time: timeText, target: targetLabel, text });
  }
  contentText = appendActionResultCharacterChangeText(contentText, record);

  return {
    content: [{ type: "text", text: contentText }],
    details: {
      actionId: record.id,
      status: record.status,
      error: record.error,
      completion: isTerminalActionStatus(record.status) ? "runtime_terminal" : "runtime_pending",
      interrupted,
      result: record.result,
    },
  };
}

export function formatPlanFarmWorkToolResult(
  record: ActionLogRecord,
  context: {
    toolName: string;
    target: Record<string, unknown> | string;
    resultNote?: string;
    displayTarget?: string;
  },
): AgentToolResult<CharacterActionToolDetails> {
  const result = record.result ?? {};
  const completed = recordListField(result, "completed");
  const remaining = recordListField(result, "remaining", planFarmOpsFromTarget(context.target));
  const progressText = formatFarmProgressText(completed, remaining, result);
  const interrupted = isInterruptedAction(record);
  const completion = isTerminalActionStatus(record.status) ? "runtime_terminal" : "runtime_pending";
  const text = renderFarmWorkContext(record, progressText, interrupted);

  return {
    content: [{ type: "text", text }],
    details: {
      actionId: record.id,
      status: record.status,
      error: record.error,
      completion,
      interrupted,
      result: record.result,
    },
  };
}

function renderFarmWorkContext(
  record: ActionLogRecord,
  progressText: string,
  interrupted: boolean,
): string {
  const timeText = actionGameTimeText(record);
  const lines = [
    td("action.farm.header"),
    td("action.farm.result_format", { time: timeText, progress: progressText || td("action.farm.empty_progress") }),
  ];
  if (record.error) {
    lines.push(td("action.result.reason_format", { reason: renderToolError(record.error) }));
  }
  lines.push(...renderActionResultCharacterChangeLines(record.result));
  lines.push(...renderFarmFailureLines(recordListField(record.result ?? {}, "completed")));
  if (!isTerminalActionStatus(record.status)) {
    lines.push(td("action.farm.pending_note"));
  } else if (interrupted) {
    const reason = stringField(record.result ?? {}, ["reason"]);
    if (reason === "slot_occupied") {
      lines.push(td("action.farm.interrupted_slot_occupied"));
    } else if (reason === "stamina_depleted") {
      lines.push(td("action.farm.interrupted_stamina_depleted"));
    } else {
      lines.push(td("action.farm.interrupted_default"));
    }
  }
  return lines.join("\n");
}

function appendActionResultCharacterChangeText(text: string, record: ActionLogRecord): string {
  const changeLines = renderActionResultCharacterChangeLines(record.result);
  return changeLines.length > 0 ? [text, ...changeLines].join("\n") : text;
}

function formatFarmProgressText(
  completed: Record<string, unknown>[],
  remaining: Record<string, unknown>[],
  result: Record<string, unknown>,
): string {
  const successes = completed.filter(isFarmOpSuccess);
  const failedCount = completed.length - successes.length;
  const counts = farmActionCounts(successes);
  const parts = [
    farmCountText(counts.plant, "plant"),
    farmCountText(counts.water, "water"),
    farmCountText(counts.pest, "pest"),
    farmCountText(counts.harvest, "harvest"),
    farmCountText(counts.uproot, "uproot"),
  ].filter((part): part is string => Boolean(part));
  const completedText = parts.length > 0 ? parts.join(td("action.clause_separator")) : td("action.farm.completed_zero");
  const failedText = failedCount > 0 ? td("action.farm.failed_count_format", { count: failedCount }) : undefined;
  const remainingText = remaining.length > 0
    ? td("action.farm.remaining_count_format", { count: remaining.length })
    : td("action.farm.remaining_none");
  const activeText = farmActiveText(result);
  return [completedText, failedText, remainingText, activeText].filter(Boolean).join(td("action.clause_separator"));
}

function farmActionCounts(records: Record<string, unknown>[]): Record<string, number> {
  const counts: Record<string, number> = { plant: 0, water: 0, pest: 0, harvest: 0, uproot: 0 };
  for (const record of records) {
    const kind = stringField(record, ["kind"]);
    if (kind && counts[kind] != null) {
      counts[kind] += 1;
    }
  }
  return counts;
}

function farmCountText(count: number, kind: string): string | undefined {
  return count > 0 ? td(`action.farm.count.${kind}`, { count }) : undefined;
}

function isFarmOpSuccess(record: Record<string, unknown>): boolean {
  if (record.ok === false) {
    return false;
  }
  const result = objectValue(record.result);
  return result?.ok !== false;
}

function renderFarmFailureLines(completed: Record<string, unknown>[]): string[] {
  const failures = completed.filter((record) => !isFarmOpSuccess(record));
  if (failures.length === 0) {
    return [];
  }
  const lines = [td("action.farm.failure_header")];
  for (const failure of failures.slice(0, 5)) {
    lines.push(`- ${renderFarmFailureLine(failure)}`);
  }
  if (failures.length > 5) {
    lines.push(`- ${td("action.farm.failure_overflow_format", { count: failures.length - 5 })}`);
  }
  return lines;
}

function renderFarmFailureLine(record: Record<string, unknown>): string {
  const kind = stringField(record, ["kind"]);
  const slot = numberField(record, ["slot_index", "slotIndex", "index"]);
  const result = objectValue(record.result);
  const message = stringField(result ?? {}, ["message", "error", "reason"])
    ?? stringField(record, ["message", "error", "reason"])
    ?? JSON.stringify(localizeValue(result ?? record));
  const slotText = slot != null ? td("action.farm.failure_slot_format", { slot }) : "";
  const actionText = kind ? td("action.farm.failure_action_format", { action: farmActionLabel(kind) }) : "";
  return td("action.farm.failure_line_format", { slot: slotText, action: actionText, reason: localizeText(message) });
}

function farmActiveText(result: Record<string, unknown>): string | undefined {
  const state = stringField(result, ["active_state", "activeState"]);
  const kind = stringField(result, ["active_kind", "activeKind"]);
  if (!state || !kind) {
    return undefined;
  }
  const action = farmActionLabel(kind);
  return state === "walking"
    ? td("action.farm.active_walking_format", { action })
    : td("action.farm.active_working_format", { action });
}

function farmActionLabel(kind: string): string {
  return tdOr(`action.farm.action.${kind}`, kind);
}

function planFarmOpsFromTarget(target: Record<string, unknown> | string): Record<string, unknown>[] {
  if (typeof target === "string") {
    return [];
  }
  return recordListValue(target.ops);
}

function recordListField(record: Record<string, unknown>, key: string, fallback: Record<string, unknown>[] = []): Record<string, unknown>[] {
  return recordListValue(record[key], fallback);
}

function recordListValue(value: unknown, fallback: Record<string, unknown>[] = []): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    return fallback;
  }
  return value.filter((entry): entry is Record<string, unknown> => Boolean(entry) && typeof entry === "object" && !Array.isArray(entry));
}

function renderToolError(error: string): string {
  const eventInterruptedPrefix = td("action.interrupted_by_event_prefix");
  const interruptedPrefix = td("action.interrupted_prefix");
  // 跨角色单占失败：Godot 端只传 id，名字翻译统一在 backend 边界做（memory: feedback_llm_id_name_boundary）。
  // 格式：`workstation <ws_id> busy: held by <operator_id>` → `工作台 <ws名> 正被 <operator名> 使用中`
  const busyMatch = error.match(/^workstation (\S+) busy: held by (\S+)$/);
  if (busyMatch) {
    return td("workstation_common.error.busy_format", {
      workstation: workstationName(busyMatch[1]) || busyMatch[1],
      operator: characterName(busyMatch[2]),
    });
  }
  return localizeText(error
    .replace(/^interrupted by event [^:]+:\s*/, eventInterruptedPrefix)
    .replace(/^interrupted:\s*/, interruptedPrefix));
}

function isInterruptedAction(record: ActionLogRecord): boolean {
  if (record.result?.interrupted === true) {
    return true;
  }
  return typeof record.error === "string"
    && (record.error.startsWith("interrupted by event ") || record.error.startsWith("interrupted:"));
}

function actionGameTimeText(record: ActionLogRecord): string {
  return formatGameTime(
    record.completedGameTime
      ?? record.failedGameTime
      ?? record.acceptedGameTime
      ?? record.gameTime,
  ) ?? td("action.time_now");
}

function isTerminalActionStatus(status: string): boolean {
  return status === "completed" || status === "failed" || status === "cancelled";
}

function renderToolTarget(target: Record<string, unknown> | string, displayTarget?: string): string {
  if (displayTarget?.trim()) {
    return td("action.target.label_format", { value: localizeText(displayTarget) });
  }
  if (typeof target === "string") {
    return target ? td("action.target.label_format", { value: localizeStringValue(target) }) : "";
  }
  const text = typeof target.text === "string" ? target.text : undefined;
  const targetCharacterId = stringField(target, ["targetCharacterId", "target_character_id", "character", "characterId", "character_id", "to"]);
  if (text) {
    return targetCharacterId
      ? td("action.target.speech_with_target_format", { target: localizeStringValue(targetCharacterId), text: localizeText(text) })
      : td("action.target.speech_no_target_format", { text: localizeText(text) });
  }
  if (target.targetType === "character" && typeof target.characterId === "string") {
    return td("action.target.label_format", { value: localizeStringValue(target.characterId) });
  }
  if (target.targetType === "item" && typeof target.item === "string") {
    return td("action.target.item_format", { item: localizeText(target.item) });
  }
  const farmId = stringField(target, ["farm_id", "farmId", "farm"]);
  if (farmId) {
    return td("action.target.farm_format", { farm: localizeStringValue(farmId) });
  }
  const workstationId = stringField(target, ["workstation_id", "workstationId", "workstation"]);
  if (workstationId) {
    const verb = stringField(target, ["verb"]);
    const subOption = stringField(target, ["sub_option", "subOption"]);
    const action = [verb, subOption].filter(Boolean).join("/");
    return action
      ? td("action.target.workstation_with_action_format", { workstation: localizeStringValue(workstationId), action })
      : td("action.target.workstation_format", { workstation: localizeStringValue(workstationId) });
  }
  const item = stringField(target, ["item", "seed"]);
  if (item) {
    return td("action.target.label_format", { value: localizeText(item) });
  }
  return td("action.target.label_format", { value: JSON.stringify(localizeValue(target)) });
}

function sayToTargetCharacterId(record: ActionLogRecord, target: Record<string, unknown> | string): string | undefined {
  return stringField(record.result ?? {}, ["targetCharacterId", "target_character_id"])
    ?? (typeof target === "string" ? undefined : stringField(target, ["targetCharacterId", "target_character_id", "character", "characterId", "character_id", "to"]));
}

function sayToText(record: ActionLogRecord, target: Record<string, unknown> | string): string {
  const raw = stringField(record.result ?? {}, ["text"])
    ?? (typeof target === "string" ? undefined : stringField(target, ["text"]))
    ?? "";
  return localizeText(raw);
}

function sayToHeardBy(record: ActionLogRecord): string[] {
  return stringListField(record.result ?? {}, ["heardByCharacterIds", "heard_by_character_ids", "heardBy", "heard_by"]);
}

function stringField(record: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) {
      return value;
    }
  }
  return undefined;
}

function stringListField(record: Record<string, unknown>, keys: string[]): string[] {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) {
      return [value];
    }
    if (Array.isArray(value)) {
      return value.filter((entry): entry is string => typeof entry === "string" && entry.length > 0);
    }
  }
  return [];
}

function moveTargetType(target: Record<string, unknown> | string): MoveToLocationToolDetails["targetType"] {
  if (typeof target !== "string") {
    if (target.targetType === "character") {
      return "character";
    }
    if (target.targetType === "item") {
      return "item";
    }
    return "location";
  }
  const currentLocationLabel = td("common.current_location_value");
  return normalizeLocationInput(target) === normalizeLocationInput(currentLocationLabel)
    ? "current_location"
    : "location";
}

function moveDestinationLabel(
  target: Record<string, unknown> | string,
  targetType: MoveToLocationToolDetails["targetType"],
  displayTarget?: string,
): string {
  if (displayTarget?.trim()) {
    return localizeText(displayTarget);
  }
  if (typeof target === "string") {
    return localizeStringValue(target) ?? target;
  }
  if (targetType === "character" && typeof target.characterId === "string") {
    return characterName(target.characterId);
  }
  if (targetType === "item" && typeof target.item === "string") {
    return localizeText(target.item);
  }
  return stripToolTargetPrefix(renderToolTarget(target));
}

function moveArrivalText(
  destination: string,
  targetType: MoveToLocationToolDetails["targetType"],
): string {
  if (targetType === "character" || targetType === "item") {
    return td("action.move.arrival_nearby_format", { destination });
  }
  return td("action.move.arrival_location_format", { destination });
}

function moveNearbyEnvironmentText(current: AgentCurrentContext | undefined): string {
  if (!current) {
    return "";
  }
  const interactiveSection = renderInteractiveSitesSection(current);
  const sections = [
    ...renderNearbyEnvironmentSections(current),
    interactiveSection,
  ].filter((section): section is { title: string; body: string } => Boolean(section));
  return sections
    .map((section) => `# ${section.title}\n${section.body}`)
    .join("\n\n");
}

function moveElapsedGameMinutes(record: ActionLogRecord): number | undefined {
  const start = gameTimeTotalMinutes(record.acceptedGameTime ?? record.gameTime);
  const end = gameTimeTotalMinutes(record.completedGameTime ?? record.failedGameTime);
  if (start == null || end == null) {
    return undefined;
  }
  return Math.max(0, end - start);
}

function gameTimeTotalMinutes(value: GameTimeSnapshot | undefined): number | undefined {
  if (!value) {
    return undefined;
  }
  if (typeof value.totalGameMinutes === "number") {
    return value.totalGameMinutes;
  }
  if (typeof value.totalGameHours === "number") {
    return (value.totalGameHours * 60) + (value.minute ?? 0);
  }
  if (typeof value.day === "number" && typeof value.hour === "number" && typeof value.minute === "number") {
    return (((value.day * 24) + value.hour) * 60) + value.minute;
  }
  return undefined;
}

function formatGameDurationMinutes(totalMinutes: number): string {
  const clamped = Math.max(0, Math.floor(totalMinutes));
  const hours = Math.floor(clamped / 60);
  const minutes = clamped % 60;
  return td("action.duration.hours_minutes_format", { hours, minutes });
}

function tdOr(key: string, fallback: string): string {
  const value = td(key);
  return value === `tool.${key}` ? fallback : value;
}

function stripToolTargetPrefix(value: string): string {
  const prefix = td("action.target.label_prefix");
  return value.replace(new RegExp(`^${escapeRegExp(prefix)}\\s*`), "");
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
