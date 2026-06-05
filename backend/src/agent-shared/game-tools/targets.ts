import { getActiveLocale, t } from "../../i18n/index.js";
import {
  characterName,
  localizeStringValue,
  locationName,
  resolveCharacterIdByName,
  resolveContainerIdByName,
  resolveItemIdByName,
  resolveLocationIdByName,
  resolveMaterialIdByName,
  resolveNavigableSiteIdByName,
  resolveWorkstationIdByName,
} from "../name-resolver/index.js";
import { renderInteractiveSiteName } from "../entity-descriptions/site-naming.js";
import type { AgentCurrentContext, InteractiveSiteContext, ItemIndexEntry } from "../prompt-context/types.js";
import { craftSkipsInputs, getCraftSpec, type CraftSlug } from "./craft-registry.js";
import { moveToCharacterPrefix, moveToItemPrefix, td } from "./i18n.js";
import type { ItemRefParam, PlanFarmWorkOpParams } from "./schemas.js";
import type { MoveTargetError, MoveTargetResolution } from "./types.js";
import type { PlanFarmWorkOp } from "../../godot-link/actions.js";

// 名字 → character slug。先看 near + far，再回退全表 slug 解析（对方可能已离场）。
// 是否在附近、能不能交易/听到由 Godot 决定。trade / speech 共用，只差缺参错误 key。
function resolveCharacterTarget(
  character: string,
  currentContext: AgentCurrentContext | undefined,
  missingErrorKey: string,
): { id: string; label: string } | MoveTargetError {
  if (!character?.trim()) {
    return { error: t(missingErrorKey, getActiveLocale()) };
  }
  const id = resolveCharacterTargetId(character, currentContext);
  if (!id) {
    return { error: t("error.unknown_character", getActiveLocale(), { character: character.trim() }) };
  }
  return { id, label: characterName(id) };
}

export function resolveTradeTarget(
  character: string,
  currentContext?: AgentCurrentContext,
): { id: string; label: string } | MoveTargetError {
  return resolveCharacterTarget(character, currentContext, "error.offer_missing_character");
}

export function resolveSpeechTarget(
  character: string,
  currentContext?: AgentCurrentContext,
): { id: string; label: string } | MoveTargetError {
  return resolveCharacterTarget(character, currentContext, "error.say_to_missing_character");
}

// ── 交互 site 解析：单一入口 ──────────────────────────────────────────────
// workstation / container / farm / shelf 全走这里。匹配的 alias 用 renderInteractiveSiteName
// 产出 —— 与 sections.ts 渲染给 LLM 看的字符串**同源**，所以 LLM 原样 copy 回来必能反查到。
// 各 tool 的 resolver 只是套一层 filter（按 kind / craft 允许集）+ 决定返回哪个 id。
// 不做"在不在附近"校验 —— 那是 Godot 的权威（[[feedback_godot_is_authority]]）。
export type SiteMatch = { site: InteractiveSiteContext; label: string };

export function resolveInteractiveSite(
  requested: string | undefined,
  currentContext: AgentCurrentContext | undefined,
  opts: {
    filter: (site: InteractiveSiteContext) => boolean;
    // requested 为空时：候选恰好一个就直接选它（单工作台 craft / 唯一货架等）。
    autoPickWhenEmpty?: boolean;
    // 默认取 ctx.interactiveSites（= prompt 渲染的同一份）；货架 owned scope 传显式列表。
    sites?: InteractiveSiteContext[];
  },
): SiteMatch | undefined {
  const candidates = (opts.sites ?? currentContext?.interactiveSites ?? []).filter(opts.filter);
  const trimmed = requested?.trim() ?? "";
  if (!trimmed) {
    if (opts.autoPickWhenEmpty && candidates.length === 1) {
      return { site: candidates[0], label: renderInteractiveSiteName(candidates[0]) };
    }
    return undefined;
  }
  const normalized = normalizeLocationInput(trimmed);
  for (const site of candidates) {
    const name = renderInteractiveSiteName(site);
    const aliases = [
      name,
      site.displayName,
      site.id,
      site.workstationId ?? "",
      site.locationId ?? "",
      // 旧 resolver 接受的两种合成形式，保留向后兼容（LLM 偶尔把 id 也括在后面）。
      site.kind === "shelf" ? `${name} (${site.id})` : "",
      site.kind === "workstation" && site.workstationId ? `${name} (${site.workstationId})` : "",
    ];
    if (aliases.some((alias) => alias && normalizeLocationInput(alias) === normalized)) {
      return { site, label: name };
    }
  }
  return undefined;
}

