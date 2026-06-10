import type { AppDb } from "../../db/sqlite.js";
import type { PerceivedRef, PerceptionBand, PerceptionManifestPayload } from "../../godot-link/perception-manifest.js";
import {
  DisplayNameResolver,
  getCharacterPresences,
  getCharacterState,
  getContainersByIds,
  getFarmsByIds,
  getInventoryForCharacter,
  getItemDefsByIds,
  getLocationsByIds,
  getProficiencyForCharacter,
  getShelvesByIds,
  getWorkstationsByIds,
  type CharacterPresenceView,
  type CharacterStateView,
  type ContainerView,
  type FarmPlotView,
  type FarmView,
  type InventoryItemRow,
  type ItemDefView,
  type ShelfView,
  type WorkstationView,
} from "../../services/world-state/index.js";
import { cropStageDisplayName, getVariety, isRipeStage } from "../../services/world-state/crops-catalog.js";
import { getActiveLocale, t, type Locale } from "../../i18n/index.js";
import { syncPlayerNameCacheFromDb } from "../name-resolver/player-name-cache.js";
import { characterAttributeName } from "../name-resolver/index.js";
import { refreshSiteCatalog } from "../name-resolver/site-catalog.js";
import { getCraftSpec, listCraftSlugs, type CraftSlug } from "../game-tools/craft-registry.js";
import { gameTimeFromRecord } from "./time.js";
import type {
  AgentCurrentContext,
  CharacterContextEntry,
  CharacterDistanceBandContext,
  CharacterPresenceStatus,
  DistanceBandContext,
  FarmContext,
  FarmSlotContext,
  InteractiveSiteContext,
  ItemIndexEntry,
  ProficiencyEntry,
  ShelfContext,
  ShelfListingContext,
  VisibleLocationContext,
  WorkstationContext,
} from "./types.js";

// god 组成员视为有所有 owner_group 的 access 权限。仅作 access 标记，不影响可见性。
// 可见性（哪些站点/地点进 context）完全由 Godot 端的 perception manifest 给定。
const GOD_GROUP_ID = "god";

