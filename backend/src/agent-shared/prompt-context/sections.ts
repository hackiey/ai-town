// 共享的 prompt context section 渲染器。
// 这些函数描述"角色周围的世界"——所有 agent 看到的形态一致。
// per-agent 的 prompt orchestrator 自己决定要不要 include 这些 section，按什么顺序，
// 但 section 本身的格式不归 per-agent 改。

import { getActiveLocale, type Locale, t } from "../../i18n/index.js";
import { craftForSkillId, craftForWorkstationVerb, skillIdForCraft } from "../game-tools/craft-registry.js";
import { characterName, localizeText, locationName, locationDescription, locationDirection, locationAccess } from "../name-resolver/index.js";
import { workstationName, workstationDescription } from "../name-resolver/workstation.js";
import { locationDescriptors, type LocationDescriptor } from "../name-resolver/source-data.js";
import { renderInteractiveSiteName } from "../entity-descriptions/site-naming.js";
import { getReactionsForCraft, type ReactionMeta } from "../../services/world-state/reaction-catalog.js";
import type {
  AgentCurrentContext,
  CharacterContextEntry,
  CharacterDistanceBandContext,
  DistanceBandContext,
  InteractiveSiteContext,
  ProficiencyEntry,
} from "./types.js";

// 熟练度等级阈值（与 docs/proficiency_system.md 对齐）。
// renderer 端固定，不放 i18n 因为档位顺序是设计常量。
const PROFICIENCY_TIERS: Array<{ min: number; key: string }> = [
  { min: 90, key: "master" },
  { min: 75, key: "expert" },
  { min: 55, key: "skilled" },
  { min: 35, key: "competent" },
  { min: 15, key: "apprentice" },
  { min: 0, key: "novice" },
];

function proficiencyTier(value: number): string {
  for (const tier of PROFICIENCY_TIERS) {
    if (value >= tier.min) return tier.key;
  }
  return "novice";
}

export type RenderedContextSection = {
  title: string;
  body: string;
};

export function renderNearbyEnvironmentSections(
  current: AgentCurrentContext,
  locale: Locale = getActiveLocale(),
): RenderedContextSection[] {
  return [
    {
      title: t("prompt.context.label.nearby_buildings", locale),
      body: renderLocationDistanceBandLines(current.nearbyBuildings, current, {
        near: t("prompt.context.distance.buildings_near", locale),
        far: t("prompt.context.distance.buildings_far", locale),
      }),
    },
    {
      title: t("prompt.context.label.nearby_characters", locale),
      body: renderCharacterDistanceBandLines(current.nearbyCharacters, {
        near: t("prompt.context.distance.characters_near", locale),
        far: t("prompt.context.distance.characters_far", locale),
      }),
    },
    {
      title: t("prompt.context.label.nearby_items", locale),
      body: renderDistanceBandLines(current.nearbyItems, "item", {
        near: t("prompt.context.distance.items_near", locale),
        far: t("prompt.context.distance.items_far", locale),
      }),
    },
  ];
}

// 渲染"你的手艺"——按 proficiency entries 列出每个 skill，每个 skill 下挂可做的
// reaction 列表（带难度）。数据来源：reaction-catalog（Godot 启动期 dump 进来）。
//
// 排版：
//   ### {skill}：{tier}（{value}）
//   - {label}（难度 {d}）
//   - ...
// 末尾追加一句通用 hint，告诉 LLM 难度对照熟练度的大致规则。
//
// 全空（生手）→ 一句占位文案；reaction catalog 未就绪时降级成纯 skill 行（无 bullets）。
// 数值四舍五入到整数；公式真值是 float，但 prompt 里没必要展示小数点。
export function renderProficiencySection(
  current: AgentCurrentContext,
  locale: Locale = getActiveLocale(),
): RenderedContextSection {
  const title = t("prompt.context.label.proficiency", locale);
  if (current.proficiency.length === 0) {
    return { title, body: t("prompt.context.proficiency.empty", locale) };
  }
  const blocks: string[] = [];
  for (const entry of current.proficiency) {
    blocks.push(renderProficiencyBlock(entry, locale));
  }
  blocks.push(t("prompt.context.proficiency.usage_hint", locale));
  return { title, body: blocks.join("\n\n") };
}