export function resolveMoveTarget(requestedLocation: string, currentContext?: AgentCurrentContext): MoveTargetResolution | MoveTargetError {
  const trimmed = requestedLocation.trim();
  const normalizedRequest = normalizeLocationInput(trimmed);
  const currentLocationLabel = td("common.current_location_value");
  if (["current_location", "current location", currentLocationLabel].map(normalizeLocationInput).includes(normalizedRequest)) {
    return { target: { locationId: currentLocationLabel }, label: currentLocationLabel };
  }

  // 前缀 disambiguate（schema 鼓励 LLM 用这两个前缀；没用前缀时按 location 走）
  const charPrefix = moveToCharacterPrefix();
  if (trimmed.startsWith(charPrefix)) {
    const raw = trimmed.slice(charPrefix.length).trim();
    const id = resolveCharacterTargetId(raw, currentContext);
    if (!id) {
      return { error: t("error.unknown_character", getActiveLocale(), { character: raw }) };
    }
    return {
      target: { characterId: id },
      label: `${charPrefix}${characterName(id)}`,
    };
  }
  const itemPrefix = moveToItemPrefix();
  if (trimmed.startsWith(itemPrefix)) {
    const raw = trimmed.slice(itemPrefix.length).trim();
    const item = resolveItemTarget(raw, currentContext);
    if (isMoveTargetError(item)) {
      return item;
    }
    return {
      target: { itemId: item.id },
      label: `${itemPrefix}${item.label}`,
    };
  }

  const siteId = resolveNavigableSiteIdByName(trimmed);
  if (siteId) {
    return { target: { locationId: siteId }, label: localizeStringValue(siteId) };
  }
  return { target: { locationId: trimmed }, label: locationName(trimmed) };
}

export function isMoveTargetError(value: unknown): value is MoveTargetError {
  return Boolean(value && typeof value === "object" && "error" in value);
}

// 名字 → farm slug。是否在附近、农事是否合法由 Godot 决定。
export function resolvePlanFarm(
  requestedFarm: string | undefined,
  currentContext?: AgentCurrentContext,
): { id: string; label: string } | MoveTargetError {
  if (!requestedFarm?.trim()) {
    return { error: t("error.plan_farm_work_missing_farm", getActiveLocale()) };
  }
  const trimmed = requestedFarm.trim();
  const match = resolveInteractiveSite(trimmed, currentContext, { filter: (s) => s.kind === "farm" });
  if (match) {
    return { id: match.site.id, label: match.label };
  }
  // 不在附近也尝试名字 → location id 反查（让 Godot 后续判定）。
  const locationId = resolveLocationIdByName(trimmed);
  if (!locationId) {
    return { error: t("error.unknown_farm", getActiveLocale(), { farm: trimmed }) };
  }
  return { id: locationId, label: locationName(locationId) };
}

// 名字 → canonical workstation id。显示名在 backend 映射层消化，发给 Godot 的 payload
// 只使用 workstation id。不做"是否在附近"校验 —— 那是 Godot server 的权威。
export function resolveUseWorkstationName(requested: string | undefined, currentContext?: AgentCurrentContext): { id: string; label: string } | MoveTargetError {
  if (!requested?.trim()) {
    return { error: t("error.use_workstation_missing_workstation", getActiveLocale()) };
  }
  const trimmed = requested.trim();
  const match = resolveInteractiveSite(trimmed, currentContext, {
    filter: (s) => s.kind === "workstation" && !!s.workstationId,
  });
  if (match?.site.workstationId) {
    return { id: match.site.workstationId, label: match.label };
  }
  const workstationId = resolveWorkstationIdByName(trimmed);
  if (!workstationId) {
    return { error: t("error.use_workstation_unknown_workstation", getActiveLocale(), { workstation: trimmed }) };
  }
  return { id: workstationId, label: localizeStringValue(workstationId) };
}

export function resolveContainerTarget(requested: string | undefined): { id: string; label: string } | MoveTargetError {
  if (!requested?.trim()) {
    return { error: t("error.unknown_container", getActiveLocale(), { container: "" }) };
  }
  const trimmed = requested.trim();
  const containerId = resolveContainerIdByName(trimmed);
  if (!containerId) {
    return { error: t("error.unknown_container", getActiveLocale(), { container: trimmed }) };
  }
  return { id: containerId, label: localizeStringValue(containerId) };
}