// P4 入口：从 manifest（perception band 标注的 ref 列表）+ sqlite repos 当场拼 AgentCurrentContext。
//
// 职责切分：
// - "演员主观感知"（看得见什么、近不近、能不能直接动）= Godot 算好塞进 manifest band；
//   backend 不重推空间，不读 selfPosition，不应用半径常量
// - "世界客观状态"（hp、库存、田里几格熟了、verbs 列表）= backend 从 sqlite repos 拼
// - "可访问性"（owner_group 匹配）= backend 比对 characterGroupIds
//
// availableActions 全空——所有 tool 永远 expose；执行时 Godot 按真实规则返回 tool error。
export function assembleAgentContextFromManifest(
  db: AppDb,
  townId: string,
  manifest: PerceptionManifestPayload,
): AgentCurrentContext {
  // 玩家显示名真值 = Godot 写的 player_accounts.name；渲染前刷一次到内存 cache，
  // resolver 走单一查找链（i18n catalog → npc descriptor → player cache → id）。
  syncPlayerNameCacheFromDb(db, townId);
  // 地点结构真值 = Godot 灌的 sites 表。刷新内存 catalog，供下游 db-less 的 resolver /
  // localize / renderTownMap 读取（地点全部由 Godot 传递，backend 只渲染+解析）。
  refreshSiteCatalog(db, townId);
  const characterId = manifest.characterId;
  const groupIds = manifest.characterGroupIds;
  // 单一 name resolver：所有"id → 中文名"翻译只走这一条链路（i18n catalog → id）。
  // 不允许各子流程再各自维护 fallback；新加 entity 只要在 agent-shared/name-resolver/
  // 加对应 kind 文件即可。
  const names = new DisplayNameResolver();

  const characterIds = idsOf(manifest.perceivedCharacters);
  // "NPC 知道全城哪些地点存在" — 给 move_to_location enum / alias 表用，
  // 与感知解耦：实时感知（距离过滤）走 manifest.perceivedLocations，下方 nearbyBuildings 直接消费。
  const knownLocationIds = manifest.knownLocationIds;
  const farmIds = idsOf(manifest.perceivedFarms);
  const workstationIds = idsOf(manifest.perceivedWorkstations);
  const shelfIds = idsOf(manifest.perceivedShelves);

  const farmBands = bandMap(manifest.perceivedFarms);
  const workstationBands = bandMap(manifest.perceivedWorkstations);
  const shelfBands = bandMap(manifest.perceivedShelves);

  const selfState = getCharacterState(db, townId, characterId);
  const presences = getCharacterPresences(db, townId, characterIds);
  const presenceById = new Map(presences.map((p) => [p.characterId, p]));

  // visibleLocations 用 known 集（驱动 move_to_location enum 和 alias 表）；
  // nearbyBuildings 仍来自 perceivedLocations（实时感知）。
  const locationViews = getLocationsByIds(db, townId, knownLocationIds);
  const farmViews = getFarmsByIds(db, townId, farmIds);
  // Workstations + Containers 共用 perceivedWorkstations（容器是 WorkstationNode 子类）。
  // 两张表 schema 不同（container_states 多 contents + lockItemId），所以分别查后在
  // nearbyWorkstations 里 union——下游 LLM 只看到一份统一列表。
  const workstationViews = getWorkstationsByIds(db, townId, workstationIds);
  const containerViews = getContainersByIds(db, townId, workstationIds);

  // 货架已统一为无锁容器：shelves 表是静态镜像（位置 + locationId），内容物 + 标价走
  // item_instances(ownerKind='container')，由 getShelvesByIds 一并查出（view.contents）。
  // 货架无 owner 概念——只有"附近感知到的"一份（perceived ids），不再有 ownedShelves。
  const nearbyShelfViews = getShelvesByIds(db, townId, shelfIds);

  const inventoryRows = selfState ? getInventoryForCharacter(db, townId, characterId) : [];

  // 可见性由 perception manifest 决定，backend 不再二次过滤；owner_group 只用于
  // 给每条 snapshot 标 `accessible` 字段（LLM 判断"能不能用"）。
  const nearbyFarms = farmViews.map((farm) => farmViewToContext(farm, names, groupIds, farmBands));
  const workstationCtxs = workstationViews.map((ws) => workstationViewToContext(ws, groupIds, names, workstationBands, characterId));
  // containerCtxs 同时算出 containerItemIndex（容器内容 [N] → slotIndex 映射）。
  const containerItemIndex: Record<string, ItemIndexEntry[]> = {};
  const containerCtxs = containerViews.map((c) => {
    const built = containerViewToWorkstationContext(c, inventoryRows, groupIds, names, workstationBands);
    if (built.entries.length > 0) containerItemIndex[c.containerId] = built.entries;
    return built.context;
  });
  const nearbyWorkstations = [...workstationCtxs, ...containerCtxs];
  // buildShelfContexts 同时落 shelfItemIndex（货架内容 [N] → slotIndex 映射，put_take take 反查）。
  const shelfItemIndex: Record<string, ItemIndexEntry[]> = {};
  const nearbyShelvesBuilt = buildShelfContexts(nearbyShelfViews, names, shelfBands, groupIds);
  for (const built of nearbyShelvesBuilt) {
    if (built.entries.length > 0) shelfItemIndex[built.context.id] = built.entries;
  }
  const nearbyShelves = nearbyShelvesBuilt.map((b) => b.context);

  // 地点名一律走 names.location（= 统一的 locationName：普通地点 / 组合工作台 "<def>@<group>"
  // / 工作台兜底全覆盖）。**不要**再按 isWorkstation 分流去调 names.workstation —— 组合 id
  // 在工作台目录里查不到会吐回原始串（"gold_mine_workstation@gold_mine"），正是它漏进 prompt
  // 的根因。见 name-resolver/location.ts locationName。
  const visibleLocations = locationViews.map<VisibleLocationContext>((location) => ({
    id: location.locationId,
    alias: names.location(location.locationId),
    parentId: location.parentLocationId,
    depth: location.parentLocationId ? 1 : 0,
    childIds: [],
  }));
  // itemDefs 仍要用 —— 名字走 resolver，但 staticJson（capacity 等模板级值）+
  // baseEffects 默认效果是 item_defs 表独有信息，instance 自己没写时作 fallback。
  const itemDefs = getItemDefsByIds(db, townId, inventoryRows.map((r) => r.itemDefId));
  const inventoryRender = renderInventoryEntries(inventoryRows.filter((r) => r.slotIndex < 0), itemDefs, names);  // 装备槽（GD 端约定 slotIndex<0）
  const rawBackpackRender = renderInventoryEntries(inventoryRows.filter((r) => r.slotIndex >= 0), itemDefs, names);
  // 钱包余额作为虚拟背包行注入头部（[N] 银币），让 LLM 用统一 {name, index} 引用钱包。
  // entry.slotIndex 留空 —— Godot 端按 itemId 自己从 wallet 扣。
  // 液体（水/盐水/油）不用虚拟行：renderInventoryEntries 已把 r.container.content 塞进
  // entry.containerContent，resolver 在 name mismatch 时会兜底匹配（"水"≈ 木桶里的 water），
  // 返回 {id: water, slotIndex: 木桶的 slotIndex}，Godot 端验证后从该桶倒水。
  const backpackRender = prependWalletEntriesToBackpack(rawBackpackRender, selfState?.walletCenti ?? 0, names);
  const nearbyItemsRender = renderPerceivedItems(manifest.perceivedItems, names);
  // 附近地面液体容器（掉落的桶）拼进 nearby 段：带 groundItemId，put_take 可取/存液体。
  for (const gc of manifest.perceivedGroundContainers ?? []) {
    if (gc.band !== "near") continue;
    const name = names.item(gc.itemId);
    const contentStr = gc.amount > 0 && gc.content
      ? `（${names.item(gc.content)} ${formatAmount(gc.amount)}）`
      : "（空）";
    nearbyItemsRender.context.near.push(`[0] ${name}${contentStr}`);
    const e: ItemIndexEntry = { itemDefId: gc.itemId, groundItemId: gc.instanceId };
    if (gc.amount > 0 && gc.content) e.containerContent = gc.content;
    nearbyItemsRender.entries.push(e);
  }

  // ── 统一扁平编号（从 1 顺序往后，全场唯一）──────────────────────────
  // 一遍 post-pass：按显示顺序给每个条目编 globalIndex，并把行内 [N] / 结构化 .index
  // 改成全局号；同时 flat[] 收集全部条目。resolver 按 globalIndex 反查（见 targets.ts）。
  const flat: ItemIndexEntry[] = [];
  let g = 1;
  const renumberLines = (render: { lines: string[]; entries: ItemIndexEntry[] }, scope: ItemIndexEntry["scope"]) => {
    render.entries.forEach((e, i) => {
      e.globalIndex = g;
      e.scope = scope;
      render.lines[i] = render.lines[i].replace(/^\[\d+\]/, `[${g}]`);
      flat.push(e);
      g++;
    });
  };
  renumberLines(backpackRender, "backpack");
  renumberLines(inventoryRender, "equipment");
  // nearby：near 行与 entries 一一对应（far 行无 entries/编号）。
  nearbyItemsRender.entries.forEach((e, i) => {
    e.globalIndex = g;
    e.scope = "nearby";
    nearbyItemsRender.context.near[i] = nearbyItemsRender.context.near[i].replace(/^\[\d+\]/, `[${g}]`);
    flat.push(e);
    g++;
  });
  // 容器内容：WorkstationContext.items[].index 与 containerItemIndex[id] 一一对应。
  for (const ctx of containerCtxs) {
    const entries = containerItemIndex[ctx.id];
    if (!entries || !ctx.items) continue;
    ctx.items.forEach((it, i) => {
      const e = entries[i];
      if (!e) return;
      e.globalIndex = g;
      e.scope = "container";
      e.containerId = ctx.id;
      it.index = g;
      flat.push(e);
      g++;
    });
  }
  // 货架 listings：ShelfContext.listings[].index 与 shelfItemIndex[id] 一一对应。
  for (const built of nearbyShelvesBuilt) {
    const entries = shelfItemIndex[built.context.id];
    if (!entries) continue;
    built.context.listings.forEach((l, i) => {
      const e = entries[i];
      if (!e) return;
      e.globalIndex = g;
      e.scope = "shelf";
      e.containerId = built.context.id;
      l.index = g;
      flat.push(e);
      g++;
    });
  }

  return {
    currentLocation: manifest.selfLocationId || "unknown",
    gameTime: manifest.gameTime ?? gameTimeFromRecord({}),
    visibleLocations,
    availableActions: [],
    characterAttributes: characterAttributesFromState(selfState),
    selfDrunk: selfState?.drunk ?? 0,
    selfDrunkTier: selfState?.drunkTier ?? "",
    proficiency: getProficiencyForCharacter(db, townId, characterId).map<ProficiencyEntry>((row) => ({
      skillId: row.skillId,
      value: row.value,
    })),
    nearbyBuildings: bandRefsToContext(manifest.perceivedLocations, (id) => id),
    nearbyCharacters: bandCharacterRefs(manifest.perceivedCharacters, presenceById, names),
    nearbyItems: nearbyItemsRender.context,
    nearbyFarms,
    nearbyWorkstations,
    nearbyShelves,
    groups: groupIds,
    interactiveSites: buildInteractiveSites(nearbyFarms, nearbyWorkstations, nearbyShelves, names),
    inventory: inventoryRender.lines,
    backpack: backpackRender.lines,
    backpackCarryText: selfState ? `${formatCurrentOverMax(selfState.carryWeight, selfState.maxCarry)} kg` : undefined,
    itemIndex: {
      equipment: inventoryRender.entries,
      backpack: backpackRender.entries,
      nearby: nearbyItemsRender.entries,
      containers: containerItemIndex,
      shelves: shelfItemIndex,
      flat,
    },
    walletCenti: selfState?.walletCenti ?? 0,
    lastUpdatedAt: manifest.occurredAt,
  };
}

