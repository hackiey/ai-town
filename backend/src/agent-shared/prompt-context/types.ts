// Agent prompt 中"世界感知"部分的数据形状。Godot 端的 perception manifest
// 经 assemble-from-manifest 装配成 AgentCurrentContext + 周边数据，再由各 agent
// 选择哪些字段、按什么顺序渲染进自己的 prompt。
//
// 这些类型是 shared 的——所有 agent 看到同一份感知数据形状，避免在多个 agent
// 之间漂移。Memory 形状暂时也共享（v1 都按 self_knowledge/skill/other 分段），
// 后续如果有 agent 想换 memory 结构再 per-agent 化。

import type { ActionLogRecord, GameTimeSnapshot, WorldEventRecord } from "../../godot-link/protocol.js";

export type DistanceBandContext = {
  near: string[];
  far: string[];
};

// 旁人能直接看出来的"身体动作"。
// - sleeping / dead 是已存在的两条
// - using_workstation / working_at_farm 反查自 workstation_states/farm_states 的 currentOperatorId
// - anim 是 animState passthrough 兜底（"走动中"等），由 renderer 决定要不要翻译
export type CharacterPresenceStatus =
  | { kind: "sleeping" }
  | { kind: "dead" }
  | { kind: "using_workstation"; place: string }
  | { kind: "working_at_farm"; place: string }
  | { kind: "anim"; state: string };

export type CharacterContextEntry = {
  id: string;
  status?: CharacterPresenceStatus;
};

export type CharacterDistanceBandContext = {
  near: CharacterContextEntry[];
  far: CharacterContextEntry[];
};

export type VisibleLocationContext = {
  id: string;
  alias?: string;
  parentId?: string;
  depth: number;
  visibility?: string;
  childIds: string[];
};

export type FarmSlotContext = {
  index: number;
  slotName?: string;
  occupied: boolean;
  variety?: string;
  displayName?: string;
  stage?: string;
  stageDisplay?: string;
  moisture?: number;
  moisturePercent?: number;
  hasPest?: boolean;
  maturity?: number;
  ripe?: boolean;
  needsWater?: boolean;
  canHarvest?: boolean;
  needsPestControl?: boolean;
  statusTags?: string[];
  statusText?: string;
};

export type FarmContext = {
  id: string;
  locationId?: string;
  directlyInteractable?: boolean;
  // false = 看得见但没耕作权限（owner_group 不匹配）；undefined 兼容旧数据视作 true。
  accessible?: boolean;
  // 归属 group id（如 "hale_bakery"）；用于在 LLM-facing 描述里渲染招牌后缀
  // "（黑尔面包店）"。空/undefined = 公用。
  ownerGroup?: string;
  totalSlots?: number;
  occupiedSlots?: number;
  emptySlots?: number;
  ripeSlots?: number;
  pestSlots?: number;
  drySlots?: number;
  statusSummary?: string;
  slots: FarmSlotContext[];
};

export type WorkstationContext = {
  id: string;
  workstationId: string;
  displayName?: string;
  directlyInteractable?: boolean;
  // false = 看得见但没使用权限（owner_group 不匹配）；undefined 兼容旧数据视作 true。
  accessible?: boolean;
  // 归属 group id（如 "blacksmith_shop"）；用于在 LLM-facing 描述里渲染招牌后缀
  // "（巴克利铁匠铺）"。空/undefined = 公用。
  ownerGroup?: string;
  interactionMode?: string;
  verbs: string[];
  slotCount?: number;
  // 容器型 workstation (interactionMode="container") 专属：
  // - lockItemId：上锁 item id；空/缺省 = 未锁
  // - locked：lockItemId 非空时为 true
  // - unlocked：actor 是否能开（无锁 或 背包持锁匹配的钥匙）
  // - items：当前库存摘要（locked 且 actor 没钥匙时为空数组）
  lockItemId?: string;
  locked?: boolean;
  unlocked?: boolean;
  // 容器内容：每条带 index（LLM 看到的 [N]，与 itemIndex.containers[containerId] 对齐）+
  // slotIndex（item_instances 真 id，take/put 时走 wire 给 Godot）。quality 仅作展示。
  items?: Array<{ index: number; slotIndex: number; itemId: string; quantity: number; quality?: number }>;
  // 跨角色单占：非空 = 工作台正被该角色使用，他人调 use_workstation 会吃 workstation_busy。
  // 装配时已剔除"自己"——actor 自己用着的工作台不渲染"使用中"后缀。
  // 容器恒空（容器允许多人并发翻箱）。
  currentOperatorName?: string;
};