// 单个 skill 块：标题行（手艺名 + tier + 数值），然后该 axis 下所有 reaction（带难度）的 bullets。
// reaction-catalog 未就绪 / 该 skill 不对应任何 axis（admin/knowledge 类） → 只出标题行无 bullets。
function renderProficiencyBlock(entry: ProficiencyEntry, locale: Locale): string {
  const headingLine = renderProficiencyHeading(entry, locale);
  const axis = craftForSkillId(entry.skillId);
  const reactions = axis ? getReactionsForCraft(axis) : [];
  if (reactions.length === 0) {
    return `### ${headingLine}`;
  }
  // 按难度升序：低难度在前 = "你能稳稳做的"先看到，认知顺序更自然。
  const sorted = [...reactions].sort((a, b) => a.difficulty - b.difficulty);
  const bullets = sorted.map((r) => `- ${renderReactionLine(r, locale)}`);
  return `### ${headingLine}\n${bullets.join("\n")}`;
}

function renderProficiencyHeading(entry: ProficiencyEntry, locale: Locale): string {
  const skillLabel = t(`prompt.context.proficiency.skill.${entry.skillId}`, locale);
  const tierKey = proficiencyTier(entry.value);
  const tierLabel = t(`prompt.context.proficiency.tier.${tierKey}`, locale);
  return t("prompt.context.proficiency.heading_format", locale, {
    skill: skillLabel,
    tier: tierLabel,
    value: String(Math.round(entry.value)),
  });
}

// 单条 reaction：sub_option 非空时用 sub_option（smith/assemble/woodwork 类）；
// 否则退回 reaction id（cook/mine/burn_charcoal 等无 sub_option 类的可读 id）。
function renderReactionLine(reaction: ReactionMeta, locale: Locale): string {
  const label = reaction.subOption.length > 0 ? reaction.subOption : reaction.id;
  return t("prompt.context.proficiency.reaction_line_format", locale, {
    label,
    difficulty: String(reaction.difficulty),
  });
}

export function renderInteractiveSitesSection(
  current: AgentCurrentContext,
  locale: Locale = getActiveLocale(),
): RenderedContextSection | undefined {
  if (current.interactiveSites.length === 0) return undefined;
  return {
    title: t("prompt.context.label.interactive_sites", locale),
    body: renderInteractiveSiteLines(current.interactiveSites, current, locale),
  };
}

function renderInteractiveSiteLines(
  sites: InteractiveSiteContext[],
  current: AgentCurrentContext,
  locale: Locale,
): string {
  const knownSkillIds = new Set(current.proficiency.map((p) => p.skillId));
  const directlyInteractable = sites.filter((site) => site.directlyInteractable);
  const requiresMove = sites.filter((site) => !site.directlyInteractable);
  return [
    `## ${t("prompt.context.interactive_site.direct_heading", locale)}`,
    renderNumberedLines(directlyInteractable.map((site) => renderInteractiveSiteLine(site, knownSkillIds, locale)), locale),
    "",
    `## ${t("prompt.context.interactive_site.move_heading", locale)}`,
    renderNumberedLines(requiresMove.map((site) => renderInteractiveSiteLine(site, knownSkillIds, locale)), locale),
  ].join("\n");
}

// 直接告诉 LLM 这里能调哪些 tool —— 不再写"工作台/容器/田"类别词或"制作/存取"模式词，
// 那是旧 use_workstation 时代的措辞，现在每个 craft 自带一个工具名。
//
// 格式：`{displayName}{ownerSuffix}：可使用：{tools}{slot}{lock/items}{inUse}`
//   - tools = workstation verbs 反查 craft 工具名（mine / smith 等），
//     不会的 craft 末尾挂"（你不会）"；NPC 看到 anvil 就知道它能用来 smith，但自己不会做
//   - 容器型（含晾架 / 水井）走 put_take / view_container
//   - 货架 / 田走 availableActions 直接当工具名
//   - noAccess：隐去 tools 行，仅显示招牌后缀；目前主要用于农田权限，工作台 owner_group
//     只作为归属/招牌信息，不作为硬使用门槛
function renderInteractiveSiteLine(
  site: InteractiveSiteContext,
  knownSkillIds: Set<string>,
  locale: Locale,
): string {
  const noAccess = site.accessible === false;
  const name = renderInteractiveSiteName(site, locale);
  const clauses = collectSiteClauses(site, knownSkillIds, noAccess, locale);
  const body = clauses.length > 0 ? `：${clauses.join("；")}` : "";
  return `${name}${body}`;
}