function idsOf(refs: PerceivedRef[]): string[] {
  return refs.map((r) => r.id);
}

function bandMap(refs: PerceivedRef[]): Map<string, PerceptionBand> {
  return new Map(refs.map((r) => [r.id, r.band]));
}

function characterAttributesFromState(state: CharacterStateView | undefined): string[] {
  if (!state) return [];
  const locale = getActiveLocale();
  const lines: string[] = [
    `${characterAttributeName("hp")}: ${formatCurrentOverMax(state.hp, state.maxHp)}`,
    `${characterAttributeName("stamina")}: ${formatSicknessRiskMeter(state.stamina, state.maxStamina, 30, locale)}`,
    `${characterAttributeName("hunger")}: ${formatSicknessRiskMeter(state.hunger, state.maxHunger, 50, locale)}`,
    `${characterAttributeName("rest")}: ${formatSicknessRiskMeter(state.rest, state.maxRest, 40, locale)}`,
    `${characterAttributeName("strength")}: ${formatNumber(state.strength)}`,
    `${characterAttributeName("constitution")}: ${formatNumber(state.constitution)}`,
  ];
  if (state.burning) lines.push("burning");
  if (state.activeStatuses.length > 0) {
    const tags = state.activeStatuses
      .map((c) => {
        if (typeof c === "string") return c;
        if (c && typeof c === "object") {
          const rec = c as Record<string, unknown>;
          return String(rec.type ?? rec.id ?? "");
        }
        return "";
      })
      .filter(Boolean);
    if (tags.length > 0) lines.push(`statuses: ${tags.join(", ")}`);
  }
  // 档位 key 由 Godot 算好持久化（state.drunkTier/sicknessTier）；这里只渲染，不复制阈值。
  pushImpairmentLines(lines, "drunk", state.drunkTier, state.drunk, locale);
  pushImpairmentLines(lines, "sick", state.sicknessTier, state.sickness, locale);
  pushSicknessSymptomLine(lines, state.symptoms, state.sicknessTier, locale);
  // 负重档位（carryTier 非空才渲染）：value 用当前总重 kg。
  pushImpairmentLines(lines, "encumber", state.carryTier, state.carryWeight, locale);
  return lines;
}

// 醉酒 / 生病：超阈值才向自我感知里塞三行——状态档位、可能后果、roleplay 指令。
// 档位判定（阈值）只在 Godot src/sim/characters/impairment.gd 发生；backend 收到的 tierKey
// 是 ""（清醒/健康，不渲染）或 tipsy/drunk/wasted（drunk）、mild/moderate/severe（sick）。
// raw value 仍传进来只为了显示 "65/100" 的数字，不参与档位判定。
function pushImpairmentLines(
  lines: string[],
  kind: "drunk" | "sick" | "encumber",
  tierKey: string,
  value: number,
  locale: Locale,
): void {
  if (!tierKey) return;
  const level = t(`prompt.context.impairment.${kind}.label.${tierKey}`, locale);
  lines.push(t(`prompt.context.impairment.${kind}.line`, locale, { level, value: Math.round(value) }));
  lines.push(t(`prompt.context.impairment.${kind}.consequence`, locale));
  lines.push(t(`prompt.context.impairment.${kind}.roleplay`, locale, { level }));
}

