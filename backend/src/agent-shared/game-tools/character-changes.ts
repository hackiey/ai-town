// 解析 / 渲染 tool result 里 character_changes 段（属性变动 + 背包变动）。
// 给 notice render 和 use_workstation result 都用。

import { characterAttributeName, localizeText } from "../name-resolver/index.js";
import { arrayValue, objectValue } from "../utils/primitives.js";

export type AgentCharacterChanges = {
  attributes: Record<string, unknown>[];
  backpack: Record<string, unknown>[];
};

export function renderActionResultCharacterChangeLines(result: Record<string, unknown> | undefined): string[] {
  return renderAgentCharacterChangeLines(result?.character_changes ?? result?.characterChanges);
}

export function parseAgentCharacterChanges(value: unknown): AgentCharacterChanges {
  const changes = objectValue(value) ?? {};
  return {
    attributes: arrayValue(changes.attributes).filter(isRecordValue),
    backpack: arrayValue(changes.backpack).filter(isRecordValue),
  };
}

export function renderAgentCharacterChangeLines(value: unknown): string[] {
  const changes = parseAgentCharacterChanges(value);
  const lines: string[] = [];
  const attributes = changes.attributes
    .map(renderAgentAttributeChange)
    .filter((line): line is string => Boolean(line));
  if (attributes.length > 0) {
    lines.push(`属性变动：${attributes.join("；")}`);
  }
  const backpack = changes.backpack
    .map(renderAgentBackpackChange)
    .filter((line): line is string => Boolean(line));
  if (backpack.length > 0) {
    lines.push(`背包变动：${backpack.join("；")}`);
  }
  return lines;
}

function renderAgentAttributeChange(change: Record<string, unknown>): string | undefined {
  const field = stringField(change, ["attribute_id", "attributeId", "field", "stat", "name"]);
  const label = field ? characterAttributeName(field) : stringField(change, ["label"]);
  if (!label) return undefined;
  return `${label} ${formatChangeValue(change.before)} -> ${formatChangeValue(change.after)}`;
}

function renderAgentBackpackChange(change: Record<string, unknown>): string | undefined {
  const kind = stringField(change, ["kind"]);
  const name = localizeText(stringField(change, ["display_name", "displayName", "item_id", "itemId"]) ?? "物品");
  if (kind === "quantity") {
    const delta = numberField(change, ["delta"]) ?? 0;
    if (delta > 0) return `获得 ${name} x${formatCompactNumber(delta)}`;
    if (delta < 0) return `失去 ${name} x${formatCompactNumber(Math.abs(delta))}`;
    return undefined;
  }
  if (kind === "durability") {
    const max = numberField(change, ["max"]);
    const suffix = max == null || max <= 0 ? "" : `/${formatCompactNumber(max)}`;
    return `${name}耐久 ${formatChangeValue(change.before)} -> ${formatChangeValue(change.after)}${suffix}`;
  }
  if (kind === "container") {
    return `${name}：${formatChangeValue(change.before)} -> ${formatChangeValue(change.after)}`;
  }
  return undefined;
}

function formatChangeValue(value: unknown): string {
  if (typeof value === "number") return formatCompactNumber(value);
  if (typeof value === "boolean") return value ? "是" : "否";
  if (typeof value === "string") return localizeText(value);
  return String(value ?? "未知");
}

function formatCompactNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function stringField(record: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

function numberField(record: Record<string, unknown>, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value)) return value;
  }
  return undefined;
}

function isRecordValue(value: unknown): value is Record<string, unknown> {
  return Boolean(objectValue(value));
}
