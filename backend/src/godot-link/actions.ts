// Single source of truth for the backend ↔ Godot action wire contract.
// Tool-factory must produce these exact shapes. Godot must read these exact keys.
// No translation layer between (see action-log-service.ts: stores & forwards as-is).

export const SAY_TO_ACTION = "say_to";
export const SLEEP_ACTION = "sleep";

export const ACTION_NAMES = [
  "move_to_location",
  SAY_TO_ACTION,
  SLEEP_ACTION,
  "drop_item",
  // offer：request:[] 时是单向赠送（同步转移 + 发 give 事件），
  // request 非空时是议价交易（写 trade_offers，阻塞等对方 respond）。
  "offer",
  // respond：加 kind 字段 dispatch。目前只 kind="trade"，
  // 未来扩 request_join_group 等新 kind 时只加 dispatch case 即可，不再 rename tool。
  "respond",
  "create_item",
  "use_item",
  // 工作台 axis actions —— 见 backend/src/agent-shared/game-tools/craft-registry.ts。
  // 每个 axis 一个 wire action，共享 WorkstationActionTarget shape；Godot 端走同一个
  // start_workstation_action() 派发。
  "mine",
  "chop_wood",
  "woodwork",
  "burn_charcoal",
  "smelt",
  "smith",
  "assemble",
  "cook",
  "alchemy",
  "mill_grain",
  "boil_salt",
  "plant_seed",
  "water_crop",
  "harvest_crop",
  "remove_pest",
  "plan_farm_work",
  "put",
  "take",
  "brew",
  "write",
  "read",
] as const;

export type ActionName = (typeof ACTION_NAMES)[number];
export type CharacterAction = ActionName;

export function isKnownActionName(name: string): name is ActionName {
  return (ACTION_NAMES as readonly string[]).includes(name);
}

// ───────────────────────────── targets ─────────────────────────────

// Exactly one of these fields will be present per call.
export type MoveToLocationTarget = {
  locationId?: string;
  characterId?: string;
  itemId?: string;
  regionId?: string;
};

export type SayToTarget = {
  targetCharacterId: string;
  text: string;
  volume: "near" | "far" | "shout";
};

export type SleepTarget = {
  durationGameMinutes: number;
};

// slotIndex 是 item_instances 表的真 primary key（按 ownerKind+ownerId 唯一）。
// backend 把 LLM 给的 {name, index} 反查成 slotIndex 发过来，Godot 按 slotIndex 直接定位栈。
// undefined = 来源没有 slotIndex 时，Godot 按 itemId 选默认实例。
// quantity = drop 的份数；缺省 = 1。
export type ItemTarget = {
  itemId: string;
  slotIndex?: number;
  quantity?: number;
};

export type UseItemTarget = {
  itemId: string;
  slotIndex?: number;
  targetId?: string;
};

// priceSilver 是 decimal silver（1 silver = 100 centi）。GDScript 端 round 到 centi int 存储。
// Trade line：我方付出 (offer) 时 slotIndex 指向我背包里具体那份 stack；
// 对方付出 (request) 是描述，对方背包对发起方不可见，slotIndex 留空，对方履约时按 itemId 自选。
export type TradeLine = { item: string; count: number; slotIndex?: number };

// request: [] 时 Godot 走 _run_give 单向赠送分支（不写 trade_offers，立即发 give 事件）；
// request 非空时走 trade.lua 谈判流程。schema 是交易报价目标。
export type OfferTarget = {
  characterId: string;
  offer: TradeLine[];
  request: TradeLine[];
};

// kind 必填。"trade" 走原 trade.lua on_respond；未来加新 kind 时 Godot _run_respond
// 内 dispatch + 加新 lua mechanic 文件，tool name 不再 rename。
// buyerCharacterId 是 kind="trade" 下的字段名；未来 kind 可能用不同字段定位被回应对象。
export type RespondTarget = {
  kind: string;
  buyerCharacterId?: string;
  response: "accept" | "reject";
};