function pushSicknessSymptomLine(lines: string[], symptoms: Record<string, number>, tierKey: string, locale: Locale): void {
  if (!tierKey) return;
  const symptomText = formatSymptomList(symptoms, locale);
  if (!symptomText) return;
  lines.push(t("prompt.context.impairment.sick.symptoms_line", locale, { symptoms: symptomText }));
}

function localizeDiseaseName(diseaseId: string, locale: Locale): string {
  const key = `disease.${diseaseId}.name`;
  const translated = t(key, locale);
  return translated === key ? diseaseId : translated;
}

function localizeSymptomName(symptomId: string, locale: Locale): string {
  const key = `symptom.${symptomId}.name`;
  const translated = t(key, locale);
  return translated === key ? symptomId : translated;
}

function formatSymptomList(symptoms: Record<string, number>, locale: Locale): string {
  return Object.entries(symptoms)
    .filter(([, value]) => Number.isFinite(value) && value > 0.5)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 6)
    .map(([id, value]) => `${localizeSymptomName(id, locale)} ${Math.round(value)}/100`)
    .join("、");
}

// "100/100" 格式；max 缺失（manifest 没带或未连上）退回单值显示，不至于让 LLM 看到孤零零的 "/?"。
function formatCurrentOverMax(current: number, max: number | undefined): string {
  const cur = Math.round(current);
  if (max == null || !Number.isFinite(max)) return String(cur);
  return `${cur}/${Math.round(max)}`;
}

function formatSicknessRiskMeter(current: number, max: number | undefined, riskThresholdPct: number, locale: Locale): string {
  const text = formatCurrentOverMax(current, max);
  if (max == null || !Number.isFinite(max) || max <= 0) return text;
  const pct = current / max * 100;
  return pct < riskThresholdPct ? `${text} ${t("prompt.context.body_common_sense.sickness_risk_suffix", locale)}` : text;
}

function formatNumber(value: number): string {
  return Number.isFinite(value) ? String(Math.round(value)) : "0";
}

function bandCharacterRefs(
  refs: PerceivedRef[],
  presence: Map<string, CharacterPresenceView>,
  names: DisplayNameResolver,
): CharacterDistanceBandContext {
  const near: CharacterContextEntry[] = [];
  const far: CharacterContextEntry[] = [];
  for (const ref of refs) {
    // entry.id 改成已解析的中文名；renderer 那边 displayContextEntry 仍会再过一道 locationName
    // / catalog，找不到就显示这个名字，名字一致性由本 resolver 兜底。
    const displayId = names.character(ref.id) || ref.id;
    const p = presence.get(ref.id);
    const status = formatPresenceStatus(p, names);
    const entry: CharacterContextEntry = status ? { id: displayId, status } : { id: displayId };
    // direct 不适用 character，归入 near。
    (ref.band === "far" ? far : near).push(entry);
  }
  return { near, far };
}

// 通用 ref → DistanceBandContext。"direct" band 归入 near（locations / items 没有 approach 概念）。
function bandRefsToContext(refs: PerceivedRef[], display: (id: string) => string): DistanceBandContext {
  const near: string[] = [];
  const far: string[] = [];
  for (const ref of refs) {
    (ref.band === "far" ? far : near).push(display(ref.id));
  }
  return { near, far };
}

// 优先级：dead > sleeping > 当前在做的 activity > animState passthrough（"走动中"等）> 无。
// dead/sleeping 是肉眼最显著的特征；其次是"在 X 干活"——比孤零零的 "walking" 更具体；
// 二者都没有时再退回 animState，保留旧行为不让 LLM 突然丢信息。
// activity 来源是 character_states.currentActivityKind/Target（Godot runner 写）；翻译目标 slug
// 用本地 name resolver——LLM 边界做 id↔名字翻译（feedback_llm_id_name_boundary）。
function formatPresenceStatus(
  p: CharacterPresenceView | undefined,
  names: DisplayNameResolver,
): CharacterPresenceStatus | undefined {
  if (!p) return undefined;
  if (!p.alive) return { kind: "dead" };
  if (p.isSleeping) return { kind: "sleeping" };
  const activity = activityFromPresence(p, names);
  if (activity) return activity;
  if (p.animState && p.animState !== "idle") return { kind: "anim", state: p.animState };
  return undefined;
}

// Slug → CharacterPresenceStatus 的"边界翻译"。未知 kind 直接落 anim，至少把 kind 透传出去；
// target 缺失（NULL/空串）时给个不带 place 的兜底文案，避免渲染 "在 旁忙碌" 这种空洞串。
function activityFromPresence(
  p: CharacterPresenceView,
  names: DisplayNameResolver,
): CharacterPresenceStatus | undefined {
  const kind = p.currentActivityKind;
  if (!kind) return undefined;
  const target = p.currentActivityTarget ?? "";
  switch (kind) {
    case "using_workstation":
      return { kind: "using_workstation", place: names.workstation(target) || target };
    case "working_at_farm":
      return { kind: "working_at_farm", place: names.location(target) || target };
    default:
      // 未识别的 activity slug 当作 anim 透传；renderer 端走 i18n fallback。
      return { kind: "anim", state: kind };
  }
}

