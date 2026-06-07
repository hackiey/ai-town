// Action notice 渲染：把 ContinuedActionManager 投递出来的 ActionNotice 拼成 user message
// 喂给 agent。其中 axis 工作台工具（mine / cook / smelt / ...）走专门的
// "工作台结果"模板（详细，含进度/产出/状态变化），plan_farm_work 复用 game-tools 自己的
// 格式化器（保持和直接调用结果一致），其它 tool 走通用模板。
//
// 这一层不持有任何状态，所有数据从 notice 自带。

import type { AfterToolCallContext } from "@mariozechner/pi-agent-core";
import { getActiveLocale, t } from "../../i18n/index.js";
import type { ActionLogRecord } from "../../godot-link/protocol.js";
import { localizeStringValue, localizeText } from "../name-resolver/index.js";
import {
  parseAgentCharacterChanges,
  renderActionResultCharacterChangeLines,
  renderAgentCharacterChangeLines,
  type AgentCharacterChanges,
} from "../game-tools/character-changes.js";
import { formatPlanFarmWorkToolResult } from "../game-tools/action-results.js";
import { isKnownCraft } from "../game-tools/craft-registry.js";
import { numberValue, objectValue, stringArray, stringValue } from "../utils/primitives.js";
import type { ActionNotice } from "./queue.js";

export function renderActionNotices(title: string, notices: ActionNotice[]): string {
  const lines = [
    `# ${title}`,
    "以下是此前已返回“仍在进行中”的行动完成提醒，不是当前工具调用本身的结果。",
  ];
  for (const notice of notices) {
    lines.push(renderActionNotice(notice));
  }
  lines.push("你可以继续当前对话；如果该行动结果改变了下一步计划，再选择合适工具。不要重复提交已经完成的工作。");
  return lines.join("\n\n");
}

export function renderUseWorkstationToolResultPrompt(context: AfterToolCallContext): string {
  return renderWorkstationContextForAgent(buildAgentWorkstationContext({
    actionStatus: stringValue(objectValue(context.result.details)?.status) ?? (context.isError ? "failed" : "completed"),
    isError: context.isError,
    args: context.args,
    toolResultDetails: context.result.details,
    toolResultContent: context.result.content,
  }));
}

function renderActionNotice(notice: ActionNotice): string {
  const status = actionNoticeStatusText(notice.record.status);
  return [
    `## ${notice.toolName} ${status}（actionId=${notice.actionId}）`,
    renderContinuedActionRecord(notice.record, notice.toolName),
  ].filter(Boolean).join("\n");
}

function actionNoticeStatusText(status: string): string {
  switch (status) {
    case "completed": return "已完成";
    case "failed": return "失败";
    case "cancelled": return "已取消";
    case "interrupted": return "已中断";
    default: return status;
  }
}

function renderContinuedActionRecord(record: ActionLogRecord, toolName: string): string {
  if (isKnownCraft(toolName)) {
    return renderWorkstationContextForAgent(buildAgentWorkstationContext({
      actionStatus: record.status,
      isError: record.status === "failed",
      args: record.target,
      toolResultDetails: {
        status: record.status,
        error: record.error,
        result: record.result,
      },
      toolResultContent: [],
    }));
  }
  if (toolName === "plan_farm_work") {
    return formatContentText(formatPlanFarmWorkToolResult(record, {
      toolName,
      target: record.target ?? {},
    }).content) ?? renderGenericContinuedActionRecord(record, toolName);
  }
  return renderGenericContinuedActionRecord(record, toolName);
}

function renderGenericContinuedActionRecord(record: ActionLogRecord, toolName: string): string {
  const lines = [
    "# 行动结果",
    `动作：${toolName}`,
    `状态：${actionNoticeStatusText(record.status)}`,
  ];
  if (record.target != null) {
    lines.push(`目标：${formatContinuityValue(record.target)}`);
  }
  if (record.error) {
    lines.push(`原因：${renderAgentToolError(record.error)}`);
  }
  lines.push(...renderActionResultCharacterChangeLines(record.result));
  if (record.result && Object.keys(record.result).length > 0) {
    lines.push(`结果：${formatContinuityValue(record.result)}`);
  }
  return lines.join("\n");
}

