import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Dict<T> = Record<string, T>;

type Item = {
  id: string;
  name: string;
  kind: string;
  shapeType: string;
  materials: Dict<string>;
  tags: string[];
  cropVarietyId: string;
  hunger: number;
  stamina: number;
  shelfLifeHours: number;
  sourcePath: string;
};

type Material = {
  id: string;
  name: string;
  category: string;
  transforms: Dict<string>;
  alloys: Dict<string>;
  tags: string[];
  shelfLifeHours: number;
};

type CropVariety = {
  id: string;
  name: string;
  maturationHours: number;
  harvestYieldId: string;
  harvestYieldQuantity: number;
};

type InputPredicate = {
  itemId?: string;
  shapeType?: string;
  bodyMaterial?: string;
  bodyCategory?: string;
  tags: string[];
  tool: boolean;
};

type OutputSpec = {
  itemId?: string;
  shapeType?: string;
  bodyMaterial?: string;
  qty: number;
};

type Reaction = {
  id: string;
  verb: string;
  workstation: string;
  subOption: string;
  materialStrategy: string;
  difficulty: number;
  staminaCost: number;
  durationSeconds: number;
  inputs: InputPredicate[];
  outputs: OutputSpec[];
  primaryInputIndices: number[];
  sourcePath: string;
};

type Recipe = {
  id: string;
  reactionId: string;
  workstation: string;
  outputItemId: string;
  outputQty: number;
  inputItemIds: string[];
  requirementItemIds: string[];
  durationSeconds: number;
  staminaCost: number;
  difficulty: number;
};

type Price = {
  itemId: string;
  value: number;
  source: string;
  cost: number;
  labor: number;
  margin: number;
};

type ItemFlow = {
  supply: number;
  demand: number;
  notes: string[];
};

type NpcDefinition = {
  name: string;
  age: number;
  skills: string[];
  other: string[];
  groups: string[];
};

type RuntimeWagePolicy = {
  minerIds: string[];
  oreRates: Dict<number>;
  weeklyRoles: Dict<{ weekday: number; amount: number }>;
};

type Catalog = {
  labels: { items: Dict<string>; materials: Dict<string> };
  materials: Map<string, Material>;
  items: Map<string, Item>;
  crops: Map<string, CropVariety>;
  reactions: Reaction[];
  recipes: Recipe[];
  farmSlots: Dict<number>;
  workstationCounts: Dict<number>;
  // group_id → 组内 NPC id 列表，来自 npcs.json 每个 NPC 的 groups[] 反向聚合。
  groupMembers: Map<string, string[]>;
  // group_id → list of location 节点名（来自 town.tscn LocationMarker.owner_group 继承解析）。
  // Godot 场景树是真值（src/world/town_world.gd _resolve_owner_group），这里离线复刻一遍。
  groupToLocations: Map<string, string[]>;
  npcs: Map<string, NpcDefinition>;
  mineTargets: Dict<number>;
  runtimeWages: RuntimeWagePolicy;
};

type FoodPlanRow = {
  group: string;
  itemId: string;
  itemName: string;
  hungerShare: number;
  targetHunger: number;
  hungerPerItem: number;
  targetQty: number;
  suppliedQty: number;
  gapQty: number;
};

type CropPlanRow = {
  cropId: string;
  itemId: string;
  itemName: string;
  requestedQty: number;
  suppliedQty: number;
  perSlotPerDay: number;
  slotsNeeded: number;
  slotsAllocated: number;
  slotShare: number;
};

type WorkOrder = {
  reactionId: string;
  sectorId: string;
  workstation: string;
  outputItemId: string;
  outputQty: number;
  actions: number;
  requiredHours: number;
  requiredStamina: number;
};

type ActivityDemand = {
  sectorId: string;
  activity: string;
  workerCount: number;
  requiredHours: number;
  requiredStamina: number;
  source: string;
};

type ToolPlanRow = {
  itemId: string;
  itemName: string;
  activity: string;
  activeUsers: number;
  wearPerUserPerDay: number;
  dailyWear: number;
  payerSectors: string;
  craftable: boolean;
};

type LivestockPlanRow = {
  itemId: string;
  itemName: string;
  outputQty: number;
  feedItemId: string;
  feedQty: number;
};

type MinePlanRow = {
  mineId: string;
  itemId: string;
  itemName: string;
  targetQty: number;
  outputQty: number;
  workerIds: string[];
  wageRate: number;
  wageTotal: number;
};

type WageRow = {
  recipientId: string;
  recipientName: string;
  role: string;
  payerGroupId: string;
  payerSectorId?: string;
  silverPerDay: number;
  source: string;
  status: string;
};

type SectorConfig = {
  id: string;
  name: string;
  groupId: string;
  workerIds: string[];
  plannedWorkers?: number;
  productItemIds: string[];
  taxRate: number;
  rentPerDay: number;
  spoilageRate: number;
  revenueMode?: "market" | "asset_supply" | "none";
};

type SectorCashRow = {
  sectorId: string;
  sectorName: string;
  groupId: string;
  revenue: number;
  materialCost: number;
  wageCost: number;
  ownerLaborDraw: number;
  taxRent: number;
  spoilageCost: number;
  retained: number;
  capture: number;
  notes: string;
};

type GroupCashRow = {
  groupId: string;
  members: number;
  businessRetained: number;
  ownerLaborDraw: number;
  wagesReceived: number;
  taxRentReceived: number;
  directPayrollPaid: number;
  totalCapture: number;
  captureShare: number;
  notes: string;
};

type ReactionCapacityRow = {
  reactionId: string;
  sectorId: string;
  workstation: string;
  stationCount: number;
  requiredOutput: number;
  timeCapacity: number;
  staminaCapacity: number;
  status: string;
};

type SectorLaborRow = {
  sectorId: string;
  sectorName: string;
  workers: number;
  requiredHours: number;
  availableHours: number;
  requiredStamina: number;
  availableStamina: number;
  laborValue: number;
  status: string;
  sources: string;
};

type ModelState = {
  flows: Map<string, ItemFlow>;
  supplyBySector: Map<string, Dict<number>>;
  demandBySector: Map<string, Dict<number>>;
  workOrders: WorkOrder[];
  activityDemands: ActivityDemand[];
};

type EconomyModel = {
  npcCount: number;
  prices: Map<string, Price>;
  state: ModelState;
  foodRows: FoodPlanRow[];
  cropRows: CropPlanRow[];
  toolRows: ToolPlanRow[];
  livestockRows: LivestockPlanRow[];
  mineRows: MinePlanRow[];
  wageRows: WageRow[];
  sectorRows: SectorCashRow[];
  groupRows: GroupCashRow[];
  reactionCapacityRows: ReactionCapacityRow[];
  sectorLaborRows: SectorLaborRow[];
  risks: string[];
};

const __dirname = dirname(fileURLToPath(import.meta.url));
const backendRoot = resolve(__dirname, "../..");
const projectRoot = resolve(backendRoot, "..");

// 设计契约：所有数值围绕这些不变量调。报告里会逐条 pass/fail。
// 改 anchor / margin / wage 时回头看这些是否仍 green；不 green 说明设计本身矛盾，得调结构（产能、recipe、契约本身）。
const CONTRACTS = {
  // I1: 卫兵日薪能买 4 份主食 + 1 份生肉（家庭基本伙食）
  i1_guard_daily_food: {
    breadCount: 4,
    rawMeatCount: 1,
    description: "guard daily wage covers 4 bread + 1 raw_meat",
  },
  // I2: 一把铁工具 ≈ 卫兵 1 天工资（攒一天就能买）
  i2_iron_tool_vs_wage: {
    minMultiplier: 0.8,
    maxMultiplier: 1.2,
    toolItemIds: ["iron_axe", "iron_pick", "iron_shovel"],
    description: "iron axe/pick/shovel ∈ [0.8, 1.2] × guard daily wage",
  },
  // I3: 单 NPC 日食物总开销占卫兵日薪 30-40%（中世纪农经济风味）
  i3_food_share: {
    minRatio: 0.30,
    maxRatio: 0.40,
    description: "NPC daily food basket / guard daily wage ∈ [30%, 40%]",
  },
  // I4: 国库净流可正可负，但不能崩盘。当前接受盈余（预留给后续守卫装备采购、公共工程等支出）。
  i4_treasury_balance: {
    minRatio: -0.10,
    maxRatio: 0.40,
    description: "treasury weekly net / expense ∈ [-10%, +40%] (surplus reserved for guard equipment / civil works)",
  },
  // I5: 没有 sector 实际买卖亏损（排除 owner_labor，因为自雇劳动是收入不是成本）。
  //   formula: (revenue - materials - fixed_wages - spoilage - tax_rent) / revenue ≥ -10%
  i5_sector_retained: {
    minRetainedRatio: -0.10,
    description: "every sector with revenue > 0: (revenue − materials − wages − spoilage − tax) / revenue ≥ -10%",
  },
};

// npcs.json 周薪真值表（loadRuntimeWagePolicy 解析的 GD 常量已删，这里直接维护）。
// 改 npcs.json 工资后必须同步这里，否则契约 I1/I2/I3 检查会对错的工资。
// 见 memory [[project-wage-rates-in-npcs-json]]。
const NPC_WEEKLY_WAGES: Dict<{ silverPerWeek: number; role: string; payerGroupId: string }> = {
  magda_kerr:    { silverPerWeek: 105, role: "treasurer",            payerGroupId: "royal_treasury" },
  keir_march:    { silverPerWeek:  84, role: "guard captain",        payerGroupId: "royal_treasury" },
  merek_gate:    { silverPerWeek:  84, role: "guard lieutenant",     payerGroupId: "royal_treasury" },
  sona_ward:     { silverPerWeek:  70, role: "town guard",           payerGroupId: "royal_treasury" },
  garret_pell:   { silverPerWeek:  70, role: "town guard",           payerGroupId: "royal_treasury" },
  iva_stone:     { silverPerWeek:  70, role: "town guard",           payerGroupId: "royal_treasury" },
  brenna_vail:   { silverPerWeek:  70, role: "soldier",              payerGroupId: "royal_treasury" },
  rolan_teague:  { silverPerWeek:  70, role: "soldier",              payerGroupId: "royal_treasury" },
  oswin_locke:   { silverPerWeek:  70, role: "soldier",              payerGroupId: "royal_treasury" },
};

// 矿石→银币 rate (在 npcs.json prompts 里硬编码，这里维护 mirror)。
const ORE_RATES: Dict<number> = {
  silver_ore: 0.5,
  gold_ore:   1.0,
};

const GUARD_REPRESENTATIVE_ID = "sona_ward"; // 普通卫兵作为 I1/I2/I3 的基准

