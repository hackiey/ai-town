// 计算"当前正在进行的活儿"行——给每 turn user message 用，让 LLM 别忘了自己手上有未完成的工具。
// 数据源：action_log 里 non-terminal 的 action（优先），没有就 fallback 到 ContinuedActionManager.activeIntentLine()。

import type { AgentRuntimeContext } from "../../../agent-host/runtime.js";
import type { ContinuedActionManager } from "../../../agent-shared/notices/queue.js";
import { localizeStringValue } from "../../../agent-shared/name-resolver/index.js";
import { arrayValue, objectValue, stringValue } from "../../../agent-shared/utils/primitives.js";
import type { ActionLogRecord } from "../../../godot-link/protocol.js";
import { getActiveLocale, t, type Locale } from "../../../i18n/index.js";

const TERMINAL_ACTION_STATUSES = new Set(["completed", "failed", "cancelled", "interrupted"]);
const DEFAULT_RECENT_ACTION_LIMIT = 8;

export type ComputeActiveWorkOptions = {
  ctx: AgentRuntimeContext;
  characterId: string;
  continuedActions: ContinuedActionManager;
  limit?: number;
};

export async function computeActiveWorkLines(options: ComputeActiveWorkOptions): Promise<string[]> {
  await options.continuedActions.restore();
  const locale = getActiveLocale();
  const limit = options.limit ?? DEFAULT_RECENT_ACTION_LIMIT;
  const actions = await options.ctx.actions().recentForCharacter(options.characterId, limit);
  const openActions = actions.filter((action) => !TERMINAL_ACTION_STATUSES.has(action.status));
  if (openActions.length > 0) {
    return openActions.map((action) => renderActiveWorkLine(action, locale));
  }
  const fallback = options.continuedActions.activeIntentLine();
  return fallback ? [`- ${fallback}`] : [];
}

function renderActiveWorkLine(action: ActionLogRecord, locale: Locale): string {
  const description = describeActiveWorkAction(action, locale);
  const progress = extractProgress(action.result);
  const progressSuffix = progress
    ? t("prompt.agent.two_track.tick.active_work_progress_format", locale, { progress })
    : "";
  const target = description.target ?? extractTargetLabel(action.target);
  const targetSuffix = target
    ? t("prompt.agent.two_track.tick.active_work_target_format", locale, { target })
    : "";
  return t("prompt.agent.two_track.tick.active_work_line_format", locale, {
    // actionId 不再暴露给 LLM；动作名用工具显示 label（找不到退回 slug），目的地另起 suffix。
    action: description.action,
    targetSuffix,
    status: statusLabel(action.status, locale),
    progressSuffix,
  });
}

type ActiveWorkDescription = {
  action: string;
  target?: string;
};

function describeActiveWorkAction(action: ActionLogRecord, locale: Locale): ActiveWorkDescription {
  if (action.action === "take" || action.action === "put") {
    return describeContainerTransferAction(action, locale) ?? { action: actionLabel(action.action, locale) };
  }
  if (action.action === "plan_farm_work") {
    return describeFarmWorkAction(action, locale);
  }
  return { action: actionLabel(action.action, locale) };
}

function describeContainerTransferAction(action: ActionLogRecord, locale: Locale): ActiveWorkDescription | undefined {
  const target = objectValue(action.target);
  const transfers = recordArray(target?.transfers);
  if (transfers.length === 0) return undefined;

  const endpoint = transferEndpointLabel(transfers[0], action.action === "take" ? "from" : "to", locale);
  if (action.action === "take" && transfers.some(isDrawWaterTransfer)) {
    const target = endpoint ?? localizeStringValue("well");
    return {
      action: t("prompt.agent.two_track.tick.active_work_draw_water_action_format", locale, { target }),
    };
  }

  const content = singleTransferContentLabel(action, transfers);
  const baseAction = action.action === "put" && transfers.some((transfer) => transfer.kind === "liquid")
    ? t("prompt.agent.two_track.tick.active_work_pour_liquid_action", locale)
    : actionLabel(action.action, locale);
  return {
    action: content
      ? t("prompt.agent.two_track.tick.active_work_item_action_format", locale, { action: baseAction, item: content })
      : baseAction,
    target: endpoint,
  };
}