export function resolveItemTarget(requested: string | undefined, currentContext?: AgentCurrentContext): { id: string; label: string } | MoveTargetError {
  if (!requested?.trim()) {
    return { error: t("error.unknown_item", getActiveLocale(), { item: "" }) };
  }
  const trimmed = requested.trim();
  const itemId = resolveItemIdFromKnownNames(trimmed, currentContext);
  if (!itemId) {
    return { error: t("error.unknown_item", getActiveLocale(), { item: trimmed }) };
  }
  return { id: itemId, label: localizeStringValue(itemId) };
}

// LLM 提供 {name, index} 引用某个物品清单（背包 / 装备 / 附近 / 容器 / 货架）里的具体一份堆叠。
// 反查 assemble 时冻结进 ctx.itemIndex 的 1-based snapshot，校验 name 与该行实际
// 显示名一致后返回 (itemDefId, slotIndex/listingId) —— 真 primary key 透传给 Godot 不留歧义。
// 不做"是否还在那里"的运行时校验——那是 Godot 的权威（[[feedback_godot_is_authority]]）。
export type ItemRefList = "backpack" | "equipment" | "nearby";
export type ScopedItemRefList = { kind: "container"; containerId: string } | { kind: "shelf"; shelfId: string };

export type ResolvedItemRef = {
  id: string;
  label: string;
  slotIndex?: number;
  listingId?: string;
};

export function resolveItemByIndex(
  ref: ItemRefParam | undefined,
  list: ItemRefList | ScopedItemRefList,
  currentContext?: AgentCurrentContext,
): ResolvedItemRef | MoveTargetError {
  if (!ref || !ref.name?.trim() || !Number.isInteger(ref.index) || ref.index < 1) {
    return { error: t("error.unknown_item", getActiveLocale(), { item: ref?.name?.trim() ?? "" }) };
  }
  const requestedName = ref.name.trim();
  const entries = pickEntries(list, currentContext);
  const listLabel = itemRefListLabel(list);
  if (ref.index > entries.length) {
    return {
      error: t("error.item_index_out_of_range", getActiveLocale(), {
        list: listLabel,
        index: ref.index,
        size: entries.length,
      }),
    };
  }
  const entry = entries[ref.index - 1];
  if (!entry) {
    return {
      error: t("error.item_index_out_of_range", getActiveLocale(), {
        list: listLabel,
        index: ref.index,
        size: entries.length,
      }),
    };
  }
  const actualName = localizeStringValue(entry.itemDefId);
  if (normalizeItemInput(actualName) !== normalizeItemInput(requestedName)) {
    // liquid_container 兜底：LLM 写 {name:"水", index:<木桶>} 时 entry 是 wood_bucket，
    // 名字对不上但 entry.containerContent 是 "water"。若请求名 ≈ 容器装的内容，就把请求
    // 解析成 {id: 内容, slotIndex: 桶}，转给 Godot 端做最终校验（量够、桶在背包）。
    if (entry.containerContent) {
      const contentName = localizeStringValue(entry.containerContent);
      if (normalizeItemInput(contentName) === normalizeItemInput(requestedName)) {
        const resolved: ResolvedItemRef = { id: entry.containerContent, label: contentName };
        if (entry.slotIndex != null) resolved.slotIndex = entry.slotIndex;
        return resolved;
      }
    }
    return {
      error: t("error.item_index_name_mismatch", getActiveLocale(), {
        list: listLabel,
        index: ref.index,
        actualName,
        requestedName,
      }),
    };
  }
  const resolved: ResolvedItemRef = { id: entry.itemDefId, label: actualName };
  if (entry.slotIndex != null) resolved.slotIndex = entry.slotIndex;
  if (entry.listingId != null) resolved.listingId = entry.listingId;
  return resolved;
}

function pickEntries(list: ItemRefList | ScopedItemRefList, ctx?: AgentCurrentContext) {
  const idx = ctx?.itemIndex;
  if (!idx) return [];
  if (typeof list === "string") return idx[list] ?? [];
  if (list.kind === "container") return idx.containers[list.containerId] ?? [];
  return idx.shelves[list.shelfId] ?? [];
}

function itemRefListLabel(list: ItemRefList | ScopedItemRefList): string {
  if (typeof list === "string") {
    switch (list) {
      case "backpack": return "# 背包";
      case "equipment": return "# 当前装备";
      case "nearby": return "# 附近物品";
    }
  }
  return list.kind === "container"
    ? `${localizeStringValue(list.containerId)} 容器内容`
    : `${localizeStringValue(list.shelfId)} 货架内容`;
}