export type ShelfListingContext = {
  // index = LLM 看到的 [N] 序号（与 itemIndex.shelves[shelfId] 对齐）；
  // listingId = 货架 listing 表真 id，update/remove 走 wire 给 Godot。
  index?: number;
  listingId: string;
  slotIndex?: number;
  itemId?: string;
  displayName?: string;
  quantity: number;
  // priceCenti 是 DB 真值（int, 1 silver = 100 centi）；priceSilver = centi/100 是显示用 silver(float)。
  priceCenti: number;
  priceSilver: number;
  priceText?: string;
  quality?: number;
  qualityTier?: string;
  freshnessTier?: number;
  descriptionParts: string[];
};

export type ShelfContext = {
  id: string;
  locationId?: string;
  displayName?: string;
  directlyInteractable?: boolean;
  slotCount?: number;
  interactionRadiusMeters?: number;
  listings: ShelfListingContext[];
};

export type InteractiveSiteContext = {
  id: string;
  locationId?: string;
  displayName: string;
  kind: "farm" | "workstation" | "shelf";
  directlyInteractable: boolean;
  // false = 看得见但没权限（owner_group 不匹配）；undefined / true = 有权限。
  accessible?: boolean;
  // 归属 group id；non-empty 时渲染层会在 displayName 后追加招牌（如 "（巴克利铁匠铺）"），
  // 让"看得见但不归你用"成为世界叙述的一部分，不再需要 [无权限] 标签。
  ownerGroup?: string;
  availableActions: string[];
  summary?: string;
  verbs?: string[];
  workstationId?: string;
  interactionMode?: string;
  slotCount?: number;
  lockItemId?: string;
  locked?: boolean;
  unlocked?: boolean;
  // 容器内容：每条带 index（LLM 看到的 [N]，与 itemIndex.containers[containerId] 对齐）+
  // slotIndex（item_instances 真 id，take/put 时走 wire 给 Godot）。quality 仅作展示。
  items?: Array<{ index: number; slotIndex: number; itemId: string; quantity: number; quality?: number }>;
  // 跨角色单占。同 WorkstationContext.currentOperatorName：装配时已剔除自己，仅在被他人占用时填。
  currentOperatorName?: string;
};

// 单条 item index entry：把 LLM 看到的 [N] 序号反解回具体 stack 的真 primary key。
// item_instances 的 slotIndex 是 (townId, ownerKind, ownerId) 范围内的唯一槽位 id，
// 用作背包 / 装备 / 容器内 stack 的真 id 发给 Godot —— 不再用 quality 当辅助 id（quality
// 只是显示用的 aspect，多份同 (def, quality) 会在 inventory 合并成一行，仍然只对应一个 slotIndex）。
// 货架 listing 走 listingId。perception nearby items 当前没 instance id，只能落 itemDefId。
export type ItemIndexEntry = {
  itemDefId: string;
  slotIndex?: number;
  listingId?: string;
  // 液体容器装的内容 id（如 wood_bucket 里的 "water"）。resolver 在 name mismatch 时
  // 用这个兜底——LLM 写 {name:"水", index:<木桶>} 可以解析成 {id:"water", slotIndex:桶}，
  // 由 Godot 端做最终校验（桶里真有水、量够等）。空 / undefined = 不是液体容器或桶里空着。
  containerContent?: string;
};

