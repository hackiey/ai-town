// View 类型层：每个 repo SELECT 出来的领域对象。Naming 与 prompt/types.ts 里 renderer 已知的
// FarmContext / WorkstationContext 等保持一致——P4 拼 context 直接喂给 renderer，无需中间映射。

// npc_proficiency 一行：(skillId, value 0-100)。无行 = 生手（按 0 处理）。
export type ProficiencyRowView = {
  skillId: string;
  value: number;
};

export type CharacterStateView = {
  characterId: string;
  currentLocationId: string;
  position: { x: number; y: number; z: number };
  animState: string;
  hp: number;
  maxHp: number;
  stamina: number;
  // maxStamina 是静态 export 上限；effective_stamina_max（hunger/rest 压低后的"当下可达"）
  // 不持久化，prompt 想要"当下可达"时让 Godot 单独算并送过来即可。
  maxStamina: number;
  hunger: number;
  maxHunger: number;
  rest: number;
  maxRest: number;
  // 损伤层：drunk 醉酒 / sickness 生病累计值（0..100）。0 = 清醒健康。
  drunk: number;
  sickness: number;
  // 档位 key（Godot 单一写者算好持久化）：drunk ""/tipsy/drunk/wasted；sickness ""/mild/moderate/severe。
  // backend 只读这个 key 渲染，不在 TS 里复制阈值。见 docs/architecture/impairment-system.md §2。
  drunkTier: string;
  sicknessTier: string;
  sleepNeededHours: number;
  temperature: number;
  burning: boolean;
  alive: boolean;
  equipped: {
    rightHand: string;
    leftHand: string;
    body: string;
    head: string;
  };
  activeStatuses: unknown[];
  // Wallet 余额，centi 单位（1 silver = 100 centi）。silver_coin / gold_coin 不在 inventory
  // 里，而是直接进 wallet。给 LLM 看时 / 100 转 silver 小数。
  walletCenti: number;
};

export type CharacterPresenceView = {
  characterId: string;
  animState: string;
  hp: number;
  hunger: number;
  alive: boolean;
  // 显式投影 sleeping 这条 status 给 prompt 渲染。其他 status（hungry/burning...）
  // 都是私密体验，旁人在邻近列表里看不到；只有 sleeping 是肉眼可辨。
  isSleeping: boolean;
  // "当下在做什么"——由 Godot 各 action runner 在 enter/exit 时写 character_states 两列。
  // kind 是 slug 枚举（using_workstation / working_at_farm / ...），target 是关联实体的 slug
  // （workstation_def_id / farm_id / ...）。两列都空 = 没在做特殊动作。
  currentActivityKind?: string;
  currentActivityTarget?: string;
};

// item_instances typed-column 投影。所有"涌现身份 + 可变 aspect"字段都按 Godot
// schema（src/autoload/db.gd item_instances）逐列读出；JSON 列由 repo 安全解析。
// - shapeType / tags / materials / physicsProps：reaction generate 时冻结，不可变
// - container / freshness / durability：可变 aspect，对应列为 NULL = 此物没该 aspect
// - baseEffects：reaction generate 时写入的"基础效果"dict（hunger/stamina/...）
// - displayedEffects：Godot 已按 quality × freshness 算好的"展示效果"dict
export type ItemInstanceAspects = {
  shapeType: string;
  tags: string[];
  materials: Record<string, string>;
  physicsProps?: Record<string, unknown>;
  container?: { amount: number; content: string | null; fermenting?: boolean; ceiling?: number };
  freshness?: { tier: number; ageHours: number | null };
  durability?: number;
  baseEffects?: Record<string, number>;
  displayedEffects?: Record<string, number>;
};

export type InventoryItemRow = {
  slotIndex: number;
  itemDefId: string;
  stackCount: number;
  quality?: number;
  // 货架陈列标价（centi 银）。仅货架槽位有；普通容器/背包为 undefined。仅展示，付钱靠 trade/give。
  listingPriceCenti?: number;
} & ItemInstanceAspects;

// displayName 不存 sqlite 也不在 view 里——所有 entity 的显示名 source-of-truth
// 是 data/i18n/<locale>/*.json catalogs。需要名字时调 DisplayNameResolver.<kind>(id)。
export type WorkstationView = {
  workstationNodeId: string;
  workstationDefId: string;
  locationId?: string;
  ownerGroup?: string;
  position: { x: number; y: number; z: number };
  interactionMode?: string;
  slotCount: number;
  verbs: string[];
  currentOperatorId?: string;
  currentVerb?: string;
  busy: boolean;
};

export type ContainerView = {
  containerId: string;
  lockItemId?: string;
  ownerGroup?: string;
  slotCount: number;
  interactionRadius: number;
  position: { x: number; y: number; z: number };
  // 内容（item_instances ownerKind='container'）的轻量摘要：只给 LLM 看 id+qty 列表
  contents: InventoryItemRow[];
};

// 场景里 ShelfNode 的静态镜像（shelves 表一行）。货架已统一为无锁容器，内容物走
// item_instances(ownerKind='container', ownerId=shelfId)，标价在槽位 listingPriceCenti。
// shelves 表只是"这个容器是货架"的标记 + 命名来源（locationId）。
export type ShelfView = {
  shelfId: string;
  ownerGroup?: string;
  locationId?: string;
  slotCount: number;
  interactionRadius: number;
  position: { x: number; y: number; z: number };
  // 货架内容（item_instances ownerKind='container'），由 shelf-repo 一并查出。
  contents: InventoryItemRow[];
};

export type LocationMarkerView = {
  locationId: string;
  parentLocationId?: string;
  ownerGroup?: string;
  position: { x: number; y: number; z: number };
  isWorkstation: boolean;
};

export type FarmPlotView = {
  plotIndex: number;
  varietyId?: string;
  spawnedAtGameHour: number;
  // stage = generic id（seed/sprout/vegetative/flowering/ripe），由 Godot 算并写盘。
  // backend 不再持有公式，直接读字段；显示名走 i18n catalog 的 prompt.context.crop_stage.*。
  stage?: string;
  careScoreSum: number;
  careScoreCount: number;
  harvestsDone: number;
  hasPest: boolean;
};

export type FarmView = {
  farmId: string;
  // locationId / totalSlots 由 TownWorld._seed_farm_static_to_db boot 时全量写入。
  // locationId 指向 location_markers.locationId，name resolver 直接命中拿 displayName。
  // totalSlots = scene 里 FarmSlot 子节点总数（farm_plots 只记被种过的格，不能当总格数）。
  locationId: string;
  // 农田归属：从 farm.locationId 关联的 location_markers.ownerGroup 取（farm-repo LEFT JOIN 拼出）。
  // 真值在 Godot 场景树 LocationMarker.owner_group 继承链（town_world.gd _resolve_owner_group）。
  // 空字符串/undefined = 公用。
  ownerGroup?: string;
  totalSlots: number;
  moisture: number;
  pestCountToday: number;
  lastProcessedDay: number;
  plots: FarmPlotView[];
};

export type TradeLine = {
  item: string;
  count: number;
};

export type TradeOfferView = {
  tradeId: string;
  fromCharacterId: string;
  toCharacterId: string;
  offer: TradeLine[];
  request: TradeLine[];
  shelfListingIds: string[];
  requestedShelfItems: unknown[];
  status: string;
  createdAt: string;
  updatedAt: string;
  respondedAt?: string;
};