function farmViewToContext(farm: FarmView, names: DisplayNameResolver, characterGroupIds: string[], bands: Map<string, PerceptionBand>): FarmContext {
  const moisturePercent = Math.round(farm.moisture * 100);
  const totalSlots = farm.totalSlots;
  const plotByIndex = new Map<number, FarmPlotView>();
  for (const p of farm.plots) plotByIndex.set(p.plotIndex, p);

  let occupiedSlots = 0;
  let ripeSlots = 0;
  let pestSlots = 0;
  let drySlots = 0;
  let wetSlots = 0;
  const slots: FarmSlotContext[] = [];

  for (let i = 0; i < totalSlots; i++) {
    const plot = plotByIndex.get(i);
    if (!plot || !plot.varietyId) {
      slots.push({
        index: i,
        occupied: false,
        statusTags: ["空地", "可种植"],
        statusText: "空地，可种植",
      });
      continue;
    }
    const variety = getVariety(plot.varietyId);
    // stage 直接读 Godot 写盘的 plot.stage，不再 backend 推算。
    // plot.stage 为空字符串 / undefined 时按未知处理（旧 DB 行的兜底）。
    const stage = plot.stage ?? "";
    const ripe = isRipeStage(stage);
    const needsWater = !!variety && farm.moisture < variety.optimalMoistureMin;
    const tooWet = !!variety && farm.moisture > variety.optimalMoistureMax;
    occupiedSlots += 1;
    if (ripe) ripeSlots += 1;
    if (plot.hasPest) pestSlots += 1;
    if (needsWater) drySlots += 1;
    if (tooWet) wetSlots += 1;
    const tags: string[] = [];
    if (ripe) tags.push("可收获");
    if (plot.hasPest) tags.push("有虫");
    if (needsWater) tags.push("缺水");
    if (tooWet) tags.push("过湿");
    if (tags.length === 0) tags.push("正常");
    // variety displayName 优先 catalog（hardcoded zh），其次 resolver（i18n / sqlite 兜底），最后 id。
    const displayName = variety?.displayName || names.item(plot.varietyId) || plot.varietyId;
    const stageText = cropStageDisplayName(plot.varietyId, stage);
    slots.push({
      index: i,
      occupied: true,
      variety: plot.varietyId,
      displayName,
      stage,
      stageDisplay: stageText,
      moisture: farm.moisture,
      moisturePercent,
      hasPest: plot.hasPest,
      ripe,
      needsWater,
      canHarvest: ripe,
      needsPestControl: plot.hasPest,
      statusTags: tags,
      statusText: `${displayName} · ${stageText} · ${tags.join(", ")}`,
    });
  }

  const emptySlots = Math.max(0, totalSlots - occupiedSlots);
  // Summary 头部：聚合统计；后接每格详情（"详情：1号空地; 2号 番茄·成长·..."）。
  const summaryParts: string[] = [];
  if (totalSlots > 0) summaryParts.push(`共${totalSlots}格`);
  summaryParts.push(`土壤水分${moisturePercent}%`);
  if (emptySlots > 0) summaryParts.push(`空地${emptySlots}格`);
  if (occupiedSlots > 0) summaryParts.push(`已种植${occupiedSlots}格`);
  if (ripeSlots > 0) summaryParts.push(`可收${ripeSlots}格`);
  if (pestSlots > 0) summaryParts.push(`有虫${pestSlots}格`);
  if (drySlots > 0) summaryParts.push(`缺水${drySlots}格`);
  if (wetSlots > 0) summaryParts.push(`过湿${wetSlots}格`);
  const headline = summaryParts.join("，");
  const slotDetails = foldSlotDetails(slots);
  const statusSummary = slotDetails ? `${headline}；详情：${slotDetails}` : headline;

  return {
    id: farm.farmId,
    locationId: farm.locationId,
    directlyInteractable: bands.get(farm.farmId) === "direct",
    accessible: isOwnedSiteAccessibleToGroups(farm.ownerGroup, characterGroupIds),
    ownerGroup: farm.ownerGroup,
    totalSlots,
    occupiedSlots,
    emptySlots,
    ripeSlots,
    pestSlots,
    drySlots,
    statusSummary,
    slots,
  };
}

// 把 slot 列表渲染成"详情"字符串。
// - 编号直接用 plot_index（0-based，跟 sqlite farm_plots.plotIndex 对齐）。LLM 调
//   plan_farm_work / plant_seed 时给的 slot_index 就跟这里显示的"N号"一致，不需要做 ±1 换算。
// - 连续相邻且 statusText 相同的格子折叠成范围（"0-6号: 空地，可种植" 或
//   "1-10号: 小麦 · 成熟 · 可收获"），减少 prompt 噪声。
function foldSlotDetails(slots: FarmSlotContext[]): string {
  if (slots.length === 0) return "";
  const sorted = [...slots].sort((a, b) => a.index - b.index);
  const parts: string[] = [];
  let i = 0;
  while (i < sorted.length) {
    const label = sorted[i].statusText ?? sorted[i].displayName ?? "?";
    let j = i;
    while (
      j + 1 < sorted.length
      && sorted[j + 1].index === sorted[j].index + 1
      && (sorted[j + 1].statusText ?? sorted[j + 1].displayName ?? "?") === label
    ) {
      j++;
    }
    const start = sorted[i].index;
    const end = sorted[j].index;
    parts.push(start === end ? `${start}号: ${label}` : `${start}-${end}号: ${label}`);
    i = j + 1;
  }
  return parts.join("; ");
}


function workstationViewToContext(ws: WorkstationView, characterGroupIds: string[], names: DisplayNameResolver, bands: Map<string, PerceptionBand>, selfCharacterId: string): WorkstationContext {
  // 自己用着的工作台不渲染"使用中"提示——LLM 已经知道自己在干嘛，避免冗余噪音。
  const occupiedByOther = ws.currentOperatorId && ws.currentOperatorId !== selfCharacterId;
  return {
    id: ws.workstationNodeId,
    workstationId: ws.workstationDefId,
    displayName: names.workstation(ws.workstationDefId),
    directlyInteractable: bands.get(ws.workstationNodeId) === "direct",
    // 工作台对所有人可用——group 不再闸门使用。owner_group 仅作招牌 flavor。
    accessible: true,
    ownerGroup: ws.ownerGroup,
    interactionMode: ws.interactionMode,
    verbs: ws.verbs,
    slotCount: ws.slotCount,
    currentOperatorName: occupiedByOther ? names.character(ws.currentOperatorId!) : undefined,
  };
}