// 所有 axis action（mine / chop_wood / woodwork / smelt / smith / assemble / cook / ...）
// 共享同一 target shape。TS 工厂根据 craft-registry 的  填好 workstationId/verb/subOption，
// Godot 端 start_workstation_action 不区分 axis（action 名只用于事件路由 + 文案识别）。
export type WorkstationActionTarget = {
  workstationId: string;
  verb?: string;
  subOption?: string;
  inputItemIds: string[];
  // 与 inputItemIds 一一对应；item_instances.slotIndex（背包槽位 id）。
  // undefined 表示该输入没有对应 slotIndex（材料来自 catalog 而非具体堆叠等罕见情况），
  // Godot 按 itemId 自选；正常 LLM 提交的输入都应有 slotIndex。
  inputItemSlotIndices?: (number | undefined)[];
};


// PlanFarmWorkOp.slotIndex 是农田 plot 序号（与 itemDefId 无关），别和 seedSlotIndex 搞混。
export type PlanFarmWorkOp = {
  kind: "plant" | "pest" | "harvest" | "uproot" | "water";
  slotIndex?: number;
  seedItemId?: string;
  seedSlotIndex?: number;
};

export type PlanFarmWorkTarget = {
  farmId: string;
  ops: PlanFarmWorkOp[];
};

// put/take：背包与一个附近储物目标之间搬运。一串 transfers，每条仍用统一 endpoint wire。
// 容器 endpoint：背包 / 附近容器 node（仓库·货架·工作台储物·水井）/ 它们里的容器 item。
// 液体按升加权混合品质；若 liquid.to 指背包/容器/货架本身且无 slotIndex，Godot 会按
// drink item 的 serving_liters 把桶装液体转成离散物品（如 beer）。离散按个数（背包侧货币走钱包）。
// Godot ContainerHandlers 执行。
export type ContainerEndpoint = {
  where: "backpack" | "node" | "ground" | "well";
  containerId?: string;   // where=node/well
  slotIndex?: number;     // where=backpack（液体容器 item 槽）/ node（容器内某 item 槽）
  groundItemId?: string;  // where=ground
  isShelf?: boolean;      // node 是货架（上架可带 priceCenti；取货按标价校验付款）
  priceCenti?: number;
};

export type TransferWire = {
  kind: "item" | "liquid";
  amount: number;
  itemId?: string;        // kind=item：搬哪种离散物
  from: ContainerEndpoint;
  to: ContainerEndpoint;
};

export type ContainerTransferTarget = {
  transfers: TransferWire[];
};

// brew：装水的酿酒桶 + 背包麦芽 → 发酵中的酒。barrel = 酿酒桶所在 endpoint。
export type BrewTarget = {
  barrel: ContainerEndpoint;
};

// write/read: 通用可书写/可阅读物品机制。write 消耗或转化一个可书写道具（比如纸）
// 成命名物品；read 按名字查可阅读物品取出 content。当前没有 writable/readable 的实物，
// 但保留 hook 供 LLM 调用——并且 Godot 端对玛格达 + "王室薪水记录" 做脏检查走虚拟账本路径。
export type WriteTarget = {
  itemName: string;
  title: string;
  content: string;
};

export type ReadTarget = {
  title: string;
};

// Vestigial: create_item never enters the action-log wire path (it goes through
// emitWorldEvent directly). Kept only so ACTION_NAMES / ActionTargetByName stay
// exhaustive for isKnownActionName.
export type CreateItemTargetUnused = Record<string, never>;

// Vestigial: plant_seed/water_crop/harvest_crop/remove_pest are only invoked
// from Godot's internal plan_farm_work queue; tool-factory never submits them.
export type FarmingSubActionTargetUnused = Record<string, never>;

