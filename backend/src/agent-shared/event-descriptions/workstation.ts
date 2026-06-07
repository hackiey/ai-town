// Workstation event renderer (共享给 10 个 axis event)。
// Data shape: WorkstationEventData (workstationId, verb, outcome, outputs,
// leftoverOutputs, failModeName, proficiency*)。Godot 端按 (workstation, verb)
// 把事件名映射成 axis slug 发回（见 src/sim/workstations/workstation_action_runner.gd
// _AXIS_BY_WORKSTATION_VERB），后端 dispatch 都路由到本文件的 renderUseWorkstationEventLine。

import { t, type Locale } from "../../i18n/index.js";
import type { WorldEventRecord } from "../../godot-link/protocol.js";
import type { UseWorkstationEventData } from "../../godot-link/world-events.js";
import { localizeStringValue, localizeText } from "../name-resolver/index.js";
import { isSelfActor, renderActorLabel } from "./shared/actor-label.js";
import { composeEventLine } from "./shared/compose.js";

export function renderUseWorkstationEventLine(
  event: WorldEventRecord,
  viewerId: string,
  locale: Locale,
): string {
  const data = (event.data ?? {}) as Partial<UseWorkstationEventData>;
  const self = isSelfActor(event.actorId, viewerId);
  const workstation = data.workstationId
    ? (localizeStringValue(data.workstationId) ?? data.workstationId)
    : "";
  const actor = renderActorLabel(event.actorId, viewerId, locale);

  const outcome = data.outcome;
  let main = outcome === "failure"
    ? renderFailure(self, actor, workstation, data, locale)
    : renderSuccessOrIdle(self, actor, workstation, data, locale);
  // 失败尾巴只对 actor 渲染 "（难度 X / 熟练度 Y）"。
  // 旁人看不到 —— 这是 actor 心里的盘算。料子折损情况不写进 event，actor 自己看
  // tool_response 的 character_changes.backpack 就知道（renderAgentBackpackChange）。
  if (outcome === "failure" && self) {
    main += renderFailureSkillAssessment(data, locale);
  }
  // 熟练度反馈只对 actor 本人渲染 —— 这是内部成长信号，旁人看不到也无从知晓。
  const profSuffix = self ? renderProficiencySuffix(data, locale) : "";

  return composeEventLine(event, viewerId, locale, main + profSuffix);
}

function renderFailureSkillAssessment(data: Partial<UseWorkstationEventData>, locale: Locale): string {
  const diff = Number(data.difficulty);
  const before = Number(data.proficiencyBefore);
  if (!Number.isFinite(diff) || !Number.isFinite(before)) return "";
  return t("prompt.context.event.workstation.failure_skill_assessment_format", locale, {
    difficulty: String(Math.round(diff)),
    proficiency: String(Math.round(before)),
  });
}

// 突破：delta >= 1.0；普通长进：>= 0.5；退步：delta < 0；其他静默。
// 数值四舍五入到整数展示（公式精度是 float，prompt 不必看小数）。
function renderProficiencySuffix(data: Partial<UseWorkstationEventData>, locale: Locale): string {
  const delta = Number(data.proficiencyDelta ?? 0);
  if (!Number.isFinite(delta) || Math.abs(delta) < 0.5) return "";
  const skillId = data.proficiencySkillId ?? "";
  if (!skillId) return "";
  const skillLabel = t(`prompt.context.proficiency.skill.${skillId}`, locale);
  const before = Math.round(Number(data.proficiencyBefore ?? 0));
  const after = Math.round(Number(data.proficiencyAfter ?? 0));
  let key: string;
  if (delta < 0) {
    key = "prompt.context.event.workstation.proficiency_loss_format";
  } else if (delta >= 1.0) {
    key = "prompt.context.event.workstation.proficiency_breakthrough_format";
  } else {
    key = "prompt.context.event.workstation.proficiency_gain_format";
  }
  return t(key, locale, { skill: skillLabel, before: String(before), after: String(after) });
}

function renderSuccessOrIdle(
  self: boolean,
  actor: string,
  workstation: string,
  data: Partial<UseWorkstationEventData>,
  locale: Locale,
): string {
  const outputs = formatOutputList(data.outputs, locale);
  if (!outputs) {
    return self
      ? t("prompt.context.event.workstation.self_idle_format", locale, { workstation })
      : t("prompt.context.event.workstation.other_idle_format", locale, { actor, workstation });
  }
  const leftoverSuffix = formatLeftoverSuffix(data.leftoverOutputs, locale);
  const base = self
    ? t("prompt.context.event.workstation.self_success_format", locale, { workstation, outputs })
    : t("prompt.context.event.workstation.other_success_format", locale, { actor, workstation, outputs });
  return base + leftoverSuffix;
}

function renderFailure(
  self: boolean,
  actor: string,
  workstation: string,
  data: Partial<UseWorkstationEventData>,
  locale: Locale,
): string {
  const reason = data.failModeName
    ? (localizeStringValue(data.failModeName) ?? data.failModeName)
    : t("prompt.context.event.workstation.failure_reason_unknown", locale);
  return self
    ? t("prompt.context.event.workstation.self_failure_format", locale, { workstation, reason })
    : t("prompt.context.event.workstation.other_failure_format", locale, { actor, workstation, reason });
}

function formatOutputList(outputs: unknown, locale: Locale): string {
  if (!Array.isArray(outputs) || outputs.length === 0) return "";
  const parts: string[] = [];
  for (const entry of outputs) {
    const formatted = formatOutputEntry(entry, locale);
    if (formatted) parts.push(formatted);
  }
  return parts.join(t("prompt.context.event.attribute_changes.separator", locale));
}

function formatLeftoverSuffix(leftover: unknown, locale: Locale): string {
  const formatted = formatOutputList(leftover, locale);
  if (!formatted) return "";
  return t("prompt.context.event.workstation.leftover_suffix_format", locale, { leftover: formatted });
}

// Outputs from Godot ship as either:
//   ["item_name x3", ...]                       (Godot legacy free-form string)
//   [{item: "wheat_flour", count: 1}, ...]      (preferred structured form)
// Be liberal in what we accept.
function formatOutputEntry(entry: unknown, locale: Locale): string | undefined {
  if (typeof entry === "string") {
    return localizeText(entry);
  }
  if (!entry || typeof entry !== "object") return undefined;
  const row = entry as Record<string, unknown>;
  const itemId = typeof row.item === "string" ? row.item
    : typeof row.itemId === "string" ? row.itemId
    : typeof row.item_id === "string" ? row.item_id
    : "";
  const count = Number(row.count ?? row.quantity ?? row.qty);
  if (!itemId || !Number.isFinite(count) || count <= 0) return undefined;
  const itemLabel = localizeStringValue(itemId) ?? itemId;
  return t("prompt.context.event.workstation.output_format", locale, {
    item: itemLabel,
    count,
  });
}