// 每个"面向 LLM 的物品清单"各自一份 1-based 序号空间。tool resolver 按 (list, index)
// 反查到对应 entry。不暴露给 LLM，是 backend 内部 snapshot。
// containers / shelves 按 id 分子表（每个容器 / 货架自己 1 起编号）。
export type AgentItemIndexMaps = {
  backpack: ItemIndexEntry[];
  equipment: ItemIndexEntry[];
  nearby: ItemIndexEntry[];
  containers: Record<string, ItemIndexEntry[]>;
  shelves: Record<string, ItemIndexEntry[]>;
};

// 单条熟练度：(skillId, value 0-100)。assembler 已按 value DESC 排好序，renderer 直接用。
// 空数组 = 这个角色还没攒过任何手艺（生手），renderer 会渲染成"还是个生手"占位。
export type ProficiencyEntry = {
  skillId: string;
  value: number;
};

export type AgentCurrentContext = {
  currentLocation: string;
  gameTime?: GameTimeSnapshot;
  visibleLocations: VisibleLocationContext[];
  availableActions: string[];
  characterAttributes: string[];
  proficiency: ProficiencyEntry[];
  // 该角色所属 group id 列表（来自 manifest.characterGroupIds / SQLite character_groups）。
  // 用于按 group 做工具门控，例如 update_shelf 只给"管理着货架的 group"成员。
  groups: string[];
  nearbyBuildings: DistanceBandContext;
  nearbyCharacters: CharacterDistanceBandContext;
  nearbyItems: DistanceBandContext;
  nearbyFarms: FarmContext[];
  nearbyWorkstations: WorkstationContext[];
  nearbyShelves: ShelfContext[];
  ownedShelves: ShelfContext[];
  interactiveSites: InteractiveSiteContext[];
  inventory: string[];
  backpack: string[];
  itemIndex: AgentItemIndexMaps;
  walletCenti: number;
  lastUpdatedAt?: string;
};

export type AgentMemoryKind = "self_knowledge" | "skill" | "other";
export type StoredAgentMemoryKind = AgentMemoryKind | "profile" | "long_term" | "reflection";

export type AgentMemoryRecord = {
  id: string;
  townId: string;
  characterId: string;
  kind: StoredAgentMemoryKind;
  text: string;
  importance: number;
  createdAt: string;
  lastAccessedAt?: string;
  sourceEventIds?: string[];
};

export type PromptMemoryRecord = Omit<AgentMemoryRecord, "kind"> & {
  kind: AgentMemoryKind;
};

export type PromptMemorySections = {
  selfKnowledge: PromptMemoryRecord[];
  skills: PromptMemoryRecord[];
  other: PromptMemoryRecord[];
  all: PromptMemoryRecord[];
};

// Thinking 轨写、Action 轨读的"工作记忆"。Action 轨每个 turn 入口读最新一份塞进 context。
// 内容是 Thinking LLM 自己写给"另一个自己"的备忘文本，不带结构约束。
// 不是所有 agent 都用——only two-track 这类有 thinking 轨的会填。
export type WorkingMemorySnapshot = {
  content: string;
  updatedAt: string;
  gameTime?: GameTimeSnapshot;
  triggerReason?: string;
};

export type GameAgentContext = {
  townId: string;
  characterId: string;
  assembledAt: string;
  // 游戏时间单位，不是 wall-clock。分桶按事件 gameTime 与当前 current.gameTime 比较。
  recentEventWindowMinutes: number;
  relevantEventWindowHours: number;
  worldLore: string[];
  current: AgentCurrentContext;
  memory: PromptMemorySections;
  relevantEvents: WorldEventRecord[];
  pendingEvents: WorldEventRecord[];
  workingMemory?: WorkingMemorySnapshot;
  // 本角色近期 action_log（含 result.character_changes/产出/消耗/失败原因）。删 transcript 后
  // 自身动作的效果只剩在 action_log.result（world_event.data 不带），渲染时按类型+gameTime 合并进
  // 自身事件行，让 LLM 看得到"吃了面包→饱食+30"。见 renderer.renderEventTimeline。
  selfActionResults?: ActionLogRecord[];
};