function describeFarmWorkAction(action: ActionLogRecord, locale: Locale): ActiveWorkDescription {
  const kind = farmActiveKind(action) ?? singleFarmTargetKind(action);
  return {
    action: kind ? farmActionLabel(kind, locale) : actionLabel(action.action, locale),
    target: extractTargetLabel(action.target),
  };
}

// 工具显示名：tools.json 的 tool.<slug>.label；缺失则退回原始 slug。
function actionLabel(action: string, locale: Locale): string {
  const key = `tool.${action}.label`;
  const label = t(key, locale);
  return label === key ? action : label;
}

function statusLabel(status: string, locale: Locale): string {
  const key = `prompt.context.status.${status}`;
  const label = t(key, locale);
  return label === key ? status : label;
}

// 从 action_log.target 里抽出可读的目的地/对象名并本地化。
// move_to_location 是 {locationId}；其它长跑工具的 target 形态各异，覆盖常见键即可，
// 命中不到就返回空（优雅降级，不渲染 suffix）。复用 move.ts:resolveTargetLabel 同款思路。
const TARGET_LABEL_KEYS = [
  "locationId",
  "characterId",
  "itemId",
  "regionId",
  "farmId",
  "farm_id",
  "farm",
  "workstation_id",
  "workstationId",
  "workstation",
  "container",
];

function extractTargetLabel(target: Record<string, unknown> | string | undefined): string | undefined {
  if (target == null) return undefined;
  if (typeof target === "string") {
    const trimmed = target.trim();
    return trimmed ? localizeStringValue(trimmed) : undefined;
  }
  for (const key of TARGET_LABEL_KEYS) {
    const value = target[key];
    if (typeof value === "string" && value.length > 0) {
      return localizeStringValue(value);
    }
  }
  return undefined;
}

function extractProgress(result: Record<string, unknown> | undefined): string | undefined {
  if (!result) return undefined;
  const progress = result.progress;
  if (progress == null) return undefined;
  if (typeof progress === "string") return progress.trim() || undefined;
  if (typeof progress === "number") return String(progress);
  try {
    return JSON.stringify(progress);
  } catch {
    return undefined;
  }
}

function recordArray(value: unknown): Record<string, unknown>[] {
  return arrayValue(value).filter((entry): entry is Record<string, unknown> => Boolean(objectValue(entry)));
}

function isDrawWaterTransfer(transfer: Record<string, unknown>): boolean {
  if (transfer.kind !== "liquid") return false;
  const from = objectValue(transfer.from);
  return from?.where === "well";
}

function transferEndpointLabel(
  transfer: Record<string, unknown>,
  key: "from" | "to",
  locale: Locale,
): string | undefined {
  const endpoint = objectValue(transfer[key]);
  if (!endpoint) return undefined;
  if (endpoint.where === "well") return localizeStringValue("well");
  if (endpoint.where === "ground") return t("tool.take.ground_target", locale);
  const containerId = stringValue(endpoint.containerId);
  return containerId ? localizeStringValue(containerId) : undefined;
}

function singleTransferContentLabel(action: ActionLogRecord, transfers: Record<string, unknown>[]): string | undefined {
  const ids = new Set<string>();
  for (const transfer of transfers) {
    const itemId = stringValue(transfer.itemId);
    if (itemId) ids.add(itemId);
  }
  for (const move of recordArray(action.result?.moves)) {
    const content = stringValue(move.content) ?? stringValue(move.itemId);
    if (content) ids.add(content);
  }
  return ids.size === 1 ? localizeStringValue([...ids][0]) : undefined;
}

function farmActiveKind(action: ActionLogRecord): string | undefined {
  const result = action.result ?? {};
  return stringValue(result.active_kind) ?? stringValue(result.activeKind);
}

function singleFarmTargetKind(action: ActionLogRecord): string | undefined {
  const target = objectValue(action.target);
  const kinds = new Set<string>();
  for (const op of [...recordArray(action.result?.remaining), ...recordArray(target?.ops)]) {
    const kind = stringValue(op.kind);
    if (kind) kinds.add(kind);
  }
  return kinds.size === 1 ? [...kinds][0] : undefined;
}

function farmActionLabel(kind: string, locale: Locale): string {
  const key = `tool.action.farm.action.${kind}`;
  const label = t(key, locale);
  return label === key ? kind : label;
}