const ECONOMY = {
  // 真值: physiology.lua hunger_decay_awake 5.0/hr + hunger_decay_sleep 1.25/hr → 16×5 + 8×1.25 = 90/天
  npcDailyHunger: 90,
  // 市场食物消费占比。town.tscn 中只有 5 个 stove：bakery / tavern / 3 自给户 (north_wall_wheat_plot / greystone_farmstead / millward_mill)。
  // 自给户 12 人 = 3 个 vale + 4 个 rowan + 3 个 millward + 2 个 tavern。其余 38/50 NPC 靠 bakery/tavern 供餐。
  marketCustomerFraction: 38 / 50,
  foodSafetyFactor: 1.0,
  facilityHoursPerDay: 8,
  workerStaminaBudgetPerDay: 180,
  laborSilverPerGameHour: 2.5,
  minimumCraftLaborSilver: 0.1,
  cropCareYieldMultiplier: 0.8,
  farmUtilization: 0.65,
  cropSeedReserveRate: 0.1,
  farmSlotRentSilverPerWeek: 1,
  farmRentExemptGroupIds: ["saint_bell_chapel"],
  daysPerWeek: 7,
  farmLaborHoursPerSlotDay: 0.035,
  farmLaborStaminaPerSlotDay: 0.65,
  livestockLaborHoursPerUnit: 0.04,
  livestockLaborStaminaPerUnit: 1.8,
  producerLabor: {
    wood: { sectorId: "lumberyard", hoursPerUnit: 0.167, staminaPerUnit: 6.0 },
    charcoal: { sectorId: "blacksmith_shop", hoursPerUnit: 0.06, staminaPerUnit: 2.4 },
    iron_ore: { sectorId: "iron_mining", hoursPerUnit: 0.333, staminaPerUnit: 12.0 },
  } satisfies Dict<{ sectorId: string; hoursPerUnit: number; staminaPerUnit: number }>,
  producerInputs: {
    charcoal: { wood: 1.4 },
  } as Dict<Dict<number>>,
  foodPlan: [
    // 食物 = kind="food" 的 item（带 base_effects.hunger）。flour/raw_meat/egg 都是 kind="material" 不能直接吃。
    // 主食是 bread（hunger=30）：每人 3 块 / 天 ≈ 填满 90 hunger。
    // 其他菜是辅食，提供变化。householdFuel 全删 —— 每个熟食 recipe 已含 1 fuel input，烹饪燃料自然由 recipe 驱动。
    { group: "staple_bread", itemId: "bread", hungerShare: 0.70, fallbackHunger: 30 },
    { group: "meat_dish", itemId: "cooked_meat", hungerShare: 0.10, fallbackHunger: 22 },
    { group: "egg_dish", itemId: "omelet", hungerShare: 0.05, fallbackHunger: 20 },
    { group: "produce_raw", itemId: "tomato_fruit", hungerShare: 0.05, fallbackHunger: 10 },
    { group: "vegetable_stew", itemId: "veg_stew", hungerShare: 0.05, fallbackHunger: 25 },
    { group: "preserved", itemId: "cured_meat", hungerShare: 0.05, fallbackHunger: 30 },
  ] satisfies Array<{ group: string; itemId: string; hungerShare: number; fallbackHunger: number }>,
  livestockFeed: {
    raw_meat: { itemId: "wheat", qtyPerUnit: 1.0 },
    egg: { itemId: "wheat", qtyPerUnit: 0.3 },
  } satisfies Dict<{ itemId: string; qtyPerUnit: number }>,
  livestockMinimumDailySupply: {
    raw_meat: 12,
    egg: 10,
  } as Dict<number>,
  cropMinimumDailyTargets: {
    wheat: 85,
    tomato: 25,
    flax: 15,
  } as Dict<number>,
  productionTools: [
    { itemId: "iron_pick", activity: "mining", activeUsersKey: "miners", wearPerUserPerDay: 0.10, payerWeights: { royal_mines: 3, iron_mining: 1 } },
    { itemId: "iron_shovel", activity: "farming", activeUsersKey: "farmers", wearPerUserPerDay: 0.05, payerWeights: { primary_agriculture: 1 } },
    { itemId: "sickle", activity: "harvesting", activeUsersKey: "farmers", wearPerUserPerDay: 0.03, payerWeights: { primary_agriculture: 1 } },
    { itemId: "iron_axe", activity: "lumber", activeUsersKey: "lumberjacks", wearPerUserPerDay: 0.25, payerWeights: { lumberyard: 1 } },
  ],
  // 燃料消耗已经在 recipe inputs 里捕获了（每个 bake/mix/smelt 都有 {tags={"fuel"}} 输入 = 1 charcoal/wood）。
  // 这里清空，避免双算。Charcoal/wood 的总需求由 recipe input 自然驱动。
  recipeOverheads: {} as Dict<Dict<number>>,
  // 原料 designed supply（绕过 recipe planner 直接 push 进 sector 的供给）。
  // charcoal 不放这里——让 kiln_burn recipe 在 blacksmith_shop / forge_yard 按需求自动 plan。
  // wood_ash 是 kiln 副产物，归到铁匠铺（他们烧炭）。
  // 真值校准 (2026-05-27)：以前数字按"工人满产理论值"，远超实际下游需求；
  // 改为对齐 recipe demand + household 简化估算，避免模型显示"米勒磨空气"。
  producerSupply: {
    wood: { sectorId: "lumberyard", qty: 15 },
    iron_ore: { sectorId: "iron_mining", qty: 2 },
    wood_ash: { sectorId: "blacksmith_shop", qty: 2 },
  } satisfies Dict<{ sectorId: string; qty: number }>,
  wellWaterPerWellDay: 120,
  mineWorkers: {
    gold_mine: ["tomas_pike"],
    silver_mine: ["harlan_dunn", "wilf_drake"],
  } as Dict<string[]>,
  mineOutputItems: {
    gold_mine: "gold_ore",
    silver_mine: "silver_ore",
  } as Dict<string>,
  mineWageRates: {
    gold_ore: 2,
    silver_ore: 1,
  } as Dict<number>,
  apprenticeWages: [
    { recipientId: "tilda_sparks", role: "smith apprentice stipend", payerGroupId: "blacksmith_shop", payerSectorId: "blacksmith_shop", silverPerDay: 10, source: "design: apprentice cash stipend" },
    { recipientId: "pella_moss", role: "herbal apprentice stipend", payerGroupId: "saint_bell_chapel", silverPerDay: 6, source: "design: clergy apprentice stipend" },
    { recipientId: "niko_vale", role: "farm family apprentice", payerGroupId: "north_wall_wheat_plot", silverPerDay: 0, source: "design: family labor share, not cash wage" },
    { recipientId: "lysa_rowan", role: "farm family junior worker", payerGroupId: "greystone_farmstead", silverPerDay: 0, source: "design: household member share, not cash wage" },
  ],
  // 用户指定的锚价（2026-05-27）：
  //   wheat 0.5 / flour 0.75 / bread 1.5
  //   wood 0.5 / iron_ore 2 / salt 0.5 / flax_bundle 0.5
  //   silver_ore 5 / gold_ore 10 (fixed)
  //   肉类 (raw_meat / egg) 暂不参与定价；给低占位值让 model 能跑。
  // 其他全部由 recipe + 体力时长 + margin 推导。
  basePrices: {
    water: 0,
    silver_coin: 1,
    gold_coin: 10,
    // ─── 原料锚 (¼ 银网格) ───
    wheat: 0.5,
    flour: 0.75,
    wood: 0.5,
    charcoal: 0.25,       // 1 wood → 4 charcoal，¼ 银/份与 NPC memory 对齐
    iron_ore: 2,
    salt: 0.5,
    flax_bundle: 0.5,
    malt: 1.0,            // 小麦晾晒制麦，¼ 银网格
    raw_meat: 2,
    egg: 0.5,
    berry: 0.25,
    stone: 0.1,
    wood_ash: 0.1,
    tomato_seed: 0.25,
    flax_seed: 0.25,
    mint_seed: 0.25,
    mugwort_seed: 0.25,
    ginger_seed: 0.5,
    plantain_seed: 0.25,
    calendula_seed: 0.5,
    valerian_seed: 0.5,
    mint_leaf: 0.4,
    mugwort_leaf: 0.4,
    ginger_root: 0.75,
    plantain_leaf: 0.4,
    calendula_flower: 0.75,
    valerian_root: 0.75,
    copper_ore: 2,
    tin_ore: 2,
    wood_bucket: 2,
    silver_ore: 5,
    gold_ore: 10,
    // ─── 零售食品锚 (¼ 银网格) ───
    bread: 1.5,           // 30 hunger 主食
    cooked_meat: 3.25,    // 22 hunger
    cured_meat: 4.0,      // 30 hunger 顶 cap，最贵保存品
    omelet: 1.5,          // 20 hunger
    cured_omelet: 2.0,    // 24 hunger
    veg_stew: 1.25,       // 25 hunger
    cured_stew: 2.0,      // 28 hunger
    berry_jam: 1.25,      // 15 hunger
    tomato_fruit: 0.5,    // 10 hunger
    beer: 1.0,            // 麦芽酒按杯零售：1 麦芽≈2 份 beer，单份不高于 1 银
    herbal_remedy: 2.0,   // 通用草药茶，弱缓解
    mint_mugwort_tea: 3.5,
    ginger_plantain_broth: 3.5,
    calendula_salve: 4.0,
    valerian_tonic: 4.0,
  } as Dict<number>,
  // 所有锚都 fixed，recipe 推导不覆盖。
  fixedPriceItems: [
    "silver_coin", "gold_coin", "silver_ore", "gold_ore",
    "wheat", "flour", "bread", "wood", "charcoal", "iron_ore", "salt", "flax_bundle",
    "raw_meat", "egg", "berry", "tomato_fruit", "malt", "beer", "herbal_remedy",
    "mint_seed", "mugwort_seed", "ginger_seed", "plantain_seed", "calendula_seed", "valerian_seed",
    "mint_leaf", "mugwort_leaf", "ginger_root", "plantain_leaf", "calendula_flower", "valerian_root",
    "mint_mugwort_tea", "ginger_plantain_broth", "calendula_salve", "valerian_tonic",
    "cooked_meat", "cured_meat", "omelet", "cured_omelet", "veg_stew", "cured_stew", "berry_jam",
  ],
  defaultMargin: 0.18,
  wealthRiskGroupShare: 0.2,
  wealthRiskSectorShare: 0.3,
  // share-based ownership 已无意义——每个 sector 现在直接对应单一 groupId（hale_bakery → hale_bakery 等）。
  // 这两个表保留为空，sectorRows 直接通过 groupId 归集，不再走 share 二次分配。
  bakeryGroups: [
    { groupId: "hale_bakery", share: 1 },
  ],
  millingGroups: [
    { groupId: "millward_mill", share: 1 },
  ],
};

// 真值依据：backend/data/town/npcs.json 每个 NPC 的 groups[] + starting_inventory + other[] 描述。
// 关键修正 (2026-05-27)：
//   - 加 forge_yard：第二个铁工铺 (Garr Hollow + Edda Vance)，跟 blacksmith_shop 并列
//   - 加 general_store：Cora Reed 独立卖绳 + 亚麻束/种 (从 tool_materials 拆出)
//   - 加 butcher：Hugh Marrow 屠夫转卖 raw_meat (从 livestock 拆出)
//   - 加 chapel_agriculture：圣钟草药园种草药，教会地免田租
//   - lumberyard 只卖 wood / shaft / plank，不再卖 charcoal / rope (charcoal 归铁工，rope 归 general_store)
//   - blacksmith_shop / forge_yard 都列出 charcoal 作为产品（自烧自卖）
//   - tavern / saltworks 实际有产
//   - inn 现在归为 import buffer，cured_stew 标记进口缓冲
const SECTORS: SectorConfig[] = [
  // 农业：3 个田主 group + 2 个教会 group + general_store 种亚麻。primary_agriculture 是"汇总虚拟 sector"用来对接田租计算。
  { id: "primary_agriculture", name: "primary agriculture", groupId: "farm_groups", workerIds: [], productItemIds: ["wheat", "tomato_fruit"], taxRate: 0, rentPerDay: 0, spoilageRate: 0.04 },
  // 磨坊
  { id: "milling", name: "milling", groupId: "millward_mill", workerIds: ["jonas_millward", "rudi_tate", "selma_millward"], productItemIds: ["flour"], taxRate: 0.08, rentPerDay: 4, spoilageRate: 0.01 },
  // 面包房
  { id: "hale_bakery", name: "hale_bakery", groupId: "hale_bakery", workerIds: ["edda_hale", "mara_hale"], productItemIds: ["bread"], taxRate: 0.10, rentPerDay: 3, spoilageRate: 0.06 },
  // 畜牧
  { id: "livestock", name: "livestock", groupId: "livestock", workerIds: ["osric_bell", "maeve_coop", "milo_fallow", "tessa_coop"], productItemIds: ["raw_meat", "egg"], taxRate: 0.08, rentPerDay: 1, spoilageRate: 0.05 },
  // 屠夫
  { id: "butcher", name: "butcher", groupId: "butcher", workerIds: ["hugh_marrow"], productItemIds: ["raw_meat"], taxRate: 0.08, rentPerDay: 1, spoilageRate: 0.05 },
  // 酒馆 / 食堂 — 也能烤面包（有 stove），是 bakery 的补充
  { id: "tavern", name: "tavern", groupId: "tavern", workerIds: ["garron_potter", "nell_savor"], productItemIds: ["bread", "cooked_meat", "omelet", "veg_stew", "cured_stew", "cured_meat", "cured_omelet", "berry_jam"], taxRate: 0.08, rentPerDay: 2, spoilageRate: 0.07 },
  // 铁匠铺 (主铺): iron tools + ingot + 副业卖炭
  { id: "blacksmith_shop", name: "blacksmith_shop", groupId: "blacksmith_shop", workerIds: ["owen_barclay", "tilda_sparks"], productItemIds: ["iron_ingot", "iron_blade", "iron_axe_head", "iron_pick_head", "iron_pick", "iron_shovel", "sickle", "iron_axe", "iron_knife", "charcoal"], taxRate: 0.08, rentPerDay: 2, spoilageRate: 0 },
  // 锻造院 (第二铁工铺): 同样能产铁器 + 卖炭
  { id: "forge_yard", name: "forge_yard", groupId: "forge_yard", workerIds: ["garr_hollow", "edda_vance"], productItemIds: ["iron_ingot", "iron_blade", "iron_axe_head", "iron_pick_head", "iron_pick", "iron_shovel", "sickle", "iron_axe", "iron_knife", "charcoal"], taxRate: 0.08, rentPerDay: 2, spoilageRate: 0 },
  // 木材厂 (只卖原木/木件，炭归铁工，绳归杂货店)
  { id: "lumberyard", name: "lumberyard", groupId: "lumberyard", workerIds: ["silas_coppice"], productItemIds: ["wood", "wood_shaft", "wood_plank"], taxRate: 0.06, rentPerDay: 1, spoilageRate: 0 },
  // 杂货店 (Cora 独立卖亚麻 + 绳)
  { id: "general_store", name: "general_store", groupId: "general_store", workerIds: ["cora_reed"], productItemIds: ["flax_bundle", "flax_seed", "rope"], taxRate: 0.06, rentPerDay: 1, spoilageRate: 0 },
  // 圣钟草药园：草药与对症药，教会地免租
  { id: "herbal_medicine", name: "herbal medicine", groupId: "saint_bell_chapel", workerIds: ["greta_moss", "pella_moss", "borin_ash"], productItemIds: ["mint_leaf", "mugwort_leaf", "ginger_root", "plantain_leaf", "calendula_flower", "valerian_root", "herbal_remedy", "mint_mugwort_tea", "ginger_plantain_broth", "calendula_salve", "valerian_tonic"], taxRate: 0, rentPerDay: 0, spoilageRate: 0.03 },
  // 私铁矿
  { id: "iron_mining", name: "iron mining", groupId: "iron_mine", workerIds: ["merrin_cairn"], productItemIds: ["iron_ore"], taxRate: 0.08, rentPerDay: 1, spoilageRate: 0 },
  // 国营金银矿 (产出按面值归国库)
  { id: "royal_mines", name: "royal mines", groupId: "royal_treasury", workerIds: ["tomas_pike", "harlan_dunn", "wilf_drake"], productItemIds: ["gold_ore", "silver_ore"], taxRate: 0, rentPerDay: 0, spoilageRate: 0, revenueMode: "asset_supply" },
  // 盐场
  { id: "saltworks", name: "saltworks", groupId: "saltworks", workerIds: ["iona_brine"], productItemIds: ["salt"], taxRate: 0.05, rentPerDay: 1, spoilageRate: 0 },
  // 旅店 + 商队进口（cured_stew、外贸盐/绳缓冲）
  { id: "inn", name: "inn imports", groupId: "inn", workerIds: ["vera_clay", "tobin_reeve"], productItemIds: ["cured_stew"], taxRate: 0.03, rentPerDay: 1, spoilageRate: 0.05 },
  // 裁缝（暂无成品 item，留 placeholder）
  { id: "textiles", name: "textiles", groupId: "tailor", workerIds: ["hilda_fenwick", "perrin_weft"], productItemIds: [], taxRate: 0.06, rentPerDay: 1, spoilageRate: 0 },
  // 公共雇员（卫兵 + 财政大臣，由国库薪资支付，无产）
  { id: "public_service", name: "public payroll", groupId: "royal_treasury", workerIds: ["magda_kerr", "keir_march", "sona_ward", "garret_pell", "iva_stone", "brenna_vail", "rolan_teague", "merek_gate", "oswin_locke"], productItemIds: [], taxRate: 0, rentPerDay: 0, spoilageRate: 0, revenueMode: "none" },
];

