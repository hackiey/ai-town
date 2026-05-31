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
    "# 行动结果",
    `动作：${genericActionName(toolName)}`,
    targetText,
  ];
  const timeText = actionGameTimeText(record);
  const summary = genericActionSummary(toolName, record, target, displayTarget);
  if (summary) {
    lines.push(`结果：${timeText}，${summary}`);
  } else if (record.status === "failed" || record.status === "cancelled") {
    const verb = record.status === "failed" ? "失败" : "被取消";
    lines.push(`结果：${timeText}，${genericActionName(toolName)}${verb}。`);
  }
  lines.push(...renderActionResultCharacterChangeLines(record.result));
  if (record.error) {
    lines.push(`原因：${renderToolError(record.error)}`);
  }
  if (resultNote && !isTerminalActionStatus(record.status)) {
    lines.push("结果：原工作仍在进行中（不会因这次中断而停下）。");
  }
  return lines.join("\n");
}

function genericActionName(toolName: string): string {
  switch (toolName) {
    case "plan_farm_work": return "农事工单";
    case "use_workstation": return "工作台动作";
    case "use_item": return "使用物品";
    case "pick_up_item": return "拾取物品";
    case "drop_item": return "放下物品";
    case "update_shelf": return "更新货架";
    case "buy_from_shelf": return "购买货架物品";
    case "offer": return "递交 / 交换";
    case "respond": return "回应请求";
    case "deposit_to_container": return "存入容器";
    case "withdraw_from_container": return "从容器取出";
    case "inspect_container": return "查看容器";
    case "write": return "书写";
    case "read": return "阅读";
    case "sleep": return "睡觉";
    default: return toolName;
  }
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
    return `${genericActionName(toolName)}正在进行。`;
  }
  const resultMessage = stringField(record.result ?? {}, ["message", "summary"]);
  if (resultMessage) {
    return localizeText(resultMessage);
  }
  switch (toolName) {
    case "pick_up_item": return `已拾取 ${targetItemLabel(target, displayTarget)}。`;
    case "drop_item": return `已放下 ${targetItemLabel(target, displayTarget)}。`;
    case "use_item": return `已使用 ${targetItemLabel(target, displayTarget)}。`;
    case "deposit_to_container": return "已把物品存入容器。";
    case "withdraw_from_container": return "已从容器取出物品。";
    case "inspect_container": return inspectContainerSummary(record.result);
    case "buy_from_shelf": return "购买已完成。";
    case "update_shelf": return "货架已更新。";
    case "offer": return "递交动作已提交。";
    case "respond": return respondSummary(record.result, target);
    case "sleep": return sleepSummary(record.result, target);
    default: return `${genericActionName(toolName)}已完成。`;
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
  return item ? localizeStringValue(item) : renderToolTarget(target).replace(/^目标\s*/, "");
}

function inspectContainerSummary(result: Record<string, unknown> | undefined): string {
  const snapshot = objectField(result, ["snapshot"]);
  const items = recordListValue(snapshot?.items ?? result?.items);
  if (items.length === 0) {
    return "容器里没有可见物品。";
  }
  return `容器里有 ${items.map(containerItemLabel).join("、")}。`;
}

function containerItemLabel(entry: Record<string, unknown>): string {
  const item = stringField(entry, ["itemId", "item_id", "item"]);
  const quantity = numberField(entry, ["quantity", "qty", "count"]);
  const quality = numberField(entry, ["quality"]);
  const base = item ? localizeStringValue(item) : JSON.stringify(localizeValue(entry));
  const quantityText = quantity == null ? "" : ` x${quantity}`;
  const qualityText = quality == null ? "" : `（品质 ${quality}）`;
  return `${base}${quantityText}${qualityText}`;
}

// respond 目前只覆盖 kind=trade（accept/reject 交易）。未来扩 kind 时按 target.kind 分支。
function respondSummary(result: Record<string, unknown> | undefined, target: Record<string, unknown> | string): string {
  const response = stringField(result ?? {}, ["response"])
    ?? (typeof target === "string" ? undefined : stringField(target, ["response"]));
  if (response === "accept") {
    return "已接受请求。";
  }
  if (response === "reject") {
    return "已拒绝请求。";
  }
  return "请求回应已提交。";
}