// ContainerView → WorkstationContext。容器是 WorkstationNode 子类，对 LLM 统一暴露成"工作台"。
// items 仅在 actor 持锁（或无锁）时填充；否则空数组表达"看得到容器但不知道里面"。
// 输出 entries（容器内容的 [N] → {itemDefId, slotIndex} 映射）供 put_take 反查；
// 容器锁住时 entries 也为空。
function containerViewToWorkstationContext(c: ContainerView, actorInventoryRows: InventoryItemRow[], characterGroupIds: string[], names: DisplayNameResolver, bands: Map<string, PerceptionBand>): { context: WorkstationContext; entries: ItemIndexEntry[] } {
  const locked = !!c.lockItemId;
  const unlocked = !locked || actorInventoryRows.some((r) => r.itemDefId === c.lockItemId && r.stackCount > 0);
  const items: NonNullable<WorkstationContext["items"]> = [];
  const entries: ItemIndexEntry[] = [];
  if (unlocked) {
    if (c.walletCenti > 0) {
      items.push({ index: 1, itemId: "silver_coin", quantity: c.walletCenti / 100 });
      entries.push({ itemDefId: "silver_coin" });
    }
    c.contents
      .filter((r) => r.itemDefId && r.stackCount > 0)
      .forEach((r) => {
        const index = items.length + 1;
        // 内容物若是装着液体的容器（仓库里的酒桶/木桶），带上液体量/发酵态——
        // 否则 NPC 只看到 "酿酒桶×1" 不知道里面有没有水/酒、酿没酿好。
        const liquid = r.container && r.container.amount > 0 && r.container.content
          ? { amount: r.container.amount, content: r.container.content, fermenting: r.container.fermenting, ceiling: r.container.ceiling }
          : undefined;
        items.push({ index, slotIndex: r.slotIndex, itemId: r.itemDefId, quantity: r.stackCount, quality: r.quality, container: liquid });
        entries.push({ itemDefId: r.itemDefId, slotIndex: r.slotIndex });
      });
  }
  const context: WorkstationContext = {
    id: c.containerId,
    workstationId: defIdFromObjectId(c.containerId),
    displayName: names.location(c.containerId),
    directlyInteractable: bands.get(c.containerId) === "direct",
    // 容器对所有人可用——group 不再闸门。能否打开只看锁（locked/unlocked）。
    accessible: true,
    ownerGroup: c.ownerGroup,
    interactionMode: "container",
    verbs: ["take", "put", "inspect"],
    slotCount: c.slotCount,
    lockItemId: c.lockItemId,
    locked,
    unlocked,
    items,
  };
  return { context, entries };
}

// 给定 ShelfView 列表 + 全量 listings byShelfId 索引，每个 view 输出一条 ShelfContext。
// 关键：空架（listings 为 []）也输出 —— 让 LLM 看到"自家空货架等着上货"，update_shelf 才能寻址。
// entries 是 listings 的 [N] → {itemDefId, listingId} 映射，update_shelf 的 update/remove 按 listingId 走。
function buildShelfContexts(
  views: ShelfView[],
  names: DisplayNameResolver,
  bands: Map<string, PerceptionBand>,
  characterGroupIds: string[],
): Array<{ context: ShelfContext; entries: ItemIndexEntry[] }> {
  return views.map((view) => {
    const rows = view.contents.filter((r) => r.itemDefId && r.stackCount > 0);
    const entries: ItemIndexEntry[] = [];
    const listings: ShelfListingContext[] = [];
    const canSeeWallet = isOwnedSiteAccessibleToGroups(view.ownerGroup, characterGroupIds);
    if (canSeeWallet && view.walletCenti > 0) {
      entries.push({ itemDefId: "silver_coin" });
      listings.push({
        index: 1,
        itemId: "silver_coin",
        displayName: names.item("silver_coin"),
        quantity: view.walletCenti / 100,
        priceCenti: 0,
        priceSilver: 0,
        descriptionParts: [],
      });
    }
    rows.forEach((r) => {
      entries.push({ itemDefId: r.itemDefId, slotIndex: r.slotIndex });
      listings.push(shelfRowToListingContext(r, names, listings.length + 1));
    });
    return {
      context: {
        id: view.shelfId,
        locationId: view.locationId ?? view.shelfId,
        ownerGroup: view.ownerGroup,
        displayName: names.location(view.shelfId),
        directlyInteractable: bands.get(view.shelfId) === "direct",
        slotCount: view.slotCount,
        interactionRadiusMeters: view.interactionRadius,
        listings,
      },
      entries,
    };
  });
}

function shelfRowToListingContext(r: InventoryItemRow, names: DisplayNameResolver, index: number): ShelfListingContext {
  const priceCenti = r.listingPriceCenti ?? 0;
  const priceSilver = priceCenti / 100;
  return {
    index,
    slotIndex: r.slotIndex,
    itemId: r.itemDefId,
    displayName: names.item(r.itemDefId),
    quantity: r.stackCount,
    priceCenti,
    priceSilver,
    priceText: priceCenti > 0 ? `${priceSilver.toFixed(2)} 银` : undefined,
    quality: r.quality,
    freshnessTier: r.freshness?.tier,
    descriptionParts: [],
  };
}