// 同一 reaction 可能多个 sector 都执行。这里列出 split。默认走 REACTION_SECTORS。
const REACTION_SECTOR_SPLITS: Dict<Array<{ sectorId: string; share: number }>> = {
  // 面包链：bakery 主业 + tavern 旁支（用 tavern 自家 stove 顺便烤）
  mix_dough: [
    { sectorId: "hale_bakery", share: 0.65 },
    { sectorId: "tavern", share: 0.35 },
  ],
  bake_bread: [
    { sectorId: "hale_bakery", share: 0.65 },
    { sectorId: "tavern", share: 0.35 },
  ],
  // 铁工链：blacksmith_shop 和 forge_yard 两家都有 forge+anvil+workbench+kiln，各 2 工人 → 50/50。
  forge_smelt:     [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  forge_alloy:     [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  anvil_axe_head:  [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  anvil_blade:     [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  anvil_pick_head: [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  combine_axe:     [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  combine_knife:   [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  combine_pick:    [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  combine_shovel:  [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  combine_sickle:  [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
  kiln_burn:       [{ sectorId: "blacksmith_shop", share: 0.5 }, { sectorId: "forge_yard", share: 0.5 }],
};

const REACTION_SECTORS: Dict<string> = {
  mill_grind: "milling",
  mix_dough: "hale_bakery",
  bake_bread: "hale_bakery",
  bake_meat: "tavern",
  bake_meat_salted: "tavern",
  bake_omelet: "tavern",
  bake_omelet_salted: "tavern",
  mix_jam: "tavern",
  mix_stew: "tavern",
  mix_stew_salted: "tavern",
  compound_mint_mugwort_tea: "herbal_medicine",
  compound_ginger_plantain_broth: "herbal_medicine",
  compound_calendula_salve: "herbal_medicine",
  compound_valerian_tonic: "herbal_medicine",
  boil_salt: "saltworks",
  forge_smelt: "blacksmith_shop",
  forge_alloy: "blacksmith_shop",
  anvil_axe_head: "blacksmith_shop",
  anvil_blade: "blacksmith_shop",
  anvil_pick_head: "blacksmith_shop",
  combine_axe: "blacksmith_shop",
  combine_knife: "blacksmith_shop",
  combine_pick: "blacksmith_shop",
  combine_shovel: "blacksmith_shop",
  combine_sickle: "blacksmith_shop",
  kiln_burn: "blacksmith_shop",
  carve_plank: "lumberyard",
  carve_shaft: "lumberyard",
  combine_rope: "general_store",
  dry_tomato_seed: "primary_agriculture",
  dry_flax_seed: "general_store",
  dry_mint_seed: "herbal_medicine",
  dry_mugwort_seed: "herbal_medicine",
  dry_plantain_seed: "herbal_medicine",
  dry_calendula_seed: "herbal_medicine",
  dry_ginger_seed: "herbal_medicine",
  dry_valerian_seed: "herbal_medicine",
  dig_gold: "royal_mines",
  dig_silver: "royal_mines",
  // 之前漏的原料 reaction：归属对应部门，capacity check 才看得到 worker/stamina 预算。
  chop_wood: "lumberyard",
  dig_iron: "iron_mining",
};

function main() {
  const catalog = loadCatalog();
  const model = buildEconomyModel(catalog);
  process.stdout.write(renderReport(catalog, model));
}

function loadCatalog(): Catalog {
  const labels = loadLabels();
  const materials = loadMaterials(labels.materials);
  const items = loadItems(labels.items, materials);
  addPseudoItems(items, labels.materials);
  const crops = loadCropVarieties();
  const reactions = loadReactions();
  const recipes = expandRecipes(reactions, items, materials);
  return {
    labels,
    materials,
    items,
    crops,
    reactions,
    recipes,
    farmSlots: loadFarmSlots(),
    workstationCounts: loadWorkstationCounts(),
    groupToLocations: loadGroupToLocations(),
    npcs: loadNpcData(),
    groupMembers: buildGroupMembersFromNpcs(),
    mineTargets: loadMineTargets(),
    runtimeWages: loadRuntimeWagePolicy(),
  };
}

function buildEconomyModel(catalog: Catalog): EconomyModel {
  const npcCount = catalog.npcs.size;
  const prices = computePrices(catalog.items, catalog.materials, catalog.crops, catalog.recipes);
  const state = createModelState();

  const foodRows = planFood(catalog, state, npcCount);
  const livestockRows = planLivestock(catalog, state);
  const toolRows = planTools(catalog, state);
  planProducerSupplies(catalog, state);
  const mineRows = planRoyalMines(catalog, state);
  const cropRows = planCrops(catalog, state);
  const wageRows = computeWageRows(catalog, mineRows);
  const sectorLaborRows = computeSectorLaborRows(catalog, state);
  const sectorRows = computeSectorCashRows(catalog, state, prices, wageRows, sectorLaborRows);
  const groupRows = computeGroupCashRows(catalog, sectorRows, wageRows);
  const reactionCapacityRows = computeReactionCapacityRows(catalog, state);
  const risks = computeRiskLines(catalog, state, foodRows, cropRows, wageRows, sectorRows, groupRows, sectorLaborRows, reactionCapacityRows);

  return {
    npcCount,
    prices,
    state,
    foodRows,
    cropRows,
    toolRows,
    livestockRows,
    mineRows,
    wageRows,
    sectorRows,
    groupRows,
    reactionCapacityRows,
    sectorLaborRows,
    risks,
  };
}

function createModelState(): ModelState {
  return {
    flows: new Map<string, ItemFlow>(),
    supplyBySector: new Map<string, Dict<number>>(),
    demandBySector: new Map<string, Dict<number>>(),
    workOrders: [],
    activityDemands: [],
  };
}

function planFood(catalog: Catalog, state: ModelState, npcCount: number): FoodPlanRow[] {
  const rows: FoodPlanRow[] = [];
  // 市场食物只服务 marketCustomerFraction × npcCount。自给户 (农场+磨坊+酒馆家) 不进 bakery/tavern 市场。
  // 但自给户依然要消耗 wheat 自磨自烤 → 通过 mill_grind / household stove 走 catalog 自动 plan。
  // 这里 marketHunger 只算市场端，进而 bakery/tavern 的产能/营收按真实需求算。
  const marketHunger = npcCount * ECONOMY.npcDailyHunger * ECONOMY.foodSafetyFactor * ECONOMY.marketCustomerFraction;
  const dailyHunger = marketHunger;
  for (const entry of ECONOMY.foodPlan) {
    const item = catalog.items.get(entry.itemId);
    const hungerPerItem = item && item.hunger > 0 ? item.hunger : entry.fallbackHunger;
    const targetHunger = dailyHunger * entry.hungerShare;
    const targetQty = targetHunger / Math.max(1, hungerPerItem);
    addDemand(state, entry.itemId, targetQty, `food_plan:${entry.group}:${round(targetHunger, 2)}_hunger`, "household_consumption");
    planRecipeOutput(catalog, state, entry.itemId, targetQty, `food_plan:${entry.group}`);
    rows.push({
      group: entry.group,
      itemId: entry.itemId,
      itemName: label(catalog.items, entry.itemId),
      hungerShare: entry.hungerShare,
      targetHunger,
      hungerPerItem,
      targetQty,
      suppliedQty: 0,
      gapQty: 0,
    });
  }
  return rows;
}

function planLivestock(catalog: Catalog, state: ModelState): LivestockPlanRow[] {
  const rows: LivestockPlanRow[] = [];
  for (const [itemId, feed] of Object.entries(ECONOMY.livestockFeed)) {
    const requiredByKitchen = totalDemandForItem(state, itemId);
    const outputQty = Math.max(requiredByKitchen, ECONOMY.livestockMinimumDailySupply[itemId] ?? 0);
    if (outputQty <= 0) continue;
    addSupply(state, itemId, outputQty, "livestock_output", "livestock");
    const feedQty = outputQty * feed.qtyPerUnit;
    addDemand(state, feed.itemId, feedQty, `livestock_feed:${itemId}`, "livestock");
    state.activityDemands.push({
      sectorId: "livestock",
      activity: `care/slaughter/collect:${itemId}`,
      workerCount: sectorWorkerCount("livestock", catalog),
      requiredHours: outputQty * ECONOMY.livestockLaborHoursPerUnit,
      requiredStamina: outputQty * ECONOMY.livestockLaborStaminaPerUnit,
      source: "livestock design target",
    });
    rows.push({
      itemId,
      itemName: label(catalog.items, itemId),
      outputQty,
      feedItemId: feed.itemId,
      feedQty,
    });
  }
  return rows;
}

function planTools(catalog: Catalog, state: ModelState): ToolPlanRow[] {
  const rows: ToolPlanRow[] = [];
  const activeUsers = computeActiveUserCounts(catalog);
  for (const tool of ECONOMY.productionTools) {
    const users = activeUsers[tool.activeUsersKey] ?? 0;
    const dailyWear = users * tool.wearPerUserPerDay;
    if (dailyWear <= 0) continue;
    const weightTotal = Object.values(tool.payerWeights).reduce((sum, value) => sum + value, 0);
    for (const [sectorId, weight] of Object.entries(tool.payerWeights)) {
      addDemand(state, tool.itemId, dailyWear * weight / Math.max(1, weightTotal), `tool_wear:${tool.activity}`, sectorId);
    }
    const craftable = findRecipe(catalog.recipes, tool.itemId) != null;
    planRecipeOutput(catalog, state, tool.itemId, dailyWear, `tool_replacement:${tool.activity}`);
    rows.push({
      itemId: tool.itemId,
      itemName: label(catalog.items, tool.itemId),
      activity: tool.activity,
      activeUsers: users,
      wearPerUserPerDay: tool.wearPerUserPerDay,
      dailyWear,
      payerSectors: Object.entries(tool.payerWeights).map(([sectorId, weight]) => `${sectorLabel(sectorId)} ${round(weight / Math.max(1, weightTotal) * 100, 1)}%`).join(", "),
      craftable,
    });
  }
  return rows;
}

function planProducerSupplies(catalog: Catalog, state: ModelState) {
  for (const [itemId, producer] of Object.entries(ECONOMY.producerSupply)) {
    addSupply(state, itemId, producer.qty, "designed_daily_producer_supply", producer.sectorId);
    for (const [inputItemId, qtyPerUnit] of Object.entries(ECONOMY.producerInputs[itemId] ?? {})) {
      addDemand(state, inputItemId, producer.qty * qtyPerUnit, `producer_input:${itemId}`, producer.sectorId);
    }
    const labor = (ECONOMY.producerLabor as Dict<{ sectorId: string; hoursPerUnit: number; staminaPerUnit: number }>)[itemId];
    if (labor) {
      state.activityDemands.push({
        sectorId: labor.sectorId,
        activity: `produce:${itemId}`,
        workerCount: sectorWorkerCount(labor.sectorId, catalog),
        requiredHours: producer.qty * labor.hoursPerUnit,
        requiredStamina: producer.qty * labor.staminaPerUnit,
        source: "designed non-recipe producer",
      });
    }
  }
  const wellCount = catalog.workstationCounts.well ?? 0;
  if (wellCount > 0) {
    addSupply(state, "water", wellCount * ECONOMY.wellWaterPerWellDay, `well_capacity:${wellCount}`, "public_infrastructure");
  }
}

function planRoyalMines(catalog: Catalog, state: ModelState): MinePlanRow[] {
  const rows: MinePlanRow[] = [];
  for (const [mineId, perHour] of Object.entries(catalog.mineTargets)) {
    const itemId = ECONOMY.mineOutputItems[mineId] ?? "";
    if (!itemId) continue;
    const targetQty = perHour * 24;
    const workerIds = ECONOMY.mineWorkers[mineId] ?? [];
    const staminaCap = workerIds.length * ECONOMY.workerStaminaBudgetPerDay / 10;
    const timeCap = workerIds.length * ECONOMY.facilityHoursPerDay * 3600 / 300;
    const outputQty = Math.min(targetQty, staminaCap, timeCap);
    const wageRate = catalog.runtimeWages.oreRates[itemId] ?? ECONOMY.mineWageRates[itemId] ?? 0;
    const wageTotal = outputQty * wageRate;
    addSupply(state, itemId, outputQty, `royal_mine:${mineId}`, "royal_mines");
    state.activityDemands.push({
      sectorId: "royal_mines",
      activity: `dig:${mineId}`,
      workerCount: workerIds.length,
      requiredHours: outputQty * 300 / 3600,
      requiredStamina: outputQty * 10,
      source: "src/autoload/mines.gd target + runtime wage policy",
    });
    rows.push({
      mineId,
      itemId,
      itemName: label(catalog.items, itemId),
      targetQty,
      outputQty,
      workerIds,
      wageRate,
      wageTotal,
    });
  }
  return rows;
}

function planCrops(catalog: Catalog, state: ModelState): CropPlanRow[] {
  for (const crop of catalog.crops.values()) {
    const currentDemand = totalDemandForItem(state, crop.harvestYieldId);
    if (currentDemand > 0) {
      addDemand(state, crop.harvestYieldId, currentDemand * ECONOMY.cropSeedReserveRate, `seed_or_replant_reserve:${crop.id}`, "primary_agriculture");
    }
  }

  const totalFarmSlots = Object.values(catalog.farmSlots).reduce((sum, value) => sum + value, 0);
  const requests = [...catalog.crops.values()].map((crop) => {
    const requestedQty = Math.max(totalDemandForItem(state, crop.harvestYieldId), ECONOMY.cropMinimumDailyTargets[crop.id] ?? 0);
    const perSlotPerDay = crop.harvestYieldQuantity * (24 / Math.max(1, crop.maturationHours)) * ECONOMY.cropCareYieldMultiplier * ECONOMY.farmUtilization;
    const slotsNeeded = requestedQty / Math.max(0.0001, perSlotPerDay);
    return { crop, requestedQty, perSlotPerDay, slotsNeeded };
  });
  const totalSlotsNeeded = requests.reduce((sum, row) => sum + row.slotsNeeded, 0);
  const scale = totalSlotsNeeded > totalFarmSlots && totalFarmSlots > 0 ? totalFarmSlots / totalSlotsNeeded : 1;
  const rows: CropPlanRow[] = [];
  for (const request of requests) {
    const slotsAllocated = request.slotsNeeded * scale;
    const suppliedQty = slotsAllocated * request.perSlotPerDay;
    if (suppliedQty > 0) addSupply(state, request.crop.harvestYieldId, suppliedQty, `crop_plan:${request.crop.id}`, "primary_agriculture");
    if (slotsAllocated > 0) {
      state.activityDemands.push({
        sectorId: "primary_agriculture",
        activity: `fieldwork:${request.crop.id}`,
        workerCount: sectorWorkerCount("primary_agriculture", catalog),
        requiredHours: slotsAllocated * ECONOMY.farmLaborHoursPerSlotDay,
        requiredStamina: slotsAllocated * ECONOMY.farmLaborStaminaPerSlotDay,
        source: "farm slot crop plan",
      });
    }
    rows.push({
      cropId: request.crop.id,
      itemId: request.crop.harvestYieldId,
      itemName: label(catalog.items, request.crop.harvestYieldId),
      requestedQty: request.requestedQty,
      suppliedQty,
      perSlotPerDay: request.perSlotPerDay,
      slotsNeeded: request.slotsNeeded,
      slotsAllocated,
      slotShare: totalFarmSlots > 0 ? slotsAllocated / totalFarmSlots : 0,
    });
  }
  return rows.sort((a, b) => b.slotsAllocated - a.slotsAllocated);
}

function computeWageRows(catalog: Catalog, mineRows: MinePlanRow[]): WageRow[] {
  const rows: WageRow[] = [];
  for (const mine of mineRows) {
    const weights = mine.workerIds.map((id) => id === "harlan_dunn" ? 1.15 : id === "wilf_drake" ? 0.85 : 1);
    const weightTotal = weights.reduce((sum, value) => sum + value, 0);
    mine.workerIds.forEach((id, index) => {
      rows.push({
        recipientId: id,
        recipientName: npcName(catalog, id),
        role: id === "wilf_drake" ? "silver miner apprentice, piece-rate" : mine.mineId === "gold_mine" ? "gold miner, piece-rate" : "silver miner, piece-rate",
        payerGroupId: "royal_treasury",
        payerSectorId: "royal_mines",
        silverPerDay: mine.wageTotal * (weights[index] ?? 1) / Math.max(1, weightTotal),
        source: "magda_kerr offer: ore rate from backend_action_runner.gd",
        status: catalog.runtimeWages.minerIds.includes(id) ? "implemented" : "design_only",
      });
    });
  }

  for (const [npcId, policy] of Object.entries(catalog.runtimeWages.weeklyRoles)) {
    const groupId = groupIdForNpc(catalog, npcId);
    rows.push({
      recipientId: npcId,
      recipientName: npcName(catalog, npcId),
      role: groupId === "town_guard" ? "guard weekly wage" : "weekly public role",
      payerGroupId: "royal_treasury",
      payerSectorId: "public_service",
      silverPerDay: policy.amount / 7,
      source: `runtime weekly wage: ${policy.amount}/week, weekday ${policy.weekday}`,
      status: "implemented",
    });
  }

  for (const wage of ECONOMY.apprenticeWages) {
    rows.push({
      recipientId: wage.recipientId,
      recipientName: npcName(catalog, wage.recipientId),
      role: wage.role,
      payerGroupId: wage.payerGroupId,
      payerSectorId: wage.payerSectorId,
      silverPerDay: wage.silverPerDay,
      source: wage.source,
      status: wage.silverPerDay > 0 ? "design_only" : "non_cash_household_share",
    });
  }
  return rows.sort((a, b) => b.silverPerDay - a.silverPerDay || a.recipientId.localeCompare(b.recipientId));
}

function computeSectorLaborRows(catalog: Catalog, state: ModelState): SectorLaborRow[] {
  const sectorHours: Dict<number> = {};
  const sectorStamina: Dict<number> = {};
  const sectorSources: Dict<string[]> = {};
  for (const order of state.workOrders) {
    sectorHours[order.sectorId] = (sectorHours[order.sectorId] ?? 0) + order.requiredHours;
    sectorStamina[order.sectorId] = (sectorStamina[order.sectorId] ?? 0) + order.requiredStamina;
    pushUnique(sectorSources, order.sectorId, order.reactionId);
  }
  for (const demand of state.activityDemands) {
    sectorHours[demand.sectorId] = (sectorHours[demand.sectorId] ?? 0) + demand.requiredHours;
    sectorStamina[demand.sectorId] = (sectorStamina[demand.sectorId] ?? 0) + demand.requiredStamina;
    pushUnique(sectorSources, demand.sectorId, demand.activity);
  }

  return SECTORS.map((sector) => {
    const workers = sectorWorkerCount(sector.id, catalog);
    const requiredHours = sectorHours[sector.id] ?? 0;
    const requiredStamina = sectorStamina[sector.id] ?? 0;
    const availableHours = workers * ECONOMY.facilityHoursPerDay;
    const availableStamina = workers * ECONOMY.workerStaminaBudgetPerDay;
    const laborValue = Math.max(requiredHours * ECONOMY.laborSilverPerGameHour, requiredStamina / ECONOMY.workerStaminaBudgetPerDay * ECONOMY.facilityHoursPerDay * ECONOMY.laborSilverPerGameHour);
    const status = requiredHours > availableHours + 0.01 || requiredStamina > availableStamina + 0.01 ? "short" : requiredHours > 0 || requiredStamina > 0 ? "ok" : "idle_or_unmodeled";
    return {
      sectorId: sector.id,
      sectorName: sector.name,
      workers,
      requiredHours,
      availableHours,
      requiredStamina,
      availableStamina,
      laborValue: roundMoney(Math.max(0, laborValue)),
      status,
      sources: (sectorSources[sector.id] ?? []).join(", ") || "-",
    };
  }).filter((row) => row.status !== "idle_or_unmodeled" || row.workers > 0);
}

function computeSectorCashRows(
  catalog: Catalog,
  state: ModelState,
  prices: Map<string, Price>,
  wageRows: WageRow[],
  laborRows: SectorLaborRow[],
): SectorCashRow[] {
  const taxBaseRows: SectorCashRow[] = [];
  for (const sector of SECTORS) {
    const revenue = sectorRevenue(sector, state, prices);
    const materialCost = sectorMaterialCost(sector, state, prices);
    const fixedWages = wageRows.filter((row) => row.payerSectorId === sector.id).reduce((sum, row) => sum + row.silverPerDay, 0);
    const laborValue = laborRows.find((row) => row.sectorId === sector.id)?.laborValue ?? 0;
    const ownerLaborDraw = Math.max(0, laborValue - fixedWages);
    const spoilageCost = revenue * sector.spoilageRate;
    const preTax = revenue - materialCost - fixedWages - ownerLaborDraw - spoilageCost;
    const taxRent = Math.max(0, preTax) * sector.taxRate + sectorRentPerDay(sector, catalog, revenue);
    const retained = preTax - taxRent;
    taxBaseRows.push({
      sectorId: sector.id,
      sectorName: sector.name,
      groupId: sector.groupId,
      revenue,
      materialCost,
      wageCost: fixedWages,
      ownerLaborDraw,
      taxRent,
      spoilageCost,
      retained,
      capture: Math.max(0, retained) + ownerLaborDraw + fixedWages,
      notes: sectorNotes(sector, state),
    });
  }
  return taxBaseRows.sort((a, b) => b.capture - a.capture || a.sectorName.localeCompare(b.sectorName));
}

function computeGroupCashRows(catalog: Catalog, sectorRows: SectorCashRow[], wageRows: WageRow[]): GroupCashRow[] {
  const groupIds = new Set<string>();
  for (const id of catalog.groupMembers.keys()) groupIds.add(id);
  for (const sector of SECTORS) groupIds.add(sector.groupId);
  for (const bakery of ECONOMY.bakeryGroups) groupIds.add(bakery.groupId);
  for (const mill of ECONOMY.millingGroups) groupIds.add(mill.groupId);
  for (const row of wageRows) groupIds.add(row.payerGroupId);
  groupIds.add("royal_treasury");

  const farmGroups = farmGroupSlotRows(catalog);
  const farmSlotTotal = farmGroups.reduce((sum, row) => sum + row.slots, 0);
  const agricultureSector = sectorRows.find((row) => row.sectorId === "primary_agriculture");
  const bakerySector = sectorRows.find((row) => row.sectorId === "hale_bakery");
  const millingSector = sectorRows.find((row) => row.sectorId === "milling");

  const rows: GroupCashRow[] = [];
  for (const groupId of groupIds) {
    let businessRetained = 0;
    let ownerLaborDraw = 0;
    const notes: string[] = [];
    if (groupId === "farm_groups" || groupId === "bakery_groups" || groupId === "milling_groups") continue;
    if (agricultureSector) {
      const farm = farmGroups.find((row) => row.groupId === groupId);
      if (farm && farmSlotTotal > 0) {
        const share = farm.slots / farmSlotTotal;
        businessRetained += (agricultureSector.retained + agricultureSector.taxRent) * share - farmGroupRentPerDay(farm.groupId, farm.slots);
        ownerLaborDraw += agricultureSector.ownerLaborDraw * share;
        notes.push(`farm-slot share ${round(share * 100, 1)}%, ${farmGroupPaysRent(farm.groupId) ? `farm rent ${roundMoney(farmGroupRentPerDay(farm.groupId, farm.slots))}/day` : "farm rent exempt"}`);
      }
    }
    if (bakerySector) {
      const bakery = ECONOMY.bakeryGroups.find((row) => row.groupId === groupId);
      if (bakery) {
        businessRetained += bakerySector.retained * bakery.share;
        ownerLaborDraw += bakerySector.ownerLaborDraw * bakery.share;
        notes.push(`bakery share ${round(bakery.share * 100, 1)}%`);
      }
    }
    if (millingSector) {
      const mill = ECONOMY.millingGroups.find((row) => row.groupId === groupId);
      if (mill) {
        businessRetained += millingSector.retained * mill.share;
        ownerLaborDraw += millingSector.ownerLaborDraw * mill.share;
        notes.push(`mill share ${round(mill.share * 100, 1)}%`);
      }
    }
    for (const sector of sectorRows.filter((row) => row.groupId === groupId && row.sectorId !== "primary_agriculture")) {
      businessRetained += sector.retained;
      ownerLaborDraw += sector.ownerLaborDraw;
      notes.push(sector.sectorName);
    }
    const wagesReceived = wageRows.filter((row) => groupIdForNpc(catalog, row.recipientId) === groupId).reduce((sum, row) => sum + row.silverPerDay, 0);
    const directPayrollPaid = wageRows.filter((row) => row.payerGroupId === groupId && !row.payerSectorId).reduce((sum, row) => sum + row.silverPerDay, 0);
    const taxRentReceived = groupId === "royal_treasury" ? sectorRows.reduce((sum, row) => sum + row.taxRent, 0) : 0;
    const totalCapture = businessRetained + ownerLaborDraw + wagesReceived + taxRentReceived - directPayrollPaid;
    if (Math.abs(totalCapture) > 0.001 || knownGroupMembers(catalog, groupId).length > 0 || groupId.startsWith("future_") || groupId === "royal_treasury") {
      rows.push({
        groupId,
        members: knownGroupMembers(catalog, groupId).length,
        businessRetained,
        ownerLaborDraw,
        wagesReceived,
        taxRentReceived,
        directPayrollPaid,
        totalCapture,
        captureShare: 0,
        notes: notes.join(", ") || "-",
      });
    }
  }
  const totalPositive = rows.reduce((sum, row) => sum + Math.max(0, row.totalCapture), 0);
  return rows.map((row) => ({ ...row, captureShare: totalPositive > 0 ? Math.max(0, row.totalCapture) / totalPositive : 0 }))
    .sort((a, b) => b.totalCapture - a.totalCapture || a.groupId.localeCompare(b.groupId));
}

function computeReactionCapacityRows(catalog: Catalog, state: ModelState): ReactionCapacityRow[] {
  const byReaction = new Map<string, WorkOrder>();
  for (const order of state.workOrders) {
    const existing = byReaction.get(order.reactionId);
    if (!existing) {
      byReaction.set(order.reactionId, { ...order });
    } else {
      existing.outputQty += order.outputQty;
      existing.actions += order.actions;
      existing.requiredHours += order.requiredHours;
      existing.requiredStamina += order.requiredStamina;
    }
  }
  return [...byReaction.values()].map((order) => {
    const recipe = catalog.recipes.find((entry) => entry.reactionId === order.reactionId && entry.outputItemId === order.outputItemId)
      ?? catalog.recipes.find((entry) => entry.reactionId === order.reactionId);
    const stationCount = catalog.workstationCounts[normalizeWorkstation(order.workstation)] ?? 0;
    const sectorWorkers = sectorWorkerCount(order.sectorId, catalog);
    const outputQty = recipe?.outputQty ?? 1;
    const duration = recipe?.durationSeconds ?? 0;
    const stamina = recipe?.staminaCost ?? 0;
    const timeCapacity = duration > 0 ? stationCount * ECONOMY.facilityHoursPerDay * 3600 / duration * outputQty : Number.POSITIVE_INFINITY;
    const staminaCapacity = stamina > 0 ? sectorWorkers * ECONOMY.workerStaminaBudgetPerDay / stamina * outputQty : Number.POSITIVE_INFINITY;
    const capacity = Math.min(timeCapacity, staminaCapacity);
    return {
      reactionId: order.reactionId,
      sectorId: order.sectorId,
      workstation: normalizeWorkstation(order.workstation),
      stationCount,
      requiredOutput: order.outputQty,
      timeCapacity,
      staminaCapacity,
      status: stationCount <= 0 ? "missing_station" : order.outputQty > capacity + 0.01 ? "short" : "ok",
    };
  }).sort((a, b) => statusRank(a.status) - statusRank(b.status) || a.sectorId.localeCompare(b.sectorId) || a.reactionId.localeCompare(b.reactionId));
}

function computeRiskLines(
  catalog: Catalog,
  state: ModelState,
  foodRows: FoodPlanRow[],
  cropRows: CropPlanRow[],
  wageRows: WageRow[],
  sectorRows: SectorCashRow[],
  groupRows: GroupCashRow[],
  laborRows: SectorLaborRow[],
  capacityRows: ReactionCapacityRow[],
): string[] {
  const lines: string[] = [];
  const foodShort = foodRows.filter((row) => row.gapQty > 0.01);
  for (const row of foodShort) lines.push(`${row.itemName} food target is short by ${round(row.gapQty, 2)}/day.`);
  for (const row of cropRows.filter((entry) => entry.suppliedQty + 0.01 < entry.requestedQty)) {
    lines.push(`${row.itemName} crop plan requests ${round(row.requestedQty, 2)}/day but farm capacity supplies ${round(row.suppliedQty, 2)}/day.`);
  }
  for (const row of laborRows.filter((entry) => entry.status === "short")) {
    lines.push(`${row.sectorName} labor bottleneck: needs ${round(row.requiredStamina, 1)} stamina/day and ${round(row.requiredHours, 2)}h/day, has ${round(row.availableStamina, 1)} stamina and ${round(row.availableHours, 2)}h.`);
  }
  for (const row of capacityRows.filter((entry) => entry.status !== "ok")) {
    lines.push(`${row.reactionId} capacity is ${row.status}; required ${round(row.requiredOutput, 2)}/day at ${row.workstation} x${row.stationCount}.`);
  }
  for (const row of groupRows.filter((entry) => entry.captureShare >= ECONOMY.wealthRiskGroupShare && entry.totalCapture > 0)) {
    lines.push(`${row.groupId} captures ${round(row.captureShare * 100, 1)}% of modeled positive daily money after wages/tax/rent. Check ownership split, household spending, and tax/rent sinks.`);
  }
  for (const row of sectorRows) {
    const positiveTotal = sectorRows.reduce((sum, entry) => sum + Math.max(0, entry.capture), 0);
    const share = positiveTotal > 0 ? Math.max(0, row.capture) / positiveTotal : 0;
    if (share >= ECONOMY.wealthRiskSectorShare) lines.push(`${row.sectorName} captures ${round(share * 100, 1)}% of sector cash capture; this is a concentration risk if its owner group is narrow.`);
  }
  if (!wageRows.some((row) => row.role.includes("guard"))) lines.push("Guard payroll is absent; add guard wage policies before balancing public spending.");
  if (!catalog.groupMembers.has("hale_bakery")) lines.push("Bakery ownership is modeled as hale_bakery but no NPC declares it in npcs.json groups[]; assign the bakery owners if it should affect simulation wealth.");
  if (!catalog.groupMembers.has("millward_mill")) lines.push("Mill ownership is modeled as millward_mill but no NPC declares it in npcs.json groups[]; assign mill owners if it should affect simulation wealth.");
  if (flowRows(catalog.items, state.flows).some((row) => row.status === "short")) lines.push("Some item flows are short; see Daily Resource Flow for concrete missing producers or over-target consumption.");
  if (lines.length === 0) lines.push("No structural risk under current assumptions; next step is replacing derived/future groups with concrete ownership data.");
  return uniqueStrings(lines);
}

function planRecipeOutput(catalog: Catalog, state: ModelState, itemId: string, qty: number, reason: string, depth = 0, seen = new Set<string>()) {
  if (qty <= 0 || depth > 10) return;
  const recipe = findRecipe(catalog.recipes, itemId);
  if (!recipe) return;
  const key = `${recipe.reactionId}:${itemId}`;
  if (seen.has(key)) return;
  const nextSeen = new Set(seen);
  nextSeen.add(key);
  const defaultSectorId = REACTION_SECTORS[recipe.reactionId] ?? sectorForWorkstation(recipe.workstation);
  const allocations = REACTION_SECTOR_SPLITS[recipe.reactionId]
    ?? [{ sectorId: defaultSectorId, share: 1.0 }];
  for (const alloc of allocations) {
    const portionQty = qty * alloc.share;
    if (portionQty <= 0) continue;
    const actions = portionQty / Math.max(1, recipe.outputQty);
    addSupply(state, itemId, portionQty, `planned_output:${reason}:${recipe.reactionId}`, alloc.sectorId);
    state.workOrders.push({
      reactionId: recipe.reactionId,
      sectorId: alloc.sectorId,
      workstation: recipe.workstation,
      outputItemId: itemId,
      outputQty: portionQty,
      actions,
      requiredHours: actions * recipe.durationSeconds / 3600,
      requiredStamina: actions * recipe.staminaCost,
    });
    for (const [overheadItemId, overheadQty] of Object.entries(ECONOMY.recipeOverheads[recipe.reactionId] ?? {})) {
      addDemand(state, overheadItemId, portionQty * overheadQty, `recipe_overhead:${recipe.reactionId}`, alloc.sectorId);
    }
    for (const inputId of recipe.inputItemIds) {
      addDemand(state, inputId, actions, `recipe_input:${recipe.reactionId}`, alloc.sectorId);
      planRecipeOutput(catalog, state, inputId, actions, `input_for:${recipe.reactionId}`, depth + 1, nextSeen);
    }
  }
}

function sectorRevenue(sector: SectorConfig, state: ModelState, prices: Map<string, Price>): number {
  if (sector.revenueMode === "none") return 0;
  let total = 0;
  const ownSupply = state.supplyBySector.get(sector.id) ?? {};
  const ownDemand = state.demandBySector.get(sector.id) ?? {};
  for (const itemId of sector.productItemIds) {
    const supply = ownSupply[itemId] ?? 0;
    const price = priceOf(prices, itemId);
    if (sector.revenueMode === "asset_supply") {
      total += supply * price;
      continue;
    }
    const externalDemand = Math.max(0, totalDemandForItem(state, itemId) - (ownDemand[itemId] ?? 0));
    total += Math.min(supply, externalDemand) * price;
  }
  return total;
}

function sectorMaterialCost(sector: SectorConfig, state: ModelState, prices: Map<string, Price>): number {
  const ownDemand = state.demandBySector.get(sector.id) ?? {};
  const ownSupply = state.supplyBySector.get(sector.id) ?? {};
  let total = 0;
  for (const [itemId, demand] of Object.entries(ownDemand)) {
    const internalSupply = ownSupply[itemId] ?? 0;
    const purchasedQty = Math.max(0, demand - internalSupply);
    total += purchasedQty * priceOf(prices, itemId);
  }
  return total;
}

function sectorNotes(sector: SectorConfig, state: ModelState): string {
  const supplied = state.supplyBySector.get(sector.id) ?? {};
  const demanded = state.demandBySector.get(sector.id) ?? {};
  const topOutputs = Object.entries(supplied).filter(([, qty]) => qty > 0).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([id, qty]) => `${id} ${round(qty, 2)}`);
  const topInputs = Object.entries(demanded).filter(([, qty]) => qty > 0).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([id, qty]) => `${id} ${round(qty, 2)}`);
  return `out: ${topOutputs.join(", ") || "-"}; in: ${topInputs.join(", ") || "-"}`;
}

function addSupply(state: ModelState, itemId: string, qty: number, note: string, sectorId: string) {
  if (!Number.isFinite(qty) || qty <= 0) return;
  const flow = state.flows.get(itemId) ?? { supply: 0, demand: 0, notes: [] };
  flow.supply += qty;
  if (!flow.notes.includes(note)) flow.notes.push(note);
  state.flows.set(itemId, flow);
  addSectorQty(state.supplyBySector, sectorId, itemId, qty);
}

function addDemand(state: ModelState, itemId: string, qty: number, note: string, sectorId: string) {
  if (!Number.isFinite(qty) || qty <= 0) return;
  const flow = state.flows.get(itemId) ?? { supply: 0, demand: 0, notes: [] };
  flow.demand += qty;
  if (!flow.notes.includes(note)) flow.notes.push(note);
  state.flows.set(itemId, flow);
  addSectorQty(state.demandBySector, sectorId, itemId, qty);
}

function addSectorQty(map: Map<string, Dict<number>>, sectorId: string, itemId: string, qty: number) {
  const sector = map.get(sectorId) ?? {};
  sector[itemId] = (sector[itemId] ?? 0) + qty;
  map.set(sectorId, sector);
}

function findRecipe(recipes: Recipe[], outputItemId: string): Recipe | undefined {
  const candidates = recipes.filter((recipe) => recipe.outputItemId === outputItemId);
  if (candidates.length === 0) return undefined;
  return candidates.sort((a, b) => recipeScore(a) - recipeScore(b))[0];
}

function recipeScore(recipe: Recipe): number {
  let score = recipe.inputItemIds.length * 10 + recipe.requirementItemIds.length;
  if (recipe.reactionId.includes("salted")) score += 3;
  if (recipe.reactionId.includes("alloy")) score += 5;
  return score;
}

function computeActiveUserCounts(catalog: Catalog): Dict<number> {
  const farmWorkers = farmGroupSlotRows(catalog).reduce((sum, row) => sum + row.members, 0);
  const royalMinerCount = Object.values(ECONOMY.mineWorkers).flat().length;
  const ironMinerCount = knownGroupMembers(catalog, "iron_mine").length;
  // lumberjacks 数取 lumberyard sector 实际 workerIds，跟着 SECTORS 自动同步。
  const lumberyardSector = SECTORS.find((s) => s.id === "lumberyard");
  const lumberjackCount = lumberyardSector?.workerIds.length ?? 0;
  return {
    farmers: farmWorkers,
    miners: royalMinerCount + ironMinerCount,
    lumberjacks: lumberjackCount,
  };
}

function sectorWorkerCount(sectorId: string, catalog: Catalog): number {
  if (sectorId === "primary_agriculture") return Math.max(1, farmGroupSlotRows(catalog).reduce((sum, row) => sum + row.members, 0));
  const sector = SECTORS.find((entry) => entry.id === sectorId);
  if (!sector) return 0;
  return Math.max(sector.workerIds.length, sector.plannedWorkers ?? 0);
}

// 田地归属报告：按"拥有 farm 的 group"枚举，slot 数来自 town.tscn LocationMarker 解析的 groupToLocations，
// member 数来自 npcs.json 反向聚合的 groupMembers。两者数据源完全不同——一个是空间，一个是人事。
function farmGroupSlotRows(catalog: Catalog): Array<{ groupId: string; slots: number; members: number; locations: string[] }> {
  return [...catalog.groupToLocations.entries()].map(([groupId, ownedLocations]) => {
    const locations = ownedLocations.filter((locationId) => (catalog.farmSlots[locationId] ?? 0) > 0);
    const slots = locations.reduce((sum, locationId) => sum + (catalog.farmSlots[locationId] ?? 0), 0);
    const members = (catalog.groupMembers.get(groupId) ?? []).length;
    return { groupId, slots, members, locations };
  }).filter((row) => row.slots > 0);
}

function totalFarmSlots(catalog: Catalog): number {
  return Object.values(catalog.farmSlots).reduce((sum, value) => sum + value, 0);
}

function taxableFarmSlots(catalog: Catalog): number {
  return farmGroupSlotRows(catalog).filter((row) => farmGroupPaysRent(row.groupId)).reduce((sum, row) => sum + row.slots, 0);
}

function exemptFarmSlots(catalog: Catalog): number {
  return farmGroupSlotRows(catalog).filter((row) => !farmGroupPaysRent(row.groupId)).reduce((sum, row) => sum + row.slots, 0);
}

function farmGroupPaysRent(groupId: string): boolean {
  return !ECONOMY.farmRentExemptGroupIds.includes(groupId);
}

function farmSlotRentPerDay(slots: number): number {
  return slots * ECONOMY.farmSlotRentSilverPerWeek / ECONOMY.daysPerWeek;
}

function farmGroupRentPerWeek(groupId: string, slots: number): number {
  return farmGroupPaysRent(groupId) ? slots * ECONOMY.farmSlotRentSilverPerWeek : 0;
}

function farmGroupRentPerDay(groupId: string, slots: number): number {
  return farmGroupRentPerWeek(groupId, slots) / ECONOMY.daysPerWeek;
}

function sectorRentPerDay(sector: SectorConfig, catalog: Catalog, revenue: number): number {
  if (sector.id === "primary_agriculture") return farmSlotRentPerDay(taxableFarmSlots(catalog));
  return revenue > 0 || sector.rentPerDay > 0 ? sector.rentPerDay : 0;
}

function knownGroupMembers(catalog: Catalog, groupId: string): string[] {
  const members = catalog.groupMembers.get(groupId);
  if (members && members.length > 0) return members;
  // "Shadow" groups: 经济报告用的会计分组，i18n catalog / npcs.json 不持有它们（如皇家金库等）。
  // 真正的游戏内成员资格走 npcs.json + character_groups 表；此处仅供报告分类。
  const derived: Dict<string[]> = {
    royal_treasury: ["magda_kerr"],
    royal_mine_workers: ["tomas_pike", "harlan_dunn", "wilf_drake"],
  };
  return derived[groupId] ?? [];
}

function groupIdForNpc(catalog: Catalog, npcId: string): string {
  const npc = catalog.npcs.get(npcId);
  if (npc && npc.groups.length > 0) return npc.groups[0] ?? "ungrouped";
  // 同 knownGroupMembers 注释：shadow group 映射给报告分类用。
  if (npcId === "magda_kerr") return "royal_treasury";
  if (["tomas_pike", "harlan_dunn", "wilf_drake"].includes(npcId)) return "royal_mine_workers";
  return "ungrouped";
}

function priceOf(prices: Map<string, Price>, itemId: string): number {
  return prices.get(itemId)?.value ?? ECONOMY.basePrices[itemId] ?? 0;
}

function totalDemandForItem(state: ModelState, itemId: string): number {
  return state.flows.get(itemId)?.demand ?? 0;
}

function totalSupplyForItem(state: ModelState, itemId: string): number {
  return state.flows.get(itemId)?.supply ?? 0;
}

type ContractCheck = {
  id: string;
  description: string;
  pass: boolean;
  detail: string;
};

function validateContracts(catalog: Catalog, model: EconomyModel): ContractCheck[] {
  const checks: ContractCheck[] = [];
  const prices = model.prices;
  const guardWeekly = NPC_WEEKLY_WAGES[GUARD_REPRESENTATIVE_ID]?.silverPerWeek ?? 0;
  const guardDaily = guardWeekly / 7;

  // I1: 卫兵日薪覆盖 4 bread + 1 raw_meat
  const breadPrice = priceOf(prices, "bread");
  const meatPrice = priceOf(prices, "raw_meat");
  const i1Cost = CONTRACTS.i1_guard_daily_food.breadCount * breadPrice
               + CONTRACTS.i1_guard_daily_food.rawMeatCount * meatPrice;
  checks.push({
    id: "I1",
    description: CONTRACTS.i1_guard_daily_food.description,
    pass: i1Cost <= guardDaily + 0.001,
    detail: `${CONTRACTS.i1_guard_daily_food.breadCount}×bread(${breadPrice.toFixed(2)}) + ${CONTRACTS.i1_guard_daily_food.rawMeatCount}×raw_meat(${meatPrice.toFixed(2)}) = ${i1Cost.toFixed(2)} 银 vs guard daily ${guardDaily.toFixed(2)} 银`,
  });

  // I2: 铁工具 ∈ [0.8, 1.2] × guard daily
  const tools = CONTRACTS.i2_iron_tool_vs_wage.toolItemIds.map((id) => ({
    id,
    price: priceOf(prices, id),
    ratio: guardDaily > 0 ? priceOf(prices, id) / guardDaily : Infinity,
  }));
  const i2Pass = tools.every((t) =>
    t.ratio >= CONTRACTS.i2_iron_tool_vs_wage.minMultiplier
    && t.ratio <= CONTRACTS.i2_iron_tool_vs_wage.maxMultiplier
  );
  checks.push({
    id: "I2",
    description: CONTRACTS.i2_iron_tool_vs_wage.description,
    pass: i2Pass,
    detail: tools.map((t) => `${t.id} ${t.price.toFixed(2)} 银 (${(t.ratio * 100).toFixed(0)}% of guard daily)`).join("; "),
  });

  // I3: 单 NPC 日食物 / guard daily ∈ [30%, 40%]
  let foodPerNpc = 0;
  const foodDetail: string[] = [];
  for (const entry of ECONOMY.foodPlan) {
    const item = catalog.items.get(entry.itemId);
    const hungerPerItem = item && item.hunger > 0 ? item.hunger : entry.fallbackHunger;
    const qty = ECONOMY.npcDailyHunger * entry.hungerShare / Math.max(1, hungerPerItem);
    const cost = qty * priceOf(prices, entry.itemId);
    foodPerNpc += cost;
    foodDetail.push(`${entry.itemId} ${cost.toFixed(2)}`);
  }
  const i3Ratio = guardDaily > 0 ? foodPerNpc / guardDaily : Infinity;
  checks.push({
    id: "I3",
    description: CONTRACTS.i3_food_share.description,
    pass: i3Ratio >= CONTRACTS.i3_food_share.minRatio && i3Ratio <= CONTRACTS.i3_food_share.maxRatio,
    detail: `food basket ${foodPerNpc.toFixed(2)} 银/天 / guard ${guardDaily.toFixed(2)} = ${(i3Ratio * 100).toFixed(1)}% (target ${CONTRACTS.i3_food_share.minRatio * 100}-${CONTRACTS.i3_food_share.maxRatio * 100}%); breakdown: ${foodDetail.join(", ")}`,
  });

  // I4: 国库周净流 / 周总出 ∈ ±5%
  const weeklyWages = Object.values(NPC_WEEKLY_WAGES).reduce((s, w) => s + w.silverPerWeek, 0);
  // 矿工日结：silver_mine 36 ore/day × 0.5 + gold_mine 12 × 1.0 = 30/day
  const silverMineDaily = (catalog.mineTargets.silver_mine ?? 1.5) * 24;
  const goldMineDaily = (catalog.mineTargets.gold_mine ?? 0.5) * 24;
  const minerWeeklyPayout = (silverMineDaily * (ORE_RATES.silver_ore ?? 0) + goldMineDaily * (ORE_RATES.gold_ore ?? 0)) * 7;
  const apprenticeWeekly = ECONOMY.apprenticeWages.reduce((s, w) => s + w.silverPerDay * 7, 0);
  const treasuryWeeklyExpense = weeklyWages + minerWeeklyPayout + apprenticeWeekly;
  // 收入：rent (固定 405/周) + minting profit
  const businessRentWeekly = 405; // 北墙96+灰石96+磨坊53+畜牧80+铁矿80（npcs.json Magda 第 1219 行）
  const silverMintProfitWeekly = silverMineDaily * (priceOf(prices, "silver_coin") - (ORE_RATES.silver_ore ?? 0)) * 7;
  const goldMintProfitWeekly = goldMineDaily * (priceOf(prices, "gold_coin") - (ORE_RATES.gold_ore ?? 0)) * 7;
  const treasuryWeeklyIncome = businessRentWeekly + silverMintProfitWeekly + goldMintProfitWeekly;
  const treasuryNet = treasuryWeeklyIncome - treasuryWeeklyExpense;
  const i4Ratio = treasuryWeeklyExpense > 0 ? treasuryNet / treasuryWeeklyExpense : 0;
  checks.push({
    id: "I4",
    description: CONTRACTS.i4_treasury_balance.description,
    pass: i4Ratio >= CONTRACTS.i4_treasury_balance.minRatio && i4Ratio <= CONTRACTS.i4_treasury_balance.maxRatio,
    detail: `income ${treasuryWeeklyIncome.toFixed(0)} 银/周 (rent ${businessRentWeekly} + silver mint ${silverMintProfitWeekly.toFixed(0)} + gold mint ${goldMintProfitWeekly.toFixed(0)}) − expense ${treasuryWeeklyExpense.toFixed(0)} (wages ${weeklyWages} + miners ${minerWeeklyPayout.toFixed(0)} + apprentices ${apprenticeWeekly}) = net ${treasuryNet.toFixed(0)} (${(i4Ratio * 100).toFixed(1)}% of expense)`,
  });

  // I5: 排除 owner_labor 后的真实业务利润率 ≥ -10%
  const i5Rows = model.sectorRows.filter((r) => r.revenue > 0).map((r) => {
    const businessProfit = r.revenue - r.materialCost - r.wageCost - r.spoilageCost - r.taxRent;
    return { name: r.sectorName, ratio: businessProfit / r.revenue, businessProfit, revenue: r.revenue };
  });
  const i5Failures = i5Rows.filter((r) => r.ratio < CONTRACTS.i5_sector_retained.minRetainedRatio);
  checks.push({
    id: "I5",
    description: CONTRACTS.i5_sector_retained.description,
    pass: i5Failures.length === 0,
    detail: i5Failures.length === 0
      ? "all active sectors business-profitable ≥ -10%"
      : i5Failures.map((r) => `${r.name} ${r.businessProfit.toFixed(1)}/${r.revenue.toFixed(1)} = ${(r.ratio * 100).toFixed(0)}%`).join("; "),
  });

  return checks;
}

function renderContractsSection(report: string[], catalog: Catalog, model: EconomyModel): void {
  const checks = validateContracts(catalog, model);
  const allPass = checks.every((c) => c.pass);
  report.push("## Design Contracts (Numeraire-Anchored Invariants)");
  report.push("");
  report.push(`Status: ${allPass ? "✅ all green" : `⚠️ ${checks.filter((c) => !c.pass).length}/${checks.length} failing`}. Adjust free vars (basePrices / margins / wages / feed coefficients) until all green. Contracts are in \`CONTRACTS\` const.`);
  report.push("");
  report.push("| ID | Status | Contract | Actual |");
  report.push("|---|---|---|---|");
  for (const c of checks) {
    report.push(`| ${c.id} | ${c.pass ? "✅" : "❌"} | ${c.description} | ${c.detail} |`);
  }
  report.push("");
}

function renderReport(catalog: Catalog, model: EconomyModel): string {
  refreshDerivedRows(model);
  const report: string[] = [];
  const totalFarmSlotsValue = totalFarmSlots(catalog);
  const taxableFarmSlotsValue = taxableFarmSlots(catalog);
  const exemptFarmSlotsValue = exemptFarmSlots(catalog);
  report.push("# Economy Design Model Report");
  report.push("");
  report.push(`Generated from static data in \`${projectRoot}\` at ${new Date().toISOString()}.`);
  report.push("");
  report.push("## Scope");
  report.push("");
  report.push(`- NPCs in data: ${catalog.npcs.size}`);
  report.push(`- NPCs used for economy projection: ${model.npcCount}`);
  report.push(`- Daily hunger demand: ${model.npcCount} * ${ECONOMY.npcDailyHunger} = ${model.npcCount * ECONOMY.npcDailyHunger}`);
  report.push(`- Items/materials/reactions/recipes: ${catalog.items.size}/${catalog.materials.size}/${catalog.reactions.length}/${catalog.recipes.length}`);
  report.push(`- Farm slots in scene: ${totalFarmSlotsValue}`);
  report.push(`- Farm rent to royal treasury: ${ECONOMY.farmSlotRentSilverPerWeek} silver/taxable slot/week; taxable ${taxableFarmSlotsValue}, exempt ${exemptFarmSlotsValue} = ${roundMoney(farmSlotRentPerDay(taxableFarmSlotsValue))} silver/day`);
  report.push(`- Functional workstations: ${formatWorkstationCounts(catalog.workstationCounts)}`);
  report.push("");
  report.push("## Model Contract");
  report.push("");
  report.push("- This is a daily design model: production, demand, capacity, wages, taxes/rent, and group capture. It does not simulate inventories or stock coverage.");
  report.push("- Resources are planned top-down from the actual NPC food basket and capital maintenance, then checked against farms, facilities, worker stamina, and payroll.");
  report.push("- Primary agriculture pays fixed land rent from taxable FarmSlot count: 1 silver/slot/week to royal_treasury, with church land exempt and no percentage harvest tax.");
  report.push("- Miner, guard, and Magda wages are read from runtime wage code; apprentice stipends are explicit design assumptions until encoded in gameplay.");
  report.push("- Sector retained cash is not personal wealth. Group capture separates retained business cash, owner labor draw, NPC wages, and tax/rent receipts.");
  report.push("");
  renderContractsSection(report, catalog, model);
  renderFoodSection(report, model);
  renderCropSection(report, catalog, model);
  renderResourceFlowSection(report, catalog, model);
  renderCapacitySection(report, catalog, model);
  renderToolAndLivestockSection(report, model);
  renderWageSection(report, model);
  renderCashSection(report, model);
  renderRiskSection(report, model);
  renderPriceSection(report, catalog, model);
  return `${report.join("\n")}\n`;
}

function refreshDerivedRows(model: EconomyModel) {
  for (const row of model.foodRows) {
    row.suppliedQty = totalSupplyForItem(model.state, row.itemId);
    row.gapQty = Math.max(0, row.targetQty - row.suppliedQty);
  }
}

function renderFoodSection(report: string[], model: EconomyModel) {
  report.push("## Food Plan");
  report.push("");
  report.push("| Group | Food | Hunger share | Target qty/day | Hunger/item | Supplied/day | Gap/day |");
  report.push("|---|---|---:|---:|---:|---:|---:|");
  for (const row of model.foodRows) {
    report.push(`| ${row.group} | ${row.itemName} | ${round(row.hungerShare * 100, 1)}% | ${round(row.targetQty, 2)} | ${round(row.hungerPerItem, 2)} | ${round(row.suppliedQty, 2)} | ${round(row.gapQty, 2)} |`);
  }
  report.push("");
}

function renderCropSection(report: string[], catalog: Catalog, model: EconomyModel) {
  report.push("## Crop Slot Plan");
  report.push("");
  report.push(`Farm formula: output/slot/day = harvest yield * cycles/day * ${Math.round(ECONOMY.cropCareYieldMultiplier * 100)}% care * ${Math.round(ECONOMY.farmUtilization * 100)}% utilization.`);
  report.push("");
  report.push("| Crop | Requested/day | Supplied/day | Per slot/day | Slots needed | Slots allocated | Slot share |");
  report.push("|---|---:|---:|---:|---:|---:|---:|");
  for (const row of model.cropRows) {
    report.push(`| ${row.itemName} | ${round(row.requestedQty, 2)} | ${round(row.suppliedQty, 2)} | ${round(row.perSlotPerDay, 2)} | ${round(row.slotsNeeded, 1)} | ${round(row.slotsAllocated, 1)} | ${round(row.slotShare * 100, 1)}% |`);
  }
  report.push("");
  report.push("### Farm Group Slot Ownership");
  report.push("");
  report.push("| Group | Members | Farm slots | Slot share | Rent/week | Rent/day | Locations |");
  report.push("|---|---:|---:|---:|---:|---:|---|");
  const farmRows = farmGroupSlotRows(catalog);
  const total = farmRows.reduce((sum, row) => sum + row.slots, 0);
  for (const row of farmRows.sort((a, b) => b.slots - a.slots)) {
    report.push(`| ${row.groupId} | ${row.members} | ${row.slots} | ${round(row.slots / Math.max(1, total) * 100, 1)}% | ${roundMoney(farmGroupRentPerWeek(row.groupId, row.slots))} | ${roundMoney(farmGroupRentPerDay(row.groupId, row.slots))} | ${row.locations.join(", ")} |`);
  }
  report.push("");
}

function renderResourceFlowSection(report: string[], catalog: Catalog, model: EconomyModel) {
  report.push("## Daily Resource Flow");
  report.push("");
  report.push("| Item | Supply/day | Demand/day | Net/day | Status | Notes |");
  report.push("|---|---:|---:|---:|---|---|");
  for (const row of flowRows(catalog.items, model.state.flows)) {
    report.push(`| ${row.name} | ${round(row.supply, 2)} | ${round(row.demand, 2)} | ${round(row.net, 2)} | ${row.status} | ${row.notes} |`);
  }
  report.push("");
}

function renderCapacitySection(report: string[], catalog: Catalog, model: EconomyModel) {
  report.push("## Worker And Facility Capacity");
  report.push("");
  report.push("| Sector | Workers | Hours need/have | Stamina need/have | Labor value/day | Status | Sources |");
  report.push("|---|---:|---:|---:|---:|---|---|");
  for (const row of model.sectorLaborRows) {
    report.push(`| ${row.sectorName} | ${row.workers} | ${round(row.requiredHours, 2)} / ${round(row.availableHours, 2)} | ${round(row.requiredStamina, 1)} / ${round(row.availableStamina, 1)} | ${roundMoney(row.laborValue)} | ${row.status} | ${row.sources} |`);
  }
  report.push("");
  report.push("### Recipe Capacity Checks");
  report.push("");
  report.push("| Reaction | Sector | Workstation | Required output/day | Time cap | Stamina cap | Status |");
  report.push("|---|---|---|---:|---:|---:|---|");
  for (const row of model.reactionCapacityRows) {
    report.push(`| ${row.reactionId} | ${sectorLabel(row.sectorId)} | ${row.workstation} x${row.stationCount} | ${round(row.requiredOutput, 2)} | ${formatCapacity(row.timeCapacity)} | ${formatCapacity(row.staminaCapacity)} | ${row.status} |`);
  }
  report.push("");
  report.push("### Workstation Counts");
  report.push("");
  report.push(`- ${formatWorkstationCounts(catalog.workstationCounts)}`);
  report.push("");
}

function renderToolAndLivestockSection(report: string[], model: EconomyModel) {
  report.push("## Tools And Livestock");
  report.push("");
  report.push("### Production Tool Maintenance");
  report.push("");
  report.push("| Tool | Activity | Active users | Wear/user/day | Replacement/day | Payer sectors | Craftable |");
  report.push("|---|---|---:|---:|---:|---|---|");
  for (const row of model.toolRows) {
    report.push(`| ${row.itemName} | ${row.activity} | ${row.activeUsers} | ${round(row.wearPerUserPerDay, 3)} | ${round(row.dailyWear, 2)} | ${row.payerSectors} | ${row.craftable ? "yes" : "no"} |`);
  }
  report.push("");
  report.push("### Livestock Feed");
  report.push("");
  report.push("| Output | Output/day | Feed | Feed/day |");
  report.push("|---|---:|---|---:|");
  for (const row of model.livestockRows) {
    report.push(`| ${row.itemName} | ${round(row.outputQty, 2)} | ${row.feedItemId} | ${round(row.feedQty, 2)} |`);
  }
  report.push("");
  report.push("### Royal Mine Output");
  report.push("");
  report.push("| Mine | Output | Target/day | Modeled output/day | Workers | Wage rate | Wages/day |");
  report.push("|---|---|---:|---:|---|---:|---:|");
  for (const row of model.mineRows) {
    report.push(`| ${row.mineId} | ${row.itemName} | ${round(row.targetQty, 2)} | ${round(row.outputQty, 2)} | ${row.workerIds.join(", ")} | ${roundMoney(row.wageRate)} | ${roundMoney(row.wageTotal)} |`);
  }
  report.push("");
}

function renderWageSection(report: string[], model: EconomyModel) {
  report.push("## Wage Schedule");
  report.push("");
  report.push("| Recipient | Role | Payer | Silver/day | Source | Status |");
  report.push("|---|---|---|---:|---|---|");
  for (const row of model.wageRows) {
    report.push(`| ${row.recipientName} (${row.recipientId}) | ${row.role} | ${row.payerGroupId}${row.payerSectorId ? ` / ${sectorLabel(row.payerSectorId)}` : ""} | ${roundMoney(row.silverPerDay)} | ${row.source} | ${row.status} |`);
  }
  report.push("");
}

function renderCashSection(report: string[], model: EconomyModel) {
  report.push("## Sector Cash Flow");
  report.push("");
  report.push("Formula: `retained = revenue - materials - fixed wages - owner labor draw - spoilage - tax/rent`. Owner labor draw and fixed wages are personal income, not retained business profit.");
  report.push("");
  report.push("| Sector | Owner group | Revenue | Materials | Fixed wages | Owner labor | Spoilage | Tax/rent | Retained | Capture | Notes |");
  report.push("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|");
  for (const row of model.sectorRows) {
    report.push(`| ${row.sectorName} | ${row.groupId} | ${roundMoney(row.revenue)} | ${roundMoney(row.materialCost)} | ${roundMoney(row.wageCost)} | ${roundMoney(row.ownerLaborDraw)} | ${roundMoney(row.spoilageCost)} | ${roundMoney(row.taxRent)} | ${roundMoney(row.retained)} | ${roundMoney(row.capture)} | ${row.notes} |`);
  }
  report.push("");
  report.push("## Group Wealth Capture");
  report.push("");
  report.push("| Group | Members | Business retained | Owner labor | Wages received | Tax/rent received | Direct payroll paid | Total capture | Share | Notes |");
  report.push("|---|---:|---:|---:|---:|---:|---:|---:|---:|---|");
  for (const row of model.groupRows) {
    report.push(`| ${row.groupId} | ${row.members} | ${roundMoney(row.businessRetained)} | ${roundMoney(row.ownerLaborDraw)} | ${roundMoney(row.wagesReceived)} | ${roundMoney(row.taxRentReceived)} | ${roundMoney(row.directPayrollPaid)} | ${roundMoney(row.totalCapture)} | ${round(row.captureShare * 100, 1)}% | ${row.notes} |`);
  }
  report.push("");
}

function renderRiskSection(report: string[], model: EconomyModel) {
  report.push("## Design Risks And Required Fixes");
  report.push("");
  for (const line of model.risks) report.push(`- ${line}`);
  report.push("");
}

function renderPriceSection(report: string[], catalog: Catalog, model: EconomyModel) {
  report.push("## Price Anchors");
  report.push("");
  report.push("| Item | Price | Basis | Cost | Labor | Margin |");
  report.push("|---|---:|---|---:|---:|---:|");
  for (const price of [...model.prices.values()].sort((a, b) => a.value - b.value || a.itemId.localeCompare(b.itemId))) {
    report.push(`| ${label(catalog.items, price.itemId)} | ${roundMoney(price.value)} | ${price.source} | ${roundMoney(price.cost)} | ${roundMoney(price.labor)} | ${roundMoney(price.margin)} |`);
  }
  report.push("");
}

function flowRows(items: Map<string, Item>, flows: Map<string, ItemFlow>) {
  return [...flows.entries()].map(([itemId, flow]) => {
    const net = flow.supply - flow.demand;
    const item = items.get(itemId);
    const status = flow.demand > 0 && net < -0.01
      ? "short"
      : flow.supply > 0 && flow.demand <= 0 && item?.hunger
        ? "reserve_food"
        : flow.supply > 0 && flow.demand <= 0
          ? "sink_missing"
          : "ok";
    return {
      itemId,
      name: label(items, itemId),
      supply: flow.supply,
      demand: flow.demand,
      net,
      status,
      notes: flow.notes.join(", "),
    };
  }).sort((a, b) => statusRank(a.status) - statusRank(b.status) || a.name.localeCompare(b.name));
}

function computePrices(
  items: Map<string, Item>,
  materials: Map<string, Material>,
  crops: Map<string, CropVariety>,
  recipes: Recipe[],
): Map<string, Price> {
  const prices = new Map<string, Price>();
  for (const [itemId, value] of Object.entries(ECONOMY.basePrices)) {
    if (!items.has(itemId)) continue;
    prices.set(itemId, { itemId, value, source: "base_anchor", cost: value, labor: 0, margin: 0 });
  }
  for (const crop of crops.values()) {
    const seedItem = [...items.values()].find((item) => item.cropVarietyId === crop.id);
    if (!seedItem || !items.has(crop.harvestYieldId)) continue;
    const seedPrice = prices.get(seedItem.id)?.value ?? ECONOMY.basePrices[seedItem.id] ?? 2;
    const cycleDays = crop.maturationHours / 24;
    const labor = ECONOMY.farmLaborHoursPerSlotDay * cycleDays * ECONOMY.laborSilverPerGameHour;
    const cost = (seedPrice + labor) / Math.max(1, crop.harvestYieldQuantity);
    const value = roundMoney(Math.max(prices.get(crop.harvestYieldId)?.value ?? 0, cost * 1.2));
    prices.set(crop.harvestYieldId, {
      itemId: crop.harvestYieldId,
      value,
      source: `crop:${crop.id}`,
      cost,
      labor,
      margin: value - cost,
    });
  }
  for (let pass = 0; pass < 8; pass += 1) {
    let changed = false;
    for (const recipe of recipes) {
      if (ECONOMY.fixedPriceItems.includes(recipe.outputItemId)) continue;
      const outputItem = items.get(recipe.outputItemId);
      if (!outputItem) continue;
      const inputPrices: number[] = [];
      for (const inputId of recipe.inputItemIds) {
        const inputPrice = prices.get(inputId)?.value;
        if (inputPrice == null) {
          inputPrices.length = 0;
          break;
        }
        inputPrices.push(inputPrice);
      }
      if (inputPrices.length !== recipe.inputItemIds.length) continue;
      const ingredientCost = inputPrices.reduce((sum, value) => sum + value, 0) / Math.max(1, recipe.outputQty);
      const overheadCost = Object.entries(ECONOMY.recipeOverheads[recipe.reactionId] ?? {}).reduce((sum, [itemId, qty]) => sum + qty * (prices.get(itemId)?.value ?? 0), 0);
      const failureMultiplier = 1 / Math.max(0.01, 1 - currentFailChance(recipe.difficulty));
      const labor = craftLabor(recipe.durationSeconds) / Math.max(1, recipe.outputQty);
      const perishability = perishabilityReserve(outputItem, materials);
      const margin = marginFor(outputItem);
      const value = roundMoney((ingredientCost * failureMultiplier + overheadCost + labor + perishability) * (1 + margin));
      const existing = prices.get(recipe.outputItemId);
      if (!existing || value < existing.value - 0.01 || existing.source === "base_anchor") {
        prices.set(recipe.outputItemId, { itemId: recipe.outputItemId, value, source: recipe.reactionId, cost: ingredientCost + overheadCost, labor, margin });
        changed = true;
      }
    }
    if (!changed) break;
  }
  return prices;
}

function loadLabels() {
  const itemJson = readJson<{ item?: Dict<{ name?: string }> }>("data/i18n/zh/items.json");
  const materialJson = readJson<{ material?: Dict<{ name?: string }> }>("data/i18n/zh/materials.json");
  return {
    items: Object.fromEntries(Object.entries(itemJson.item ?? {}).map(([id, value]) => [id, value.name ?? id])),
    materials: Object.fromEntries(Object.entries(materialJson.material ?? {}).map(([id, value]) => [id, value.name ?? id])),
  };
}

function loadMaterials(labels: Dict<string>): Map<string, Material> {
  const out = new Map<string, Material>();
  for (const path of listFiles(join(projectRoot, "data/materials"), ".tres")) {
    const raw = readFileSync(path, "utf8");
    const resource = resourceSection(raw);
    const id = stringField(resource, "id");
    if (!id) continue;
    out.set(id, {
      id,
      name: labels[id] ?? id,
      category: stringField(resource, "category"),
      transforms: dictionaryField(resource, "transforms"),
      alloys: dictionaryField(resource, "alloys"),
      tags: packedStringArrayField(resource, "tags"),
      shelfLifeHours: numberField(resource, "shelf_life_hours"),
    });
  }
  return out;
}

function loadItems(labels: Dict<string>, materials: Map<string, Material>): Map<string, Item> {
  const out = new Map<string, Item>();
  for (const path of listFiles(join(projectRoot, "data/items"), ".tres")) {
    const raw = readFileSync(path, "utf8");
    const resource = resourceSection(raw);
    const id = stringField(resource, "id");
    if (!id) continue;
    const itemMaterials = dictionaryField(resource, "materials");
    const material = materials.get(itemMaterials.body ?? "");
    const source = sourceField(resource);
    out.set(id, {
      id,
      name: labels[id] ?? material?.name ?? id,
      kind: stringField(resource, "kind"),
      shapeType: stringField(resource, "shape_type"),
      materials: itemMaterials,
      tags: packedStringArrayField(resource, "tags"),
      cropVarietyId: stringField(resource, "crop_variety_id"),
      hunger: effectAmount(source, "hunger"),
      stamina: effectAmount(source, "stamina"),
      shelfLifeHours: material?.shelfLifeHours ?? 0,
      sourcePath: relative(projectRoot, path),
    });
  }
  return out;
}

function addPseudoItems(items: Map<string, Item>, materialLabels: Dict<string>) {
  if (!items.has("water")) {
    items.set("water", {
      id: "water",
      name: materialLabels.water ?? "water",
      kind: "resource",
      shapeType: "fluid_pouch",
      materials: { body: "water" },
      tags: ["liquid"],
      cropVarietyId: "",
      hunger: 0,
      stamina: 0,
      shelfLifeHours: 0,
      sourcePath: "runtime/liquid_container",
    });
  }
}

function loadCropVarieties(): Map<string, CropVariety> {
  const raw = readProjectFile("data/mechanics/crops.lua");
  const out = new Map<string, CropVariety>();
  for (const [id, block] of extractNamedBlocks(raw, "varieties")) {
    out.set(id, {
      id,
      name: stringField(block, "display_name") || id,
      maturationHours: numberField(block, "maturation_hours"),
      harvestYieldId: stringField(block, "harvest_yield_id"),
      harvestYieldQuantity: numberField(block, "harvest_yield_quantity"),
    });
  }
  return out;
}

function loadReactions(): Reaction[] {
  const raw = readProjectFile("data/mechanics/crafting.lua");
  return extractNamedBlocks(raw, "reactions").map(([id, block]) => ({
    id,
    verb: stringField(block, "verb"),
    workstation: normalizeWorkstation(stringField(block, "workstation")),
    subOption: stringField(block, "sub_option"),
    materialStrategy: stringField(block, "material_strategy"),
    difficulty: numberField(block, "difficulty"),
    staminaCost: numberField(block, "stamina_cost"),
    durationSeconds: numberField(block, "duration_seconds"),
    inputs: parseInputs(block),
    outputs: parseOutputs(block),
    primaryInputIndices: numberArrayField(block, "primary_input_indices"),
    sourcePath: "data/mechanics/crafting.lua",
  }));
}

function expandRecipes(reactions: Reaction[], items: Map<string, Item>, materials: Map<string, Material>): Recipe[] {
  const recipes: Recipe[] = [];
  for (const reaction of reactions) {
    const candidateGroups = reaction.inputs.map((input) => candidateItemsForInput(input, items, materials));
    if (candidateGroups.some((group) => group.length === 0)) continue;
    for (const combo of cartesian(candidateGroups, 80)) {
      for (const output of reaction.outputs) {
        const outputItemId = resolveOutputItemId(reaction, output, combo, items, materials);
        if (!outputItemId || !items.has(outputItemId)) continue;
        recipes.push({
          id: `${reaction.id}:${combo.map((item) => item.id).join("+")}:${outputItemId}`,
          reactionId: reaction.id,
          workstation: reaction.workstation,
          outputItemId,
          outputQty: Math.max(1, output.qty),
          inputItemIds: combo.filter((_, index) => !reaction.inputs[index]?.tool).map((item) => item.id),
          requirementItemIds: combo.filter((_, index) => reaction.inputs[index]?.tool).map((item) => item.id),
          durationSeconds: reaction.durationSeconds,
          staminaCost: reaction.staminaCost,
          difficulty: reaction.difficulty,
        });
      }
    }
  }
  return uniqueRecipes(recipes);
}

function candidateItemsForInput(input: InputPredicate, items: Map<string, Item>, materials: Map<string, Material>): Item[] {
  if (input.itemId) {
    const item = items.get(input.itemId);
    return item ? [item] : [];
  }
  const out: Item[] = [];
  for (const item of items.values()) {
    if (input.shapeType && item.shapeType !== input.shapeType) continue;
    if (input.bodyMaterial && itemBody(item) !== input.bodyMaterial && item.id !== input.bodyMaterial) continue;
    if (input.bodyCategory) {
      const material = materials.get(itemBody(item));
      if (material?.category !== input.bodyCategory) continue;
    }
    if (input.tags.length > 0 && !input.tags.every((tag) => item.tags.includes(tag))) continue;
    out.push(item);
  }
  return out;
}

function resolveOutputItemId(reaction: Reaction, output: OutputSpec, inputs: Item[], items: Map<string, Item>, materials: Map<string, Material>): string | undefined {
  if (output.itemId) return output.itemId;
  const shapeType = output.shapeType ?? "";
  let bodyMaterial = output.bodyMaterial ?? "";
  if (!bodyMaterial && reaction.materialStrategy === "transform") {
    const primary = reaction.primaryInputIndices[0] ?? 0;
    bodyMaterial = materials.get(itemBody(inputs[primary]))?.transforms[reaction.verb] ?? "";
  } else if (!bodyMaterial && reaction.materialStrategy === "alloy") {
    const first = reaction.primaryInputIndices[0] ?? 0;
    const second = reaction.primaryInputIndices[1] ?? 1;
    bodyMaterial = materials.get(itemBody(inputs[first]))?.alloys[itemBody(inputs[second])] ?? "";
  } else if (!bodyMaterial && reaction.materialStrategy === "compose") {
    const firstInputBody = itemBody(inputs[0]);
    if (["flat_blade", "pick_head", "axe_head", "shaft", "plank", "rope"].includes(shapeType)) bodyMaterial = firstInputBody;
  }
  return findItemTemplate(items, shapeType, bodyMaterial);
}

function findItemTemplate(items: Map<string, Item>, shapeType: string, bodyMaterial: string): string | undefined {
  if (!shapeType) return undefined;
  for (const item of items.values()) {
    if (item.shapeType === shapeType && itemBody(item) === bodyMaterial) return item.id;
  }
  return undefined;
}

function loadFarmSlots(): Dict<number> {
  const raw = readProjectFile("src/levels/town.tscn");
  const out: Dict<number> = {};
  const farmHeader = /^\[node name="([^"]+)"[^\]]*parent="Farms"[^\]]*\]/gm;
  let match: RegExpExecArray | null;
  const farmNames = new Set<string>();
  while ((match = farmHeader.exec(raw)) !== null) farmNames.add(match[1] ?? "");
  for (const name of farmNames) {
    const slotRegex = new RegExp(`^\\[node name="FarmSlot_[^"]+"[^\\]]*parent="Farms/${escapeRegExp(name)}"[^\\]]*instance=ExtResource\\("19_slot"\\)\\]`, "gm");
    out[name] = [...raw.matchAll(slotRegex)].length;
  }
  return out;
}

function loadWorkstationCounts(): Dict<number> {
  const raw = readProjectFile("src/levels/town.tscn");
  const resourceToWorkstation: Dict<string> = {};
  for (const match of raw.matchAll(/\[ext_resource[^\]]*path="res:\/\/src\/sim\/workstations\/([a-z_]+)_workstation_node\.tscn"[^\]]*id="([^"]+)"[^\]]*\]/g)) {
    const workstation = normalizeWorkstation(match[1] ?? "");
    const resourceId = match[2] ?? "";
    if (workstation && resourceId) resourceToWorkstation[resourceId] = workstation;
  }
  const out: Dict<number> = {};
  for (const [resourceId, workstation] of Object.entries(resourceToWorkstation)) {
    const regex = new RegExp(`instance=ExtResource\\("${escapeRegExp(resourceId)}"\\)`, "g");
    const count = [...raw.matchAll(regex)].length;
    if (count > 0) out[workstation] = (out[workstation] ?? 0) + count;
  }
  return out;
}

// group_id → 该组的初始 NPC id 列表。源是 npcs.json 每个 NPC 的 groups[]，反向聚合。
// （不再读 groups.json——已删，归属真值在 npcs.json + Godot 场景树 *.owner_group）
function buildGroupMembersFromNpcs(): Map<string, string[]> {
  const raw = readJson<Dict<{ groups?: unknown }>>("backend/data/town/npcs.json");
  const out = new Map<string, string[]>();
  for (const [npcId, def] of Object.entries(raw)) {
    for (const groupId of stringArray(def.groups)) {
      const list = out.get(groupId) ?? [];
      list.push(npcId);
      out.set(groupId, list);
    }
  }
  return out;
}

// 离线复刻 TownWorld._resolve_owner_group：扫 town.tscn 里 Positions/ 子树的 LocationMarker，
// 按节点 parent 路径建链，按 ""=继承父 / "public"=显式公用 / 其他=字面值 解析每个 location 的 group。
// 返回 group_id → 该 group 拥有的 location 节点名列表。
function loadGroupToLocations(): Map<string, string[]> {
  const raw = readProjectFile("src/levels/town.tscn");
  // 找 location_marker.tscn 的 ExtResource id（理论是固定的 "22_locm"，但保险起见 regex 解析）。
  const locResourceMatch = raw.match(/\[ext_resource[^\]]*path="res:\/\/src\/world\/location_marker\.tscn"[^\]]*id="([^"]+)"[^\]]*\]/);
  if (!locResourceMatch) return new Map();
  const locResourceId = locResourceMatch[1] ?? "";
  type Entry = { name: string; parentPath: string; ownGroup: string };
  const entriesByPath = new Map<string, Entry>();
  // [node name="X" parent="..." instance=ExtResource("22_locm")]\n ...properties... 直到下一个 [
  const nodeBlockRegex = new RegExp(
    `\\[node name="([^"]+)"[^\\]]*parent="([^"]+)"[^\\]]*instance=ExtResource\\("${escapeRegExp(locResourceId)}"\\)\\]([\\s\\S]*?)(?=\\n\\[|$)`,
    "g",
  );
  for (const match of raw.matchAll(nodeBlockRegex)) {
    const name = match[1] ?? "";
    const parentPath = match[2] ?? "";
    const body = match[3] ?? "";
    // 限定在 Positions/ 子树——LocationMarker 偶尔也出现在别处时不参与归属继承。
    if (parentPath !== "Positions" && !parentPath.startsWith("Positions/")) continue;
    const ownGroup = body.match(/^owner_group\s*=\s*"([^"]*)"/m)?.[1] ?? "";
    const fullPath = `${parentPath}/${name}`;
    entriesByPath.set(fullPath, { name, parentPath, ownGroup });
  }
  const resolved = new Map<string, string>(); // fullPath → resolved owner_group ("" = public)
  function resolve(fullPath: string): string {
    const cached = resolved.get(fullPath);
    if (cached !== undefined) return cached;
    const entry = entriesByPath.get(fullPath);
    if (!entry) {
      // 父非 LocationMarker（如 root "Positions"）→ public
      resolved.set(fullPath, "");
      return "";
    }
    let result: string;
    if (entry.ownGroup === "public") {
      result = "";
    } else if (entry.ownGroup.length > 0) {
      result = entry.ownGroup;
    } else {
      result = resolve(entry.parentPath);
    }
    resolved.set(fullPath, result);
    return result;
  }
  const out = new Map<string, string[]>();
  for (const [fullPath, entry] of entriesByPath) {
    const group = resolve(fullPath);
    if (!group) continue;
    const list = out.get(group) ?? [];
    list.push(entry.name);
    out.set(group, list);
  }
  return out;
}

function loadNpcData(): Map<string, NpcDefinition> {
  const raw = readJson<Dict<{ name?: unknown; age?: unknown; skills?: unknown; other?: unknown; groups?: unknown }>>("backend/data/town/npcs.json");
  const out = new Map<string, NpcDefinition>();
  for (const [id, value] of Object.entries(raw)) {
    out.set(id, {
      name: typeof value.name === "string" ? value.name : id,
      age: typeof value.age === "number" ? value.age : 0,
      skills: stringArray(value.skills),
      other: stringArray(value.other),
      groups: stringArray(value.groups),
    });
  }
  return out;
}

function loadMineTargets(): Dict<number> {
  const raw = readProjectFile("src/autoload/mines.gd");
  const block = raw.match(/const _SEED: Dictionary = \{([\s\S]*?)\n\}/)?.[1] ?? "";
  const out: Dict<number> = {};
  for (const match of block.matchAll(/"([^"]+)"\s*:\s*([0-9.]+)/g)) out[match[1] ?? ""] = Number(match[2] ?? 0);
  return out;
}

function loadRuntimeWagePolicy(): RuntimeWagePolicy {
  const raw = readProjectFile("src/characters/parts/backend_action_runner.gd");
  const minerBlock = raw.match(/const _MINER_IDS: Array = \[([^\]]*)\]/)?.[1] ?? "";
  const rateBlock = raw.match(/const _ORE_RATE: Dictionary = \{([\s\S]*?)\n\}/)?.[1] ?? "";
  const weeklyBlock = raw.match(/const _WEEKLY_ROLES: Dictionary = \{([\s\S]*?)\n\}/)?.[1] ?? "";
  const oreRates: Dict<number> = {};
  for (const match of rateBlock.matchAll(/"([^"]+)"\s*:\s*([0-9.]+)/g)) oreRates[match[1] ?? ""] = Number(match[2] ?? 0);
  const weeklyRoles: Dict<{ weekday: number; amount: number }> = {};
  for (const match of weeklyBlock.matchAll(/"([^"]+)"\s*:\s*\{\s*"weekday"\s*:\s*([0-9]+),\s*"amount"\s*:\s*([0-9]+)/g)) {
    weeklyRoles[match[1] ?? ""] = { weekday: Number(match[2] ?? 0), amount: Number(match[3] ?? 0) };
  }
  return { minerIds: stringsIn(minerBlock), oreRates, weeklyRoles };
}