export type ActionTargetByName = {
  move_to_location: MoveToLocationTarget;
  say_to: SayToTarget;
  sleep: SleepTarget;
  drop_item: ItemTarget;
  offer: OfferTarget;
  respond: RespondTarget;
  create_item: CreateItemTargetUnused;
  use_item: UseItemTarget;
  // axis actions —— 全部共用 WorkstationActionTarget shape。
  mine: WorkstationActionTarget;
  chop_wood: WorkstationActionTarget;
  woodwork: WorkstationActionTarget;
  burn_charcoal: WorkstationActionTarget;
  smelt: WorkstationActionTarget;
  smith: WorkstationActionTarget;
  assemble: WorkstationActionTarget;
  cook: WorkstationActionTarget;
  alchemy: WorkstationActionTarget;
  mill_grain: WorkstationActionTarget;
  boil_salt: WorkstationActionTarget;
  plant_seed: FarmingSubActionTargetUnused;
  water_crop: FarmingSubActionTargetUnused;
  harvest_crop: FarmingSubActionTargetUnused;
  remove_pest: FarmingSubActionTargetUnused;
  plan_farm_work: PlanFarmWorkTarget;
  put: ContainerTransferTarget;
  take: ContainerTransferTarget;
  brew: BrewTarget;
  write: WriteTarget;
  read: ReadTarget;
};

export type ActionTarget<TName extends ActionName = ActionName> = ActionTargetByName[TName];

export type ActionRequest<TName extends ActionName = ActionName> = {
  id: string;
  characterId: string;
  name: TName;
  target: ActionTarget<TName>;
  options?: Record<string, unknown>;
  reason?: string;
  priority?: number;
  expiresAt?: string;
};

export const ACTION_ACK_STATUSES = ["accepted", "completed", "failed", "cancelled", "interrupted"] as const;
export type ActionAckStatus = (typeof ACTION_ACK_STATUSES)[number];

export function isActionAckStatus(status: string): status is ActionAckStatus {
  return (ACTION_ACK_STATUSES as readonly string[]).includes(status);
}

// ───────────────────────────── results ─────────────────────────────
// GDScript already emits these shapes; results are not double-translated like
// targets were. Keep the existing canonical names.

export type PlanFarmWorkResult = {
  completed?: Array<Record<string, unknown>>;
  remaining?: Array<Record<string, unknown>>;
  interrupted?: boolean;
  reason?: string;
};

export type ActionResultByName = {
  move_to_location: { elapsedGameMinutes?: number };
  say_to: {
    targetCharacterId?: string;
    text?: string;
    volume?: "near" | "far" | "shout";
    affectedCharacterIds?: string[];
    heardByCharacterIds?: string[];
  };
  sleep: { wokeAt?: string; interrupted?: boolean; durationGameMinutes?: number; wakeReason?: string };
  drop_item: { itemId?: string; quantity?: number };
  // request:[] 时 result 含 recipientCharacterId + transferred:[{itemId, requested, transferred}]；
  // request 非空时仍是 {tradeId?} 走原 trade.lua 路径。
  offer: { tradeId?: string; recipientCharacterId?: string; transferred?: Array<{ itemId: string; requested: number; transferred: number }> };
  respond: { tradeId?: string; response?: "accept" | "reject" };
  create_item: { itemId?: string };
  use_item: { itemId?: string; quantity?: number };
  mine: Record<string, unknown>;
  chop_wood: Record<string, unknown>;
  woodwork: Record<string, unknown>;
  burn_charcoal: Record<string, unknown>;
  smelt: Record<string, unknown>;
  smith: Record<string, unknown>;
  assemble: Record<string, unknown>;
  cook: Record<string, unknown>;
  alchemy: Record<string, unknown>;
  mill_grain: Record<string, unknown>;
  boil_salt: Record<string, unknown>;
  plant_seed: Record<string, unknown>;
  water_crop: Record<string, unknown>;
  harvest_crop: Record<string, unknown>;
  remove_pest: Record<string, unknown>;
  plan_farm_work: PlanFarmWorkResult;
  put: { moves?: Array<{ kind?: string; itemId?: string; content?: string; amount?: number }> };
  take: { moves?: Array<{ kind?: string; itemId?: string; content?: string; amount?: number }> };
  brew: { liters?: number; ceiling?: number };
  write: { itemName?: string; title?: string };
  read: { title?: string; content?: string };
};

export type ActionResult<TName extends ActionName = ActionName> = ActionResultByName[TName];

export type ActionAck<TName extends ActionName = ActionName> = {
  actionId: string;
  characterId: string;
  name: TName;
  status: ActionAckStatus;
  error?: string;
  result?: ActionResult<TName>;
};