// 按 site 类型拼出 "可使用：xxx" / 锁 / 内容 / 占用 / summary 等子句，已剔除空串。
// noAccess 时不返回 tools 子句；容器仍保留 lock+items（属于内容感知）。
function collectSiteClauses(
  site: InteractiveSiteContext,
  knownSkillIds: Set<string>,
  noAccess: boolean,
  locale: Locale,
): string[] {
  if (site.kind === "farm" || site.kind === "shelf") {
    const tools = renderToolsClauseFromActions(site.availableActions, noAccess, locale);
    const summary = site.summary?.trim() ?? "";
    return [tools, summary].filter((c) => c.length > 0);
  }

  // kind === "workstation"
  if (site.interactionMode === "container") {
    // 容器型工作台（含晾架 / 国库）：存取走 put_take + view_container，永远 always-expose（无 skill 闸）。
    const tools = noAccess ? "" : `${t("prompt.context.workstation.tools_prefix", locale)}put_take / view_container`;
    const lock = site.locked
      ? t("prompt.context.workstation.lock_format", locale, { key: site.lockItemId ?? "?" })
      : t("prompt.context.workstation.lock_open", locale);
    const items = site.unlocked && site.items && site.items.length > 0
      ? t("prompt.context.workstation.items_format", locale, { items: site.items.map((i) => `[${i.index}] ${localizeText(i.itemId)}×${i.quantity}`).join(", ") })
      : site.locked && !site.unlocked
        ? t("prompt.context.workstation.items_locked", locale)
        : t("prompt.context.workstation.items_empty", locale);
    return [tools, lock, items].filter((c) => c.length > 0);
  }

  // craft / direct 工作台：verbs 反查 craft 工具名，按 NPC 是否有 skill 标"（你不会）"。
  // slot/inUse 跟 tools 同一子句（用全角逗号衔接），不会的也仍然显示——LLM 该知道占用状态。
  const tools = renderCraftToolsClause(site, knownSkillIds, noAccess, locale);
  const slot = site.slotCount != null
    ? t("prompt.context.workstation.slot_count_format", locale, { n: site.slotCount })
    : "";
  const inUse = site.currentOperatorName
    ? t("prompt.context.workstation.in_use_by_format", locale, { operator: site.currentOperatorName })
    : "";
  const head = `${tools}${slot}${inUse}`.replace(/^[，,；;]+/, "");
  return head ? [head] : [];
}

// workstation verbs → craft tool 名集合（去重保序）。
// 找不到 craft 映射的 verb 跳过——意味着该 workstation+verb 没在 crafts.json 登记。
function renderCraftToolsClause(
  site: InteractiveSiteContext,
  knownSkillIds: Set<string>,
  noAccess: boolean,
  locale: Locale,
): string {
  if (noAccess) return "";
  const wsId = site.workstationId ?? "";
  const seen = new Set<string>();
  const crafts: string[] = [];
  for (const verb of site.verbs ?? []) {
    const craft = craftForWorkstationVerb(wsId, verb);
    if (!craft || seen.has(craft)) continue;
    seen.add(craft);
    crafts.push(craft);
  }
  if (crafts.length === 0) return "";
  const cantSuffix = t("prompt.context.workstation.cant_use_suffix", locale);
  const rendered = crafts.map((slug) => {
    const skillId = skillIdForCraft(slug);
    const knows = skillId === "" || knownSkillIds.has(skillId);
    return knows ? slug : `${slug}${cantSuffix}`;
  }).join(" / ");
  return `${t("prompt.context.workstation.tools_prefix", locale)}${rendered}`;
}

// shelf / farm 直接用 availableActions 作为工具名（已经是 tool slug 形态：plan_farm_work /
// update_shelf / view_shelf / buy_from_shelf）；无 skill 闸，不挂"（你不会）"。
function renderToolsClauseFromActions(
  actions: string[],
  noAccess: boolean,
  locale: Locale,
): string {
  if (noAccess || actions.length === 0) return "";
  return `${t("prompt.context.workstation.tools_prefix", locale)}${actions.map(renderActionLabel).join(" / ")}`;
}

function renderNumberedLines(lines: string[], locale: Locale): string {
  if (lines.length === 0) return t("prompt.context.distance_band_none", locale);
  return lines.map((line, index) => `${index + 1}. ${line}`).join("\n");
}

// 永远 expose 原始 tool 名（如 "plan_farm_work"）—— LLM 调 tool 时用的是这个名字，
// 翻译成中文（"农事规划"）会让 LLM 凭记忆猜 tool 名，引入歧义。
function renderActionLabel(action: string): string {
  return action;
}