function parseInputs(block: string): InputPredicate[] {
  const inputsBlock = objectFieldBlock(block, "inputs");
  if (!inputsBlock) return [];
  return topLevelObjects(inputsBlock).map((entry) => ({
    itemId: stringField(entry, "item_id") || undefined,
    shapeType: stringField(entry, "shape_type") || undefined,
    bodyMaterial: bracketStringField(entry, "materials.body") || undefined,
    bodyCategory: bracketStringField(entry, "materials.body.category") || undefined,
    tags: inlineStringArrayField(entry, "tags"),
    tool: boolField(entry, "tool"),
  }));
}

function parseOutputs(block: string): OutputSpec[] {
  const outputsBlock = objectFieldBlock(block, "outputs");
  if (!outputsBlock) return [];
  return generateBlocks(outputsBlock).map((generate) => ({
    itemId: stringField(generate, "item_id") || undefined,
    shapeType: stringField(generate, "shape_type") || undefined,
    bodyMaterial: nestedStringField(generate, "materials", "body") || undefined,
    qty: numberField(generate, "qty") || 1,
  }));
}

function parseNamedBlocksFromObject(text: string, startIndex: number): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  let i = startIndex + 1;
  const end = findMatchingBrace(text, startIndex);
  while (i < end) {
    const match = /([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{/y;
    match.lastIndex = skipTrivia(text, i);
    const result = match.exec(text);
    if (!result) {
      i += 1;
      continue;
    }
    const id = result[1] ?? "";
    const blockStart = match.lastIndex - 1;
    const blockEnd = findMatchingBrace(text, blockStart);
    out.push([id, text.slice(blockStart, blockEnd + 1)]);
    i = blockEnd + 1;
  }
  return out;
}

function extractNamedBlocks(text: string, tableName: string): Array<[string, string]> {
  const tableMatch = new RegExp(`${tableName}\\s*=\\s*\\{`).exec(text);
  if (!tableMatch) return [];
  const start = (tableMatch.index ?? 0) + tableMatch[0].lastIndexOf("{");
  return parseNamedBlocksFromObject(text, start);
}

function objectFieldBlock(text: string, field: string): string | undefined {
  const match = new RegExp(`${escapeRegExp(field)}\\s*=\\s*\\{`).exec(text);
  if (!match) return undefined;
  const start = match.index + match[0].lastIndexOf("{");
  const end = findMatchingBrace(text, start);
  return text.slice(start, end + 1);
}

function topLevelObjects(text: string): string[] {
  const out: string[] = [];
  for (let i = 1; i < text.length - 1; i += 1) {
    if (text[i] !== "{") continue;
    const end = findMatchingBrace(text, i);
    out.push(text.slice(i, end + 1));
    i = end;
  }
  return out;
}

function generateBlocks(text: string): string[] {
  const out: string[] = [];
  const regex = /generate\s*=\s*\{/g;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(text)) !== null) {
    const start = match.index + match[0].lastIndexOf("{");
    const end = findMatchingBrace(text, start);
    out.push(text.slice(start, end + 1));
    regex.lastIndex = end + 1;
  }
  return out;
}

function findMatchingBrace(text: string, start: number): number {
  let depth = 0;
  let quote = "";
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (quote) {
      if (ch === "\\") i += 1;
      else if (ch === quote) quote = "";
      continue;
    }
    if (ch === "-" && next === "-") {
      while (i < text.length && text[i] !== "\n") i += 1;
      continue;
    }
    if (ch === "\"" || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  throw new Error(`Unmatched brace near ${start}`);
}

function skipTrivia(text: string, index: number): number {
  let i = index;
  while (i < text.length) {
    if (/\s/.test(text[i] ?? "") || text[i] === ",") {
      i += 1;
      continue;
    }
    if (text[i] === "-" && text[i + 1] === "-") {
      while (i < text.length && text[i] !== "\n") i += 1;
      continue;
    }
    break;
  }
  return i;
}

function readJson<T>(path: string): T {
  return JSON.parse(readProjectFile(path)) as T;
}

function readProjectFile(path: string): string {
  return readFileSync(join(projectRoot, path), "utf8");
}

function resourceSection(text: string): string {
  const index = text.indexOf("[resource]");
  return index >= 0 ? text.slice(index) : text;
}

function listFiles(dir: string, suffix: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return listFiles(path, suffix);
    return entry.isFile() && entry.name.endsWith(suffix) ? [path] : [];
  });
}