export function resolveWorkstationInputTarget(requested: string, currentContext?: AgentCurrentContext): { id: string; label: string } | MoveTargetError {
  const trimmed = requested.trim();
  const itemId = resolveItemIdFromKnownNames(trimmed, currentContext);
  if (itemId) {
    return { id: itemId, label: localizeStringValue(itemId) };
  }
  const materialId = resolveMaterialIdByName(trimmed);
  if (materialId) {
    return { id: materialId, label: localizeStringValue(materialId) };
  }
  return { error: t("error.unknown_item", getActiveLocale(), { item: trimmed }) };
}

export function resolveOptionalKnownTargetName(target: string | undefined, currentContext?: AgentCurrentContext, selfCharacterId?: string): string | undefined | MoveTargetError {
  const trimmed = target?.trim();
  if (!trimmed) {
    return undefined;
  }
  const selfTarget = resolveSelfTargetName(trimmed, selfCharacterId);
  if (selfTarget) {
    return selfTarget;
  }
  const resolved = canonicalizeKnownTargetName(trimmed, currentContext);
  if (resolved !== trimmed) {
    return resolved;
  }
  return { error: t("error.unknown_target", getActiveLocale(), { target: trimmed }) };
}

function resolveSelfTargetName(target: string, selfCharacterId?: string): string | undefined {
  const id = selfCharacterId?.trim();
  if (!id) {
    return undefined;
  }
  const normalized = normalizeNameInput(target);
  return ["自己", "自身", "我", "我自己", "self", "me"].includes(normalized) ? id : undefined;
}

export function canonicalizeKnownTargetName(target: string | undefined, currentContext?: AgentCurrentContext): string | undefined {
  const trimmed = target?.trim();
  if (!trimmed) {
    return undefined;
  }
  const characterId = resolveCharacterTargetId(trimmed, currentContext);
  if (characterId) {
    return characterId;
  }
  const siteId = resolveNavigableSiteIdByName(trimmed);
  if (siteId) {
    return siteId;
  }
  const itemId = resolveItemIdFromKnownNames(trimmed, currentContext);
  return itemId ?? trimmed;
}

// put_take / view_container 的统一目标解析：货架（kind=shelf）与容器（kind=workstation +
// interactionMode=container）都能命中。返回 kind 让 caller 决定 take 物品的 scope。
export function resolveContainerOrShelfTarget(
  requested: string | undefined,
  currentContext?: AgentCurrentContext,
): { id: string; label: string; kind: "container" | "shelf" } | MoveTargetError {
  if (!requested?.trim()) {
    return { error: t("error.unknown_container", getActiveLocale(), { container: "" }) };
  }
  const match = resolveInteractiveSite(requested, currentContext, {
    filter: (s) => s.kind === "shelf" || (s.kind === "workstation" && s.interactionMode === "container"),
  });
  if (match) {
    return {
      id: match.site.id,
      label: match.label,
      kind: match.site.kind === "shelf" ? "shelf" : "container",
    };
  }
  // 不在感知内也尝试名字 → container id 反查（让 Godot 后续判定 not_nearby）。
  const containerId = resolveContainerIdByName(requested.trim());
  if (containerId) {
    return { id: containerId, label: localizeStringValue(containerId), kind: "container" };
  }
  return { error: t("error.unknown_container", getActiveLocale(), { container: requested.trim() }) };
}


// axis tool 工厂用：根据 axis 限定可选 workstation 集合，把 LLM 输入翻译成 workstationId。
// 不做"在不在附近"校验——那是 Godot _find_workstation 的活（[[feedback_godot_is_authority]]）。
// craft 工作台只有一个时（cook/smith/mill_grain 等），requested 可以为 undefined，直接返回固定 id。
export function resolveCraftWorkstation(
  craft: CraftSlug,
  requested: string | undefined,
  currentContext?: AgentCurrentContext,
): { id: string; label: string } | MoveTargetError {
  const workstations = getCraftSpec(craft).workstations;
  // craft 工作台只有一个时（cook/smith/mill_grain 等），不在附近也返回固定 id。
  if (!requested?.trim() && workstations.length === 1) {
    const id = workstations[0];
    return { id, label: localizeStringValue(id) };
  }
  // 附近候选用共享解析（按 craft 允许集过滤）；requested 空且恰一个候选时自动选。
  const match = resolveInteractiveSite(requested, currentContext, {
    filter: (s) => s.kind === "workstation" && !!s.workstationId && workstations.includes(s.workstationId),
    autoPickWhenEmpty: true,
  });
  if (match?.site.workstationId) {
    return { id: match.site.workstationId, label: match.label };
  }
  if (!requested?.trim()) {
    return { error: t("error.use_workstation_missing_workstation", getActiveLocale()) };
  }
  const trimmed = requested.trim();
  // 没在附近也尝试名字 → id 反查（让 Godot 后续判定 not_nearby）。
  const id = resolveWorkstationIdByName(trimmed);
  if (id && workstations.includes(id)) {
    return { id, label: localizeStringValue(id) };
  }
  return { error: t("error.use_workstation_unknown_workstation", getActiveLocale(), { workstation: trimmed }) };
}

