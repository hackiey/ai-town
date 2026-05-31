// 计算"当前正在进行的活儿"行——给每 turn user message 用，让 LLM 别忘了自己手上有未完成的工具。
// 数据源：action_log 里 non-terminal 的 action（优先），没有就 fallback 到 ContinuedActionManager.activeIntentLine()。

import type { AgentRuntimeContext } from "../../../agent-host/runtime.js";
import type { ContinuedActionManager } from "../../../agent-shared/notices/queue.js";
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
  const progress = extractProgress(action.result);
  const progressSuffix = progress
    ? t("prompt.agent.two_track.tick.active_work_progress_format", locale, { progress })
    : "";
  return t("prompt.agent.two_track.tick.active_work_line_format", locale, {
    action: action.action,
    actionId: action.id,
    status: action.status,
    progressSuffix,
  });
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