function stringField(text: string, field: string): string {
  return new RegExp(`(?:^|[\\s,{])${escapeRegExp(field)}\\s*=\\s*"([^"]*)"`, "m").exec(text)?.[1] ?? "";
}

function bracketStringField(text: string, key: string): string {
  return new RegExp(`\\["${escapeRegExp(key)}"\\]\\s*=\\s*"([^"]*)"`).exec(text)?.[1] ?? "";
}

function nestedStringField(text: string, field: string, key: string): string {
  const block = objectFieldBlock(text, field);
  if (!block) return "";
  const colonValue = new RegExp(`"${escapeRegExp(key)}"\\s*:\\s*"([^"]*)"`).exec(block)?.[1] ?? "";
  return stringField(block, key) || colonValue;
}

function numberField(text: string, field: string): number {
  const value = new RegExp(`(?:^|[\\s,{])${escapeRegExp(field)}\\s*=\\s*([-0-9.]+)`, "m").exec(text)?.[1];
  return value == null ? 0 : Number(value);
}

function boolField(text: string, field: string): boolean {
  return new RegExp(`(?:^|[\\s,{])${escapeRegExp(field)}\\s*=\\s*true`, "m").test(text);
}

function numberArrayField(text: string, field: string): number[] {
  const block = objectFieldBlock(text, field);
  if (!block) return [];
  return [...block.matchAll(/[-0-9.]+/g)].map((match) => Number(match[0]));
}

