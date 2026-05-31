// Single source of truth for the backend ↔ Godot action wire contract.
// Tool-factory must produce these exact shapes. Godot must read these exact keys.
// No translation layer between (see action-log-service.ts: stores & forwards as-is).

export const SAY_TO_ACTION = "say_to";
export const SLEEP_ACTION = "sleep";

export const ACTION_NAMES = [
  "move_to_location",
  SAY_TO_ACTION,
  SLEEP_ACTION,
  "pick_up_item",
  "drop_item",
  "update_shelf",
  "buy_from_shelf",
  // offer：原 offer_trade。request:[] 时是单向赠送（同步转移 + 发 give 事件），
  // request 非空时是议价交易（写 trade_offers，阻塞等对方 respond）。
  "offer",
  // respond：原 respond_to_trade，加 kind 字段 dispatch。目前只 kind="trade"，
  // 未来扩 request_join_group 等新 kind 时只加 dispatch case 即可，不再 rename tool。
  "respond",
  "create_item",
  "use_item",
  // 工作台 axis actions —— 见 backend/src/agent-shared/game-tools/craft-registry.ts。
  // 每个 axis 一个 wire action，共享 WorkstationActionTarget shape；Godot 端走同一个
  // start_workstation_action() 派发。draw_water（well 直接使用型）也走同一路径。
  "mine",
  "woodwork",
  "burn_charcoal",
  "smelt",
  "smith",
  "assemble",
  "cook",
  "mill_grain",
  "boil_salt",
  "draw_water",
  "plant_seed",
  "water_crop",
  "harvest_crop",
  "remove_pest",
  "plan_farm_work",
  "deposit_to_container",
  "withdraw_from_container",
  "inspect_container",
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
// undefined = 来源没有 slotIndex（pick_up_item 等 perception 不暴露 instance id 的场景），
// Godot 按 itemId 选最近/默认实例（旧行为）。
// quantity = drop/pickup 的份数；缺省 = 1。
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
// 例：priceSilver=7.5 → 750 centi。中世纪 cut coinage 允许半币 / 1/4 币找零。
// add 是从背包补货 → 带 slotIndex（背包 stack id）让 Godot 取对那份。
// update / remove 针对已有 listing → 带 listingId（货架 listing 表的真 id）。
export type ShelfOp =
  | { type: "add"; itemId: string; slotIndex?: number; quantity: number; priceSilver: number }
  | { type: "update"; itemId: string; listingId?: string; quantity: number; priceSilver: number }
  | { type: "remove"; itemId: string; listingId?: string; quantity?: number };

export type UpdateShelfTarget = {
  shelfId: string;
  ops: ShelfOp[];
};

export type BuyFromShelfTarget = {
  shelfId: string;
  listingId: string;
  quantity: number;
};

// Trade line：我方付出 (offer) 时 slotIndex 指向我背包里具体那份 stack；
// 对方付出 (request) 是描述，对方背包对发起方不可见，slotIndex 留空，对方履约时按 itemId 自选。
export type TradeLine = { item: string; count: number; slotIndex?: number };

// request: [] 时 Godot 走 _run_give 单向赠送分支（不写 trade_offers，立即发 give 事件）；
// request 非空时走 trade.lua 原有谈判流程。schema 与历史 OfferTradeTarget 一致。
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

// 所有 axis action（mine / woodwork / smelt / smith / assemble / cook / ...）+ draw_water
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

// withdraw_from_container.containerSlotIndex = 容器内 item_instances.slotIndex（take 走这个）；
// deposit_to_container.actorSlotIndex = 背包 slotIndex（put 走这个）。
// 没传时 Godot 按 itemId 自选（旧行为兜底）。
export type ContainerItemTarget = {
  containerId: string;
  itemId: string;
  quantity: number;
  containerSlotIndex?: number;
  actorSlotIndex?: number;
};

export type InspectContainerTarget = {
  containerId: string;
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
  pick_up_item: ItemTarget;
  drop_item: ItemTarget;
  update_shelf: UpdateShelfTarget;
  buy_from_shelf: BuyFromShelfTarget;
  offer: OfferTarget;
  respond: RespondTarget;
  create_item: CreateItemTargetUnused;
  use_item: UseItemTarget;
  // axis actions —— 全部共用 WorkstationActionTarget shape。
  mine: WorkstationActionTarget;
  woodwork: WorkstationActionTarget;
  burn_charcoal: WorkstationActionTarget;
  smelt: WorkstationActionTarget;
  smith: WorkstationActionTarget;
  assemble: WorkstationActionTarget;
  cook: WorkstationActionTarget;
  mill_grain: WorkstationActionTarget;
  boil_salt: WorkstationActionTarget;
  draw_water: WorkstationActionTarget;
  plant_seed: FarmingSubActionTargetUnused;
  water_crop: FarmingSubActionTargetUnused;
  harvest_crop: FarmingSubActionTargetUnused;
  remove_pest: FarmingSubActionTargetUnused;
  plan_farm_work: PlanFarmWorkTarget;
  deposit_to_container: ContainerItemTarget;
  withdraw_from_container: ContainerItemTarget;
  inspect_container: InspectContainerTarget;
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
  pick_up_item: { itemId?: string; quantity?: number };
  drop_item: { itemId?: string; quantity?: number };
  update_shelf: { shelfId?: string };
  buy_from_shelf: { shelfId?: string; listingId?: string; quantity?: number };
  // request:[] 时 result 含 recipientCharacterId + transferred:[{itemId, requested, transferred}]；
  // request 非空时仍是 {tradeId?} 走原 trade.lua 路径。
  offer: { tradeId?: string; recipientCharacterId?: string; transferred?: Array<{ itemId: string; requested: number; transferred: number }> };
  respond: { tradeId?: string; response?: "accept" | "reject" };
  create_item: { itemId?: string };
  use_item: { itemId?: string; quantity?: number };
  mine: Record<string, unknown>;
  woodwork: Record<string, unknown>;
  burn_charcoal: Record<string, unknown>;
  smelt: Record<string, unknown>;
  smith: Record<string, unknown>;
  assemble: Record<string, unknown>;
  cook: Record<string, unknown>;
  mill_grain: Record<string, unknown>;
  boil_salt: Record<string, unknown>;
  draw_water: Record<string, unknown>;
  plant_seed: Record<string, unknown>;
  water_crop: Record<string, unknown>;
  harvest_crop: Record<string, unknown>;
  remove_pest: Record<string, unknown>;
  plan_farm_work: PlanFarmWorkResult;
  deposit_to_container: { containerId?: string; itemId?: string; quantity?: number };
  withdraw_from_container: { containerId?: string; itemId?: string; quantity?: number };
  inspect_container: { containerId?: string; snapshot?: Record<string, unknown> };
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