function sleepSummary(result: Record<string, unknown> | undefined, target: Record<string, unknown> | string): string {
  const duration = numberField(result ?? {}, ["duration_game_minutes", "durationGameMinutes"])
    ?? (typeof target === "string" ? undefined : numberField(target, ["duration_game_minutes", "durationGameMinutes"]));
  const interrupted = result?.interrupted === true;
  if (duration == null) {
    return interrupted ? "睡眠被打断。" : "睡眠结束。";
  }
  return interrupted ? `睡眠被打断，原计划睡 ${duration} 分钟。` : `睡了 ${duration} 分钟。`;
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
    const elapsedPrefix = elapsedText ? `行走了${elapsedText}，` : "";
    text = `${timeText}，${elapsedPrefix}${moveArrivalText(destination, targetType)}${nearbyEnvironmentText ? `\n\n${nearbyEnvironmentText}` : ""}`;
  } else if (record.status === "failed") {
    const reason = record.error ? `原因：${renderToolError(record.error)}。` : "没有到达目标。";
    text = `${timeText}，前往 ${destination} 失败，${reason}`;
  } else if (record.status === "cancelled") {
    const reason = record.error ? `原因：${renderToolError(record.error)}。` : "动作被取消。";
    text = interrupted
      ? `${timeText}，前往 ${destination} 已被打断，${reason}`
      : `${timeText}，前往 ${destination} 已取消，${reason}`;
  } else {
    text = `${timeText}，正在前往 ${destination}。`;
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
    const heardByText = heardBy.length > 0 ? `\n旁听者：${heardBy.join("、")}。` : "";
    contentText = `${timeText}，你对${targetLabel}说：“${text}”${heardByText}`;
  } else if (record.status === "failed") {
    const reason = record.error ? renderToolError(record.error) : "没有说出口";
    contentText = `${timeText}，你没能对${targetLabel}说：${text}。原因：${reason}。`;
  } else if (record.status === "cancelled") {
    const reason = record.error ? renderToolError(record.error) : "动作被取消";
    contentText = interrupted
      ? `${timeText}，你对${targetLabel}说的话被打断了。原因：${reason}。`
      : `${timeText}，你对${targetLabel}说的话被取消了。原因：${reason}。`;
  } else {
    contentText = `${timeText}，你正要对${targetLabel}说：${text}。`;
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
    "# 农事结果",
    `结果：${timeText}，${progressText || "没有完成的农事。"}`,
  ];
  if (record.error) {
    lines.push(`原因：${renderToolError(record.error)}`);
  }
  lines.push(...renderActionResultCharacterChangeLines(record.result));
  lines.push(...renderFarmFailureLines(recordListField(record.result ?? {}, "completed")));
  if (!isTerminalActionStatus(record.status)) {
    lines.push("未完成：农事仍在进行中（动作没有取消，会在后台继续）。如需回应周围事件可调用 say_to，不会打断农事；其他占用身体的工具会接力安排，等农事自然结束后再起。");
  } else if (interrupted) {
    const reason = stringField(record.result ?? {}, ["reason"]);
    if (reason === "slot_occupied") {
      lines.push("未完成：种植时遇到 slot 已被占用，农事提前停止。请按最新农田上下文重新规划再发工单。");
    } else if (reason === "stamina_depleted") {
      lines.push("未完成：体力不足，农事提前停止。");
    } else {
      lines.push("未完成：农事被打断，还有剩余项。取最新农田上下文判断后续动作。");
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
    farmCountText(counts.plant, "已种植", "格"),
    farmCountText(counts.water, "已浇水", "次"),
    farmCountText(counts.pest, "已除虫", "格"),
    farmCountText(counts.harvest, "已收获", "格"),
    farmCountText(counts.uproot, "已铲除", "格"),
  ].filter((part): part is string => Boolean(part));
  const completedText = parts.length > 0 ? parts.join("，") : "已完成0项";
  const failedText = failedCount > 0 ? `失败${failedCount}项` : undefined;
  const remainingText = remaining.length > 0 ? `还有${remaining.length}项未完成` : "没有剩余项";
  const activeText = farmActiveText(result);
  return [completedText, failedText, remainingText, activeText].filter(Boolean).join("，");
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

function farmCountText(count: number, label: string, unit: string): string | undefined {
  return count > 0 ? `${label}${count}${unit}` : undefined;
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
  const lines = ["失败项："];
  for (const failure of failures.slice(0, 5)) {
    lines.push(`- ${renderFarmFailureLine(failure)}`);
  }
  if (failures.length > 5) {
    lines.push(`- 还有${failures.length - 5}项失败未列出。`);
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
  const slotText = slot != null ? `slot ${slot} ` : "";
  const actionText = kind ? `${farmActionLabel(kind)} ` : "";
  return `${slotText}${actionText}失败：${localizeText(message)}`;
}

function farmActiveText(result: Record<string, unknown>): string | undefined {
  const state = stringField(result, ["active_state", "activeState"]);
  const kind = stringField(result, ["active_kind", "activeKind"]);
  if (!state || !kind) {
    return undefined;
  }
  const action = farmActionLabel(kind);
  return state === "walking" ? `正在前往${action}目标` : `正在${action}`;
}

function farmActionLabel(kind: string): string {
  switch (kind) {
    case "plant": return "种植";
    case "water": return "浇水";
    case "pest": return "除虫";
    case "harvest": return "收获";
    case "uproot": return "铲除";
    default: return kind;
  }
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
  ) ?? "此刻";
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
  return renderToolTarget(target).replace(/^目标\s*/, "");
}

function moveArrivalText(
  destination: string,
  targetType: MoveToLocationToolDetails["targetType"],
): string {
  if (targetType === "character" || targetType === "item") {
    return `到达 ${destination} 附近。`;
  }
  return `到达 ${destination} 地点。`;
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
  return `${hours}时${minutes}分`;
}