// ---------- workstation result 渲染 ----------

type WorkstationContextPhase = "not_started" | "in_progress" | "terminal";
type WorkstationContextStatus = "succeeded" | "business_failed" | "runtime_failed" | "cancelled" | "interrupted_partial" | "pending";
type WorkstationContextStorage = "backpack" | "treasury_vault" | "none" | "unknown";

type AgentWorkstationContext = {
  kind: "workstation_result";
  phase: WorkstationContextPhase;
  status: WorkstationContextStatus;
  action: {
    workstationId?: string;
    workstationName: string;
    verb?: string;
    verbName?: string;
    subOption?: string;
    subOptionName?: string;
    inputs: string[];
  };
  outcome: {
    summary: string;
    outputs: string[];
    storage: WorkstationContextStorage;
    qualityModifier?: number;
    brokenTools: string[];
    reasonCode?: string;
    reasonText?: string;
  };
  changes: AgentCharacterChanges;
  progress?: {
    durationGameSeconds?: number;
    elapsedGameSeconds?: number;
    remainingGameSeconds?: number;
  };
  mining?: {
    attempts: number;
    successfulAttempts: number;
    outputTotals: Record<string, number>;
    outputLabels: string[];
    attemptIntervalGameSeconds?: number;
  };
  raw: Record<string, unknown>;
};

function buildAgentWorkstationContext(input: {
  actionStatus: string;
  isError: boolean;
  args: unknown;
  toolResultDetails: unknown;
  toolResultContent: unknown;
}): AgentWorkstationContext {
  const details = objectValue(input.toolResultDetails);
  const raw = objectValue(details?.result) ?? {};
  const args = objectValue(input.args);
  const error = stringValue(details?.error);
  const phase = deriveWorkstationPhase(input.actionStatus, raw);
  const status = deriveWorkstationStatus(input.actionStatus, input.isError, raw);
  const action = buildWorkstationActionContext(args, raw);
  const mining = buildWorkstationMiningContext(raw);
  const outputs = workstationOutputLabels(raw, mining);
  const message = workstationMessage(raw, input.toolResultContent);
  const reasonCode = stringValue(raw.reason);
  const reasonText = workstationReasonText(status, message, error);
  return {
    kind: "workstation_result",
    phase,
    status,
    action,
    outcome: {
      summary: workstationSummary(status, raw, mining, outputs, message),
      outputs,
      storage: deriveWorkstationStorage(status, action.workstationId, outputs, mining, raw),
      qualityModifier: numberValue(raw.quality_modifier ?? raw.qualityModifier),
      brokenTools: stringArray(raw.broken_tools ?? raw.brokenTools).map(localizeWorkstationValue),
      reasonCode,
      reasonText,
    },
    changes: parseAgentCharacterChanges(raw.character_changes ?? raw.characterChanges),
    progress: buildWorkstationProgressContext(raw),
    mining,
    raw,
  };
}

function buildWorkstationActionContext(args: Record<string, unknown> | undefined, raw: Record<string, unknown>): AgentWorkstationContext["action"] {
  const workstationId = stringValue(raw.workstation_id)
    ?? stringValue(raw.workstationId)
    ?? stringValue(args?.workstation_id)
    ?? stringValue(args?.workstationId)
    ?? stringValue(args?.workstation);
  const verb = stringValue(raw.verb) ?? stringValue(args?.verb);
  const subOption = stringValue(raw.sub_option)
    ?? stringValue(raw.subOption)
    ?? stringValue(args?.sub_option)
    ?? stringValue(args?.subOption);
  const rawInputs = stringArray(raw.inputs).length > 0 ? stringArray(raw.inputs) : stringArray(args?.inputs);
  return {
    workstationId,
    workstationName: workstationId ? localizeWorkstationValue(workstationId) : "工作台",
    verb,
    verbName: verb ? localizeVerbName(verb) : undefined,
    subOption,
    subOptionName: verb && subOption ? localizeVerbSubOptionName(verb, subOption) : (subOption ? localizeWorkstationValue(subOption) : undefined),
    inputs: rawInputs.map(localizeWorkstationValue),
  };
}