// 12 个 axis tool 的 inputs 解析归一：把 LLM 给的 {name, index}[] 反查成 (itemId, slotIndex)[]。
// 矿场（mine）特殊：不需要 inputs（mining 工具会从背包自动取 pick）。
export function normalizeWorkstationActionInputs(
  axis: CraftSlug,
  inputs: ItemRefParam[] | undefined,
  currentContext: AgentCurrentContext | undefined,
): { inputItemIds: string[]; inputItemSlotIndices: (number | undefined)[] } {
  if (craftSkipsInputs(axis)) {
    return { inputItemIds: [], inputItemSlotIndices: [] };
  }
  const resolved = (inputs ?? []).map((input) => {
    const r = resolveItemByIndex(input, "backpack", currentContext);
    if (isMoveTargetError(r)) throw new Error(r.error);
    return r;
  });
  return {
    inputItemIds: resolved.map((r) => r.id),
    inputItemSlotIndices: resolved.map((r) => r.slotIndex),
  };
}


export function normalizePlanFarmWorkOps(ops: PlanFarmWorkOpParams[], currentContext?: AgentCurrentContext): PlanFarmWorkOp[] {
  return ops.map((op) => {
    const seedTarget = op.seed ? resolveItemByIndex(op.seed, "backpack", currentContext) : undefined;
    if (seedTarget && isMoveTargetError(seedTarget)) {
      throw new Error(seedTarget.error);
    }
    return {
      kind: op.kind,
      ...(op.slot_index == null ? {} : { slotIndex: op.slot_index }),
      ...(seedTarget ? { seedItemId: seedTarget.id } : {}),
      ...(seedTarget?.slotIndex != null ? { seedSlotIndex: seedTarget.slotIndex } : {}),
    };
  });
}

function resolveCharacterTargetId(character: string, currentContext?: AgentCurrentContext): string | undefined {
  const direct = resolveCharacterIdByName(character);
  if (direct) {
    return direct;
  }
  const requested = normalizeNameInput(character);
  for (const entry of [...(currentContext?.nearbyCharacters.near ?? []), ...(currentContext?.nearbyCharacters.far ?? [])]) {
    const aliases = [entry.id, characterName(entry.id)];
    if (aliases.some((alias) => normalizeNameInput(alias) === requested)) {
      return entry.id;
    }
  }
  return undefined;
}

// 用于 move_to_location 的 prefix 路径 / use_item.target / canonicalize 等"按字符串
// 找一个 item id"的兜底（不带 index 的单一 name 解析）。具体堆叠请走 resolveItemByIndex —
// 此函数只回 itemDefId，不区分品质等 aspect。
function resolveItemIdFromKnownNames(item: string, currentContext?: AgentCurrentContext): string | undefined {
  const direct = resolveItemIdByName(item);
  if (direct) {
    return direct;
  }
  const requested = normalizeItemInput(item);
  // 兜底：扫 itemIndex 的 typed 记录（每条都有 itemDefId 真值），按显示名匹配。
  // 同名多份时只返回第一份的 itemDefId —— 调用者不靠 index 区分 quality，可接受。
  const allEntries: ItemIndexEntry[] = [
    ...(currentContext?.itemIndex?.nearby ?? []),
    ...(currentContext?.itemIndex?.backpack ?? []),
    ...(currentContext?.itemIndex?.equipment ?? []),
  ];
  for (const entry of allEntries) {
    const display = localizeStringValue(entry.itemDefId);
    if (normalizeItemInput(display) === requested) {
      return entry.itemDefId;
    }
  }
  return undefined;
}

function normalizeItemInput(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function normalizeNameInput(value: string): string {
  return value.trim().toLowerCase().replace(/\s*[（(][^()（）]+[)）]\s*$/u, "");
}

export function normalizeLocationInput(value: string): string {
  return value.trim().toLowerCase().replaceAll("-", "_").replaceAll(" ", "_");
}