function renderDistanceBandLines(
  value: DistanceBandContext,
  kind: "location" | "character" | "item",
  labels: { near: string; far: string } = { near: "near", far: "far" },
): string {
  const locale = getActiveLocale();
  const none = t("prompt.context.distance_band_none", locale);
  const sep = t("prompt.context.distance_band_separator", locale);
  return [
    t("prompt.context.distance_band_line_format", locale, { label: labels.near, values: value.near.length === 0 ? none : value.near.map((entry) => displayContextEntry(entry, kind)).join(sep) }),
    t("prompt.context.distance_band_line_format", locale, { label: labels.far, values: value.far.length === 0 ? none : value.far.map((entry) => displayContextEntry(entry, kind)).join(sep) }),
  ].join("\n");
}

function renderCharacterDistanceBandLines(
  value: CharacterDistanceBandContext,
  labels: { near: string; far: string } = { near: "near", far: "far" },
): string {
  const locale = getActiveLocale();
  const none = t("prompt.context.distance_band_none", locale);
  const sep = t("prompt.context.distance_band_separator", locale);
  return [
    t("prompt.context.distance_band_line_format", locale, {
      label: labels.near,
      values: value.near.length === 0 ? none : value.near.map((entry) => displayCharacterContextEntry(entry, locale)).join(sep),
    }),
    t("prompt.context.distance_band_line_format", locale, {
      label: labels.far,
      values: value.far.length === 0 ? none : value.far.map((entry) => displayCharacterContextEntry(entry, locale)).join(sep),
    }),
  ].join("\n");
}

function displayContextEntry(entry: string, kind: "location" | "character" | "item"): string {
  if (kind === "location") return locationName(entry);
  if (kind === "character") return characterName(entry);
  return localizeText(entry);
}

function displayCharacterContextEntry(entry: CharacterContextEntry, locale: Locale): string {
  const name = characterName(entry.id);
  const label = formatCharacterStatusLabel(entry.status, locale);
  if (!label) return name;
  return `${name}（${label}）`;
}

function formatCharacterStatusLabel(
  status: CharacterContextEntry["status"],
  locale: Locale,
): string {
  if (!status) return "";
  switch (status.kind) {
    case "sleeping":
      return t("prompt.context.character_status.sleeping", locale);
    case "dead":
      return t("prompt.context.character_status.dead", locale);
    case "using_workstation":
      return t("prompt.context.character_status.using_workstation_format", locale, { place: status.place });
    case "working_at_farm":
      return t("prompt.context.character_status.working_at_farm_format", locale, { place: status.place });
    case "anim": {
      // 旧行为：未在 i18n catalog 注册的 animState（"walking" / "crafting"…）退回 localizeText。
      const i18nKey = `prompt.context.character_status.${status.state}`;
      const translated = t(i18nKey, locale);
      return translated !== i18nKey ? translated : localizeText(status.state);
    }
  }
}

// 城镇地图：静态全城地点总览，给 LLM 全局意识 + move_to_location 的合法目的地名单。
// 纯数据驱动——结构（zone + children）读 backend/data/town/locations.json，文案（介绍/方位/
// 限制）读 i18n catalog；本函数只负责"读数据→按区分组→拼 markdown"，零硬编码文案。
// 同一份内容对所有 NPC 一致，故挂在 system prompt（稳定可缓存），不随 turn 变。
// 设计见 [[project_town_map_zones]]。返回 undefined 表示无任何带 zone 的地点（不送空段）。
//
// 子地点（农田 / 集市摊位 / 作坊工具）不靠 DB 父子关系推导——通用工作台（forge/stove…）
// 跨铺子合并成单一逻辑地点，无法归属某栋建筑，故在 locations.json 的 children 里显式编排。
const TOWN_MAP_ZONE_ORDER = ["upper_city", "lower_city", "outer_city", "castle", "south_outskirts", "public"] as const;