function deriveWorkstationPhase(actionStatus: string, raw: Record<string, unknown>): WorkstationContextPhase {
  if (booleanValue(raw.inProgress) === true || booleanValue(raw.in_progress) === true) return "in_progress";
  if (booleanValue(raw.actionCompleted) === false || booleanValue(raw.action_completed) === false) {
    return actionStatus === "cancelled" || booleanValue(raw.cancelled) === true ? "terminal" : "not_started";
  }
  return "terminal";
}

function deriveWorkstationStatus(actionStatus: string, isError: boolean, raw: Record<string, unknown>): WorkstationContextStatus {
  if (booleanValue(raw.inProgress) === true || booleanValue(raw.in_progress) === true) return "pending";
  if (actionStatus === "cancelled" || booleanValue(raw.cancelled) === true) return "cancelled";
  if (booleanValue(raw.interrupted) === true) return "interrupted_partial";
  if (actionStatus === "failed" || isError) return "runtime_failed";
  const outcome = stringValue(raw.outcome);
  if (booleanValue(raw.ok) === false || outcome === "failure" || outcome === "failed") return "business_failed";
  if (actionStatus === "completed") return "succeeded";
  return "pending";
}

function buildWorkstationProgressContext(raw: Record<string, unknown>): AgentWorkstationContext["progress"] | undefined {
  const progress = {
    durationGameSeconds: numberValue(raw.duration ?? raw.duration_seconds ?? raw.durationGameSeconds),
    elapsedGameSeconds: numberValue(raw.elapsed_game_seconds ?? raw.elapsedGameSeconds),
    remainingGameSeconds: numberValue(raw.remaining_game_seconds ?? raw.remainingGameSeconds),
  };
  return Object.values(progress).some((value) => value != null) ? progress : undefined;
}

function buildWorkstationMiningContext(raw: Record<string, unknown>): AgentWorkstationContext["mining"] | undefined {
  const outputTotals = numberRecord(raw.mining_totals ?? raw.miningTotals);
  const attempts = numberValue(raw.attempts);
  const successfulAttempts = numberValue(raw.successful_attempts ?? raw.successfulAttempts);
  const outputLabels = stringArray(raw.outputs).map(localizeWorkstationValue);
  const hasMiningData = attempts != null || successfulAttempts != null || Object.keys(outputTotals).length > 0;
  if (!hasMiningData) return undefined;
  return {
    attempts: attempts ?? 0,
    successfulAttempts: successfulAttempts ?? 0,
    outputTotals,
    outputLabels,
    attemptIntervalGameSeconds: numberValue(raw.attempt_interval_game_seconds ?? raw.attemptIntervalGameSeconds),
  };
}

function workstationOutputLabels(raw: Record<string, unknown>, mining: AgentWorkstationContext["mining"]): string[] {
  if (mining && mining.outputLabels.length > 0) return mining.outputLabels;
  const outputs = stringArray(raw.outputs).map(localizeWorkstationValue);
  if (outputs.length > 0) return outputs;
  const directResult = objectValue(raw.result);
  const item = stringValue(directResult?.item);
  const content = stringValue(directResult?.content);
  const amountAdded = numberValue(directResult?.amount_added ?? directResult?.amountAdded);
  if (item && content) {
    const amountText = amountAdded != null ? ` +${Math.floor(amountAdded)}` : "";
    return [`${localizeWorkstationValue(item)} 装入 ${localizeWorkstationValue(content)}${amountText}`];
  }
  return [];
}

function workstationMessage(raw: Record<string, unknown>, fallbackContent: unknown): string | undefined {
  const message = stringValue(raw.message) ?? stringValue(raw.label);
  if (message) return localizeText(message).replace(/…$/, "");
  const fallback = formatContentText(fallbackContent)?.trim();
  return fallback ? localizeText(fallback) : undefined;
}