function dictionaryField(text: string, field: string): Dict<string> {
  const block = objectFieldBlock(text, field);
  if (!block) return {};
  const out: Dict<string> = {};
  for (const match of block.matchAll(/"([^"]+)"\s*[:=]\s*"([^"]*)"/g)) out[match[1] ?? ""] = match[2] ?? "";
  return out;
}

function packedStringArrayField(text: string, field: string): string[] {
  const match = new RegExp(`${escapeRegExp(field)}\\s*=\\s*PackedStringArray\\(([^)]*)\\)`).exec(text);
  return match ? stringsIn(match[1] ?? "") : [];
}

function inlineStringArrayField(text: string, field: string): string[] {
  const block = objectFieldBlock(text, field);
  return block ? stringsIn(block) : [];
}

function stringsIn(text: string): string[] {
  return [...text.matchAll(/"([^"]+)"/g)].map((match) => match[1] ?? "");
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : [];
}

function sourceField(text: string): string {
  return /source\s*=\s*"([\s\S]*?)"\n/.exec(text)?.[1] ?? "";
}

function effectAmount(source: string, effect: "hunger" | "stamina"): number {
  const match = new RegExp(`affect\\.${effect}\\([^,]+,\\s*([0-9.]+)\\s*\\*\\s*q`).exec(source);
  return match ? Number(match[1]) : 0;
}