export function renderTownMap(locale: Locale = getActiveLocale()): string | undefined {
  const descriptors = locationDescriptors();
  const byZone = new Map<string, string[]>();
  for (const [id, descriptor] of Object.entries(descriptors)) {
    if (!descriptor.zone) continue;
    const list = byZone.get(descriptor.zone) ?? [];
    list.push(id);
    byZone.set(descriptor.zone, list);
  }
  const zoneBlocks: string[] = [];
  for (const zone of TOWN_MAP_ZONE_ORDER) {
    const ids = byZone.get(zone);
    if (!ids || ids.length === 0) continue;
    const lines: string[] = [`## ${t(`prompt.context.townmap.zone.${zone}`, locale)}`];
    const intro = optionalCatalog(`prompt.context.townmap.zone_intro.${zone}`, locale);
    if (intro) lines.push(`> ${intro}`);
    for (const id of ids) lines.push(renderTownMapLocation(id, descriptors[id], descriptors, locale));
    zoneBlocks.push(lines.join("\n"));
  }
  if (zoneBlocks.length === 0) return undefined;
  const intro = optionalCatalog("prompt.context.townmap.intro", locale);
  return [intro, zoneBlocks.join("\n\n")].filter(Boolean).join("\n\n");
}

function renderTownMapLocation(
  id: string,
  descriptor: LocationDescriptor,
  descriptors: Record<string, LocationDescriptor>,
  locale: Locale,
): string {
  const dir = locationDirection(id, locale);
  let head = `- **${locationName(id, undefined, locale)}**`;
  if (dir) head += `（${dir}）`;
  const body = [locationDescription(id, locale), locationAccess(id, locale)].filter(Boolean).join("");
  const headLine = body ? `${head}：${body}` : head;
  const childLines = renderTownMapChildren(descriptor.children ?? [], descriptors, locale);
  return childLines.length > 0 ? `${headLine}\n${childLines.join("\n")}` : headLine;
}

// 子节点行：解析每个 child 的名字 + 描述（在 locations.json 里 = 子地点，否则按 workstation 类型解析），
// 相邻且描述相同的折叠成一行（如三块农田 → 一行）。
function renderTownMapChildren(
  childIds: string[],
  descriptors: Record<string, LocationDescriptor>,
  locale: Locale,
): string[] {
  const resolved = childIds.map((cid) => {
    // 有主工作台组合 id "<def>@<group>"：名字走 locationName（拼成"铁砧（巴克利铁匠铺）"），
    // 描述按 def 取工作台描述。move_to_location 用这个完整名字。
    const at = cid.indexOf("@");
    if (at > 0) {
      return { name: locationName(cid, undefined, locale), desc: workstationDescription(cid.slice(0, at), locale) ?? "" };
    }
    const isLocation = Object.prototype.hasOwnProperty.call(descriptors, cid);
    const name = isLocation ? locationName(cid, undefined, locale) : workstationName(cid);
    const desc = (isLocation ? locationDescription(cid, locale) : workstationDescription(cid, locale)) ?? "";
    return { name, desc };
  });
  const out: string[] = [];
  let i = 0;
  while (i < resolved.length) {
    let j = i;
    while (j + 1 < resolved.length && resolved[j + 1].desc === resolved[i].desc) j++;
    const names = resolved.slice(i, j + 1).map((r) => `**${r.name}**`).join("、");
    const desc = resolved[i].desc;
    out.push(desc ? `  - ${names}：${desc}` : `  - ${names}`);
    i = j + 1;
  }
  return out;
}

function optionalCatalog(key: string, locale: Locale): string | undefined {
  const value = t(key, locale);
  return value === key ? undefined : value;
}

function renderLocationDistanceBandLines(
  value: DistanceBandContext,
  current: AgentCurrentContext,
  labels: { near: string; far: string } = { near: "near", far: "far" },
): string {
  const locale = getActiveLocale();
  const none = t("prompt.context.distance_band_none", locale);
  const sep = t("prompt.context.distance_band_separator", locale);
  return [
    t("prompt.context.distance_band_line_format", locale, { label: labels.near, values: value.near.length === 0 ? none : value.near.map((entry) => displayLocationContextEntry(entry, current)).join(sep) }),
    t("prompt.context.distance_band_line_format", locale, { label: labels.far, values: value.far.length === 0 ? none : value.far.map((entry) => displayLocationContextEntry(entry, current)).join(sep) }),
  ].join("\n");
}

// 地点 id → 显示名：统一走 locationName（已覆盖普通地点 / 组合工作台 / 工作台兜底）。
// 不再自己拼 fallback 链——历史上那套 + visibleLocation.alias override 会让组合 id
// 漏成原始串进 prompt。aliasOverride 仍传，但 locationName 会忽略等于 id 的脏值。
export function displayLocationContextEntry(entry: string, current: AgentCurrentContext): string {
  const override = current.visibleLocations.find((location) => location.id === entry)?.alias;
  return locationName(entry, override);
}