function workstationSummary(
  status: WorkstationContextStatus,
  raw: Record<string, unknown>,
  mining: AgentWorkstationContext["mining"],
  outputs: string[],
  message: string | undefined,
): string {
  if (mining) {
    const mined = outputs.length > 0 ? outputs.join("、") : "没有挖到矿石";
    if (status === "interrupted_partial") return `采矿被打断；这次挖了 ${mining.attempts} 次，收获 ${mined}。`;
    if (stringValue(raw.reason) === "tool_broken") return `采矿提前结束，工具损坏；这次挖了 ${mining.attempts} 次，收获 ${mined}。`;
    return `采矿结束；这次挖了 ${mining.attempts} 次，收获 ${mined}。`;
  }
  return message ?? defaultWorkstationSummary(status);
}

function workstationReasonText(status: WorkstationContextStatus, message: string | undefined, error: string | undefined): string | undefined {
  if (status === "runtime_failed" || status === "cancelled") return error ? renderAgentToolError(error) : message;
  if (status === "business_failed") return message;
  return undefined;
}

function deriveWorkstationStorage(
  status: WorkstationContextStatus,
  workstationId: string | undefined,
  outputs: string[],
  mining: AgentWorkstationContext["mining"],
  raw: Record<string, unknown>,
): WorkstationContextStorage {
  if (mining || objectValue(raw.mining_totals) || Array.isArray(raw.mining_diverted)) {
    return outputs.length > 0 ? "treasury_vault" : "none";
  }
  if (status === "business_failed" || status === "runtime_failed" || status === "cancelled") return "none";
  if (outputs.length > 0 || workstationId === "well") return "backpack";
  return status === "pending" || status === "interrupted_partial" ? "unknown" : "none";
}

function defaultWorkstationSummary(status: WorkstationContextStatus): string {
  switch (status) {
    case "succeeded": return "工作台动作已完成。";
    case "business_failed": return "工作台动作执行完毕，但制作结果失败。";
    case "runtime_failed": return "工作台动作没有成功开始或执行失败。";
    case "cancelled": return "工作台动作已取消。";
    case "interrupted_partial": return "工作台动作被打断，但返回了阶段性结果。";
    case "pending": return "工作台动作正在执行。";
  }
}

function renderWorkstationContextForAgent(context: AgentWorkstationContext): string {
  const lines = [
    "# 工作台结果",
    `动作：${renderWorkstationActionLine(context)}`,
  ];
  if (context.action.inputs.length > 0) {
    lines.push(`输入：${context.action.inputs.join("、")}`);
  }
  if (context.progress) {
    lines.push(`用时：${renderWorkstationProgressLine(context.progress)}`);
  }
  lines.push(`结果：${context.outcome.summary}`);
  if (context.outcome.reasonText && context.outcome.reasonText !== context.outcome.summary) {
    lines.push(`原因：${context.outcome.reasonText}`);
  }
  if (context.outcome.outputs.length > 0) {
    lines.push(`产出：${context.outcome.outputs.join("、")}`);
  }
  lines.push(...renderAgentCharacterChangeLines(context.changes));
  if (context.outcome.outputs.length > 0 || context.outcome.storage !== "none") {
    lines.push(`产物去向：${workstationStorageLabel(context.outcome.storage)}`);
  }
  if (context.outcome.qualityModifier != null) {
    lines.push(`质量倍率：${formatCompactNumber(context.outcome.qualityModifier)}`);
  }
  if (context.outcome.brokenTools.length > 0) {
    lines.push(`工具损坏：${context.outcome.brokenTools.join("、")}`);
  }
  return lines.join("\n");
}

function renderWorkstationActionLine(context: AgentWorkstationContext): string {
  const action = context.action;
  const actionParts = [action.verbName, action.subOptionName].filter((part): part is string => Boolean(part));
  return actionParts.length > 0 ? `${action.workstationName} · ${actionParts.join("/")}` : action.workstationName;
}