function itemBody(item: Item | undefined): string {
  return item?.materials.body ?? "";
}

function cartesian<T>(groups: T[][], limit: number): T[][] {
  let out: T[][] = [[]];
  for (const group of groups) {
    const next: T[][] = [];
    for (const prefix of out) {
      for (const item of group) {
        next.push([...prefix, item]);
        if (next.length >= limit) break;
      }
      if (next.length >= limit) break;
    }
    out = next;
  }
  return out;
}

function uniqueRecipes(recipes: Recipe[]): Recipe[] {
  const seen = new Set<string>();
  const out: Recipe[] = [];
  for (const recipe of recipes) {
    const key = `${recipe.reactionId}|${recipe.outputItemId}|${recipe.inputItemIds.join("+")}|${recipe.requirementItemIds.join("+")}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(recipe);
  }
  return out;
}

function craftLabor(durationSeconds: number): number {
  const hours = durationSeconds / 3600;
  return Math.max(ECONOMY.minimumCraftLaborSilver, hours * ECONOMY.laborSilverPerGameHour);
}

function currentFailChance(difficulty: number): number {
  return Math.max(0, Math.min(1, difficulty - 0.4));
}

function perishabilityReserve(item: Item, materials: Map<string, Material>): number {
  const shelfLife = item.shelfLifeHours || materials.get(itemBody(item))?.shelfLifeHours || 0;
  if (shelfLife <= 0) return 0;
  if (shelfLife >= 168) return 0.1;
  if (shelfLife >= 72) return 0.2;
  if (shelfLife >= 24) return 0.35;
  return 0.6;
}

function marginFor(item: Item): number {
  if (item.kind === "tool") return 0.35;
  if (item.kind === "food") return 0.22;
  if (item.kind === "part") return 0.15;
  return ECONOMY.defaultMargin;
}

function normalizeWorkstation(value: string): string {
  return value.replace(/_workstation$/, "");
}

function sectorForWorkstation(workstation: string): string {
  if (workstation === "mill") return "milling";
  if (workstation === "stove") return "tavern";
  if (["forge", "anvil"].includes(workstation)) return "blacksmith_shop";
  if (workstation === "workbench") return "blacksmith_shop";
  if (workstation.includes("mine")) return "royal_mines";
  return "unassigned";
}

function sectorLabel(sectorId: string): string {
  return SECTORS.find((sector) => sector.id === sectorId)?.name ?? sectorId;
}

function npcName(catalog: Catalog, npcId: string): string {
  return catalog.npcs.get(npcId)?.name ?? npcId;
}

function label(items: Map<string, Item>, itemId: string): string {
  const item = items.get(itemId);
  return item ? `${item.name} (${item.id})` : itemId;
}

function formatWorkstationCounts(counts: Dict<number>): string {
  const entries = Object.entries(counts).sort(([a], [b]) => a.localeCompare(b));
  return entries.length > 0 ? entries.map(([id, count]) => `${id} x${count}`).join(", ") : "none";
}

function formatCapacity(value: number): string {
  return Number.isFinite(value) ? String(round(value, 2)) : "unlimited";
}

function statusRank(status: string): number {
  if (status === "short" || status === "missing_station") return 0;
  if (status === "sink_missing") return 1;
  if (status === "reserve_food") return 2;
  if (status === "ok") return 3;
  return 4;
}

function pushUnique(map: Dict<string[]>, key: string, value: string) {
  const list = map[key] ?? [];
  if (!list.includes(value)) list.push(value);
  map[key] = list;
}

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values)];
}

function round(value: number, digits: number): number {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

function roundMoney(value: number): number {
  return round(value, 2);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

main();