function buildInteractiveSites(
  farms: FarmContext[],
  workstations: WorkstationContext[],
  shelves: ShelfContext[],
  names: DisplayNameResolver,
): InteractiveSiteContext[] {
  const farmSites: InteractiveSiteContext[] = farms.map((farm, index) => ({
    id: farm.id,
    locationId: farm.locationId,
    displayName: names.location(farm.locationId) || `farm_${index + 1}`,
    kind: "farm",
    directlyInteractable: !!farm.directlyInteractable,
    accessible: farm.accessible,
    ownerGroup: farm.ownerGroup,
    availableActions: ["plan_farm_work"],
    summary: farm.statusSummary,
  }));
  const workstationSites: InteractiveSiteContext[] = workstations.map((ws, index) => ({
    id: ws.id,
    locationId: ws.id,
    displayName: names.workstation(ws.workstationId) || ws.workstationId || `ws_${index + 1}`,
    kind: "workstation",
    directlyInteractable: ws.directlyInteractable ?? true,
    accessible: ws.accessible,
    ownerGroup: ws.ownerGroup,
    availableActions: availableActionsForWorkstation(ws.workstationId, ws.interactionMode),
    verbs: ws.verbs,
    workstationId: ws.workstationId,
    interactionMode: ws.interactionMode,
    slotCount: ws.slotCount,
    lockItemId: ws.lockItemId,
    locked: ws.locked,
    unlocked: ws.unlocked,
    items: ws.items,
    currentOperatorName: ws.currentOperatorName,
  }));
  const shelfSites: InteractiveSiteContext[] = shelves.map((shelf, index) => ({
    id: shelf.id,
    locationId: shelf.locationId,
    displayName: shelf.displayName || names.location(shelf.id) || `shelf_${index + 1}`,
    kind: "shelf",
    directlyInteractable: shelf.directlyInteractable ?? true,
    availableActions: ["view_container", "put_take"],
  }));
  return [...farmSites, ...workstationSites, ...shelfSites];
}

function defIdFromObjectId(objectId: string): string {
  const at = objectId.indexOf("@");
  return at > 0 ? objectId.slice(0, at) : objectId;
}

// owner_group 真值都在 Godot 场景树（WorkstationNode / LocationMarker / 沿链解析的 farm），
// 写进 SQLite *.ownerGroup。空字符串/undefined = 公用。仅用于给 snapshot 标 `accessible`
// 字段（"能不能用"），不参与可见性 —— 可见性由 perception manifest 决定。
// 工作台 → 该工作台对应的 axis tool 名（用于 InteractiveSiteContext.availableActions
// 给 LLM 当"这里能用什么工具"的提示）。容器型（含水井）走 put_take / view_container；
// 其他按 .workstations 反查到对应 axis slug。一个工作台可能落到多个 axis
// （workbench 既能 woodwork 又能 assemble），全部列出来。找不到映射时给空数组。
function availableActionsForWorkstation(workstationId: string, interactionMode?: string): string[] {
  if (interactionMode === "container") return ["put_take", "view_container"];
  const crafts: CraftSlug[] = [];
  for (const slug of listCraftSlugs()) {
    if (getCraftSpec(slug).workstations.includes(workstationId)) crafts.push(slug);
  }
  return crafts;
}

function isOwnedSiteAccessibleToGroups(ownerGroup: string | undefined, characterGroupIds: string[]): boolean {
  if (characterGroupIds.includes(GOD_GROUP_ID)) return true;
  if (!ownerGroup) return true;
  return characterGroupIds.includes(ownerGroup);
}

// 与 Godot ContainerAspect._format_amount 对齐：接近整数（误差 < 0.05）显示整数，
// 否则一位小数。让 backend 和 tooltip 看起来一致。
function formatAmount(value: number): string {
  if (Math.abs(value - Math.round(value)) < 0.05) return String(Math.round(value));
  return value.toFixed(1);
}

// 渲染一段 inventory entries（"[N] name xN（part1 · part2 · ...）"），同时输出
// index → stack key 的映射（itemDefId + quality），供 tool resolver 反查使用。
// 直接读 item_instances typed 字段（rows 已是 ItemInstanceAspects 形状），
// item_defs 仅作 staticJson（capacity）/ baseEffects 默认值 fallback。
// 行序就是 index 序：第 i 行对应 entries[i-1]，LLM 看到的 [i] 与 resolver 查到的一致。
function renderInventoryEntries(
  rows: InventoryItemRow[],
  itemDefs: Map<string, ItemDefView>,
  names: DisplayNameResolver,
): { lines: string[]; entries: ItemIndexEntry[] } {
  const filtered = rows.filter((r) => r.itemDefId && r.stackCount > 0);
  const lines: string[] = [];
  const entries: ItemIndexEntry[] = [];
  filtered.forEach((r, idx) => {
    const indexLabel = idx + 1;
    const head = `[${indexLabel}] ${names.item(r.itemDefId)} x${r.stackCount}`;
    const parts: string[] = [];
    const def = itemDefs.get(r.itemDefId);
    // tags 给 LLM 看分类信息（tool/metal、food/cooked、liquid_container、currency 等）。
    // tag 本身没 i18n，原样输出 slug；前缀也用 "tags"（与 tag 值同语言）避免中英混杂。
    // tag 是 reaction-emergent 字段，instance 自带，不再走 item_defs。
    if (r.tags.length > 0) {
      parts.push(`tags：${r.tags.join(", ")}`);
    }
    // 效果展示优先 instance 的 displayedEffects（Godot 已按 quality×freshness 算好），
    // 没有再退 instance.baseEffects → item_def.baseEffects template fallback。
    const effects = r.displayedEffects ?? r.baseEffects ?? def?.baseEffects ?? null;
    const effectsLine = formatEffectsLine(effects, names);
    if (effectsLine) parts.push(effectsLine);
    if (typeof r.quality === "number" && r.quality < 100) {
      parts.push(`品质${r.quality}`);
    }
    // freshness 是可变 aspect；只有食物等 reaction 写了这列才有，工具/货币 NULL。
    // tier=5 = 满分不噪声；<5 才显示。
    const freshTier = r.freshness?.tier;
    if (typeof freshTier === "number" && freshTier < 5) {
      parts.push(`新鲜度${freshTier}/5`);
    }
    // 容器（桶/瓶等 kind=container）：capacity 在 item_defs.staticJson（template 静态），
    // amount/content 在 instance.container（aspect 列）。两层分别取。空桶也输出
    // "容量：空 0/N"，与 Godot ContainerAspect.display_line() 一致。
    const capacityRaw = def?.staticJson?.capacity;
    const capacity = typeof capacityRaw === "number" ? capacityRaw : 0;
    if (capacity > 0) {
      const amountNum = r.container?.amount ?? 0;
      const content = r.container?.content;
      const capText = formatAmount(capacity);
      if (amountNum > 0 && typeof content === "string" && content.length > 0) {
        const fermNote = r.container?.fermenting ? `，酿造中（品质上限${r.container.ceiling ?? "?"}）` : "";
        parts.push(`容量：${names.item(content)} ${formatAmount(amountNum)}/${capText}${fermNote}`);
      } else {
        parts.push(`容量：空 0/${capText}`);
      }
    }
    lines.push(parts.length > 0 ? `${head}（${parts.join(" · ")}）` : head);
    // containerContent 给 resolver 兜底用（liquid_container 装的 water/brine/...），
    // LLM 写 {name:"水", index:<木桶>} 时不报 name mismatch。空桶不挂，避免误匹配。
    const liquidContent = r.container && r.container.amount > 0 ? r.container.content : null;
    const entry: ItemIndexEntry = { itemDefId: r.itemDefId, slotIndex: r.slotIndex };
    if (liquidContent) entry.containerContent = liquidContent;
    entries.push(entry);
  });
  return { lines, entries };
}