function renderWorkstationProgressLine(progress: NonNullable<AgentWorkstationContext["progress"]>): string {
  if (progress.elapsedGameSeconds != null && (progress.remainingGameSeconds ?? 0) <= 0) {
    return formatGameDuration(progress.elapsedGameSeconds);
  }
  const parts = [
    progress.elapsedGameSeconds == null ? undefined : `已用 ${formatGameDuration(progress.elapsedGameSeconds)}`,
    progress.remainingGameSeconds == null ? undefined : `剩余 ${formatGameDuration(progress.remainingGameSeconds)}`,
    progress.durationGameSeconds == null ? undefined : `总时长 ${formatGameDuration(progress.durationGameSeconds)}`,
  ].filter((part): part is string => Boolean(part));
  return parts.length > 0 ? parts.join("，") : "进度未知";
}

function workstationStorageLabel(storage: WorkstationContextStorage): string {
  switch (storage) {
    case "backpack": return "背包/随身容器";
    case "treasury_vault": return "国库";
    case "none": return "无新增产物";
    case "unknown": return "以后续上下文为准";
  }
}

function localizeVerbName(verb: string): string {
  const key = `verb.${verb}.name`;
  const value = t(key, getActiveLocale());
  return value === key ? localizeWorkstationValue(verb) : value;
}

function localizeVerbSubOptionName(verb: string, subOption: string): string {
  const key = `verb.${verb}.sub_option.${subOption}`;
  const value = t(key, getActiveLocale());
  return value === key ? localizeWorkstationValue(subOption) : value;
}

function localizeWorkstationValue(value: string): string {
  return localizeText(localizeStringValue(value));
}

function numberRecord(value: unknown): Record<string, number> {
  const record = objectValue(value);
  if (!record) return {};
  const out: Record<string, number> = {};
  for (const [key, entry] of Object.entries(record)) {
    if (typeof entry === "number" && Number.isFinite(entry)) {
      out[localizeWorkstationValue(key)] = entry;
    }
  }
  return out;
}

function renderAgentToolError(error: string): string {
  return localizeText(error
    .replace(/^interrupted by event [^:]+:\s*/, "被打断：")
    .replace(/^interrupted:\s*/, "被打断："));
}

function formatGameDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const restSeconds = total % 60;
  if (hours > 0) return `${hours}小时${minutes}分钟`;
  if (minutes > 0) return `${minutes}分钟`;
  return `${restSeconds}秒`;
}

function formatCompactNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function formatContinuityValue(value: unknown): string {
  return trimText(formatValueForLog(value).replace(/\s+/g, " ").trim(), 400);
}

function formatValueForLog(value: unknown): string {
  if (typeof value === "string") return localizeText(value);
  if (value == null || typeof value !== "object") return String(value);
  try { return JSON.stringify(value); }
  catch { return String(value); }
}

function trimText(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars).trimEnd()}\n[已截断]`;
}

function formatContentText(value: unknown): string | undefined {
  if (typeof value === "string") return value.length > 0 ? value : undefined;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) {
    const parts = value.map(formatContentPartText).filter((part): part is string => Boolean(part));
    return parts.length > 0 ? parts.join("\n") : undefined;
  }
  const valueObject = objectValue(value);
  if (!valueObject) return undefined;
  return stringValue(valueObject.text) ?? stringValue(valueObject.content) ?? stringValue(valueObject.output) ?? formatValueForLog(valueObject);
}

function formatContentPartText(part: unknown): string | undefined {
  if (typeof part === "string") return part;
  const partObject = objectValue(part);
  if (!partObject) return undefined;
  const type = stringValue(partObject.type);
  if (type === "thinking" || type === "reasoning" || type === "toolCall" || type === "tool_use" || type === "tool_result" || type === "function_call" || type === "function_call_output") return undefined;
  return stringValue(partObject.text) ?? stringValue(partObject.content) ?? stringValue(partObject.output);
}

function booleanValue(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}