// 钱包余额 → 背包头部的虚拟行（仅 silver_coin）。
// wallet 真值就是 silver-centi 整数；不展示 gold_coin 换算（避免假装"钱包里有 X 枚金币"）。
// LLM 要付金币就自己用 10:1 换算成银币 count 即可。
// walletCenti=0 时不插入。entry.slotIndex 留空 —— resolver/Godot 自然走 wallet 路径。
function prependWalletEntriesToBackpack(
  raw: { lines: string[]; entries: ItemIndexEntry[] },
  walletCenti: number,
  names: DisplayNameResolver,
): { lines: string[]; entries: ItemIndexEntry[] } {
  if (walletCenti <= 0) return raw;
  const locale = getActiveLocale();
  const walletLines = [
    t("prompt.context.inventory.wallet.silver_line_format", locale, {
      index: 1,
      name: names.item("silver_coin"),
      amount: formatAmount(walletCenti / 100),
    }),
  ];
  const walletEntries: ItemIndexEntry[] = [
    { itemDefId: "silver_coin" },
  ];
  // 原 entries 的 [N] 标签在 head 里硬编码了，需要按新偏移重写每一行的 "[N]" 前缀。
  const offset = walletEntries.length;
  const shiftedLines = raw.lines.map((line, idx) => line.replace(/^\[\d+\]/, `[${idx + 1 + offset}]`));
  return {
    lines: [...walletLines, ...shiftedLines],
    entries: [...walletEntries, ...raw.entries],
  };
}

// 附近物品列表：只对 near 行编 [N]（与 itemIndex.nearby 对齐），far 行只显示名字。
// 这样 pick_up_item 用的 index 不会出现"指向远处那栏"的情况，resolver 出错就是真的越界。
// PerceivedRef.id 是 itemDefId（template slug），perception manifest 不带 instance id；
// 同 itemDefId 的多份地上物在 near 段会渲染成多行同名 [1]/[2]，但发到 Godot 只有 itemId，
// Godot 端按距离 / 默认规则选实例（[N] 在拾取时主要是 LLM 心智一致性，不能真正区分实例）。
function renderPerceivedItems(
  refs: PerceivedRef[],
  names: DisplayNameResolver,
): { context: DistanceBandContext; entries: ItemIndexEntry[] } {
  const near: string[] = [];
  const far: string[] = [];
  const entries: ItemIndexEntry[] = [];
  for (const ref of refs) {
    if (ref.band === "far") {
      far.push(names.item(ref.id));
    } else {
      const indexLabel = entries.length + 1;
      near.push(`[${indexLabel}] ${names.item(ref.id)}`);
      entries.push({ itemDefId: ref.id });
    }
  }
  return { context: { near, far }, entries };
}

// displayedEffects/baseEffects 是 typed JSON dict（{"hunger":30,"stamina":5,...}）。
// 渲染成"饱食 +30, 体力 +5"——键走 attribute i18n catalog，值四舍五入到 int，
// 正数加 "+"，负数自带 "-"，零值跳过（无意义）。
function formatEffectsLine(effects: Record<string, number> | null | undefined, _names: DisplayNameResolver): string {
  if (!effects) return "";
  const parts: string[] = [];
  for (const [key, raw] of Object.entries(effects)) {
    if (typeof raw !== "number" || !Number.isFinite(raw)) continue;
    const value = Math.round(raw);
    if (value === 0) continue;
    const locale = getActiveLocale();
    const label = key.startsWith("disease.")
      ? t("prompt.context.item.treat_disease_format", locale, { disease: localizeDiseaseName(key.slice("disease.".length), locale) })
      : key.startsWith("symptom.")
        ? localizeSymptomName(key.slice("symptom.".length), locale)
        : characterAttributeName(key) || key;
    parts.push(value > 0 ? `${label} +${value}` : `${label} ${value}`);
  }
  return parts.join(", ");
}
