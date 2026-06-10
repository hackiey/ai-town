import { StringEnum, Type, type Static } from "@mariozechner/pi-ai";
import { getCraftSpec, type CraftSlug } from "./craft-registry.js";
import { td, toolReasonDescription } from "./i18n.js";

// 历史上这些 schema 会把附近角色 / 工作台 / 货架等动态名字烤进 enum，每次感知变化都让
// tools 段 prompt cache miss。现在统一退化成 free-form Type.String，合法取值通过 tool
// description 指向 user message 的对应 # 段（# 附近人物 / # 当前附近工作台 / ...），LLM
// 自己读 user prompt 找名字，tools 段就完全静态、跨 turn 走 cache。Godot 端仍是裁决方
// （[[feedback_godot_is_authority]]），所以即使 LLM 填错名字最多被 tool error 拒掉。

// LLM 引用物品（背包 / 附近 / 货架）统一格式：{name, index}。
// name 是看到的中文显示名，index 是清单里行首方括号里的 1-based 序号。
// 同名不同品质的多份堆叠在显示时各占一行（带不同 [N]），仅靠 name 无法区分。
// 详见 [[feedback_item_ref_by_index]]。
function createItemRefSchema(nameDescKey: string) {
  return Type.Object({
    name: Type.String({ minLength: 1, description: td(nameDescKey) }),
    index: Type.Integer({ minimum: 1, description: td("common.item_ref_index") }),
  });
}

export function createMoveToLocationSchema() {
  return Type.Object({
    location: Type.String({
      minLength: 1,
      description: td("move_to_location.param.location"),
    }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

function createPlanFarmWorkOpSchema() {
  return Type.Object({
    kind: StringEnum(["plant", "pest", "harvest", "uproot", "water"], {
      description: td("plan_farm_work.param.kind"),
    }),
    slot_index: Type.Optional(Type.Integer({
      minimum: 0,
      description: td("plan_farm_work.param.slot_index"),
    })),
    seed: Type.Optional(createItemRefSchema("plan_farm_work.param.seed")),
  });
}

export function createPlanFarmWorkSchema() {
  return Type.Object({
    farm: Type.String({
      minLength: 1,
      description: td("plan_farm_work.param.farm"),
    }),
    ops: Type.Array(createPlanFarmWorkOpSchema(), {
      minItems: 1,
      maxItems: 16,
      description: td("plan_farm_work.param.ops"),
    }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createSayToSchema() {
  return Type.Object({
    character: Type.String({
      minLength: 1,
      description: td("say_to.param.character"),
    }),
    text: Type.String({
      minLength: 1,
      description: td("say_to.param.text"),
    }),
    volume: StringEnum(["near", "far"], {
      description: td("say_to.param.volume"),
    }),
  });
}

function createUseItemSchema() {
  return Type.Object({
    item: createItemRefSchema("use_item.param.item"),
    target: Type.Optional(Type.String({ description: td("use_item.param.target") })),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

function createDropItemSchema() {
  return Type.Object({
    item: createItemRefSchema("drop_item.param.item"),
    quantity: Type.Optional(Type.Integer({
      minimum: 1,
      description: td("drop_item.param.quantity"),
    })),
  });
}

// 我方付出（offer[]）：物品从我的背包出，用 {name, index} 指定具体那份堆叠。
// 对方付出（request[]）：是"我想要"的描述，对方背包对我不可见，用纯 name + count。
// 货币 count 对 silver_coin/gold_coin 允许小数（精度 0.01），其他 item 仍须正整数，
// 由 resolveRequiredTradeLine 在 tool 边界做类型校验。
function createTradeOfferLineSchema() {
  return Type.Object({
    item: createItemRefSchema("trade_line.param.offer_item"),
    count: Type.Number({ minimum: 0.01, multipleOf: 0.01, description: td("trade_line.param.count") }),
  });
}

function createRequestTradeLineSchema() {
  return Type.Object({
    item: Type.String({ minLength: 1, description: td("trade_line.param.request_item") }),
    count: Type.Number({ minimum: 0.01, multipleOf: 0.01, description: td("trade_line.param.count") }),
  });
}

// offer 统一了两种用法：request:[] = 单向赠送（不阻塞，对方即时收到）；
// request 非空 = 议价交易（阻塞等对方 respond）。schema 形状一致，分支在 Godot 端做。
function createOfferSchema() {
  return Type.Object({
    character: Type.String({ minLength: 1, description: td("offer.param.character") }),
    offer: Type.Array(createTradeOfferLineSchema(), {
      description: td("offer.param.offer"),
    }),
    request: Type.Array(createRequestTradeLineSchema(), {
      description: td("offer.param.request"),
    }),
  });
}

// respond 统一回应入口，kind 字段决定回应类型。目前只 "trade"，未来扩 "group_join" 等。
// 各 kind 的辅助字段（trade 用 character 定位买家）按 kind 文档约定填写。
function createRespondSchema() {
  return Type.Object({
    kind: StringEnum(["trade"], { description: td("respond.param.kind") }),
    character: Type.String({ minLength: 1, description: td("respond.param.character") }),
    response: StringEnum(["accept", "reject"], { description: td("respond.param.response") }),
  });
}

// ───────────────────────────── 工作台 axis schemas ─────────────────────────────
// 按 proficiency skill axis 拆分的工具替代旧 use_workstation —— 见 craft-registry.ts +
// docs/proficiency_system.md。每个 schema 只暴露该 axis 真用得到的字段；workstation 检测仍
// 由 Godot _find_workstation 兜底（[[feedback_godot_is_authority]]）。
//
// 共享规则：
// - workstation 永远是 free-form string；合法取值由 tool description 指向 user message 的
//   # 当前附近工作台 段。烤进 enum 会让 tools 段 cache 每次感知变就 miss
// - sub_option 候选取自 axis spec 的 subOptions；只在该轴有多选时暴露（静态，不影响 cache）
// - mine（dig）不需要 inputs；其他制作型 axis 一律必填 inputs

export function createMineSchema() {
  return Type.Object({
    mine: Type.String({ minLength: 1, description: td("mine.param.mine") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createChopWoodSchema() {
  return Type.Object({
    lumberyard: Type.String({ minLength: 1, description: td("chop_wood.param.lumberyard") }),
    inputs: Type.Array(createItemRefSchema("chop_wood.param.input_item"), { minItems: 1, maxItems: 8, description: td("chop_wood.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createWoodworkSchema() {
  const spec = getCraftSpec("woodwork");
  return Type.Object({
    workstation: Type.String({ minLength: 1, description: td("woodwork.param.workstation") }),
    sub_option: StringEnum([...spec.subOptions!], { description: td("woodwork.param.sub_option") }),
    inputs: Type.Array(createItemRefSchema("woodwork.param.input_item"), { minItems: 1, maxItems: 8, description: td("woodwork.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createBurnCharcoalSchema() {
  return Type.Object({
    inputs: Type.Array(createItemRefSchema("burn_charcoal.param.input_item"), { minItems: 1, maxItems: 8, description: td("burn_charcoal.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createSmeltSchema() {
  return Type.Object({
    workstation: Type.String({ minLength: 1, description: td("smelt.param.workstation") }),
    inputs: Type.Array(createItemRefSchema("smelt.param.input_item"), { minItems: 1, maxItems: 8, description: td("smelt.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createSmithSchema() {
  return Type.Object({
    sub_option: StringEnum([...getCraftSpec("smith").subOptions!], { description: td("smith.param.sub_option") }),
    inputs: Type.Array(createItemRefSchema("smith.param.input_item"), { minItems: 1, maxItems: 8, description: td("smith.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createAssembleSchema() {
  return Type.Object({
    sub_option: StringEnum([...getCraftSpec("assemble").subOptions!], { description: td("assemble.param.sub_option") }),
    inputs: Type.Array(createItemRefSchema("assemble.param.input_item"), { minItems: 1, maxItems: 8, description: td("assemble.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createCookSchema() {
  return Type.Object({
    verb: StringEnum([...getCraftSpec("cook").verbs], { description: td("cook.param.verb") }),
    inputs: Type.Array(createItemRefSchema("cook.param.input_item"), { minItems: 1, maxItems: 8, description: td("cook.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createAlchemySchema() {
  return Type.Object({
    inputs: Type.Array(createItemRefSchema("alchemy.param.input_item"), { minItems: 1, maxItems: 8, description: td("alchemy.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createMillGrainSchema() {
  return Type.Object({
    inputs: Type.Array(createItemRefSchema("mill_grain.param.input_item"), { minItems: 1, maxItems: 8, description: td("mill_grain.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createBoilSaltSchema() {
  return Type.Object({
    inputs: Type.Array(createItemRefSchema("boil_salt.param.input_item"), { minItems: 1, maxItems: 8, description: td("boil_salt.param.inputs_array") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

function createTransferEndpointSchema() {
  return Type.Object({
    container: Type.Optional(Type.String({ description: td("brew.param.endpoint_container") })),
    item: Type.Optional(Type.Object({
      name: Type.String({ minLength: 1, description: td("brew.param.endpoint_item_name") }),
      index: Type.Integer({ minimum: 1, description: td("brew.param.endpoint_item_index") }),
    })),
  });
}

function createStorageTransferSchema(direction: "put" | "take") {
  return Type.Object({
    kind: StringEnum(["item", "liquid"], { description: td(`${direction}.param.transfer_kind`) }),
    item: Type.Optional(createItemRefSchema(`${direction}.param.item`)),
    amount: Type.Number({ minimum: 0.01, description: td(`${direction}.param.amount`) }),
    to_item: Type.Optional(createItemRefSchema(`${direction}.param.to_item`)),
    price_silver: Type.Optional(Type.Number({ minimum: 0, multipleOf: 0.01, description: td(`${direction}.param.price_silver`) })),
  });
}

export function createPutSchema() {
  return Type.Object({
    to: Type.String({ minLength: 1, description: td("put.param.to") }),
    transfers: Type.Array(createStorageTransferSchema("put"), { minItems: 1, maxItems: 16, description: td("put.param.transfers") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

export function createTakeSchema() {
  return Type.Object({
    from: Type.String({ minLength: 1, description: td("take.param.from") }),
    transfers: Type.Array(createStorageTransferSchema("take"), { minItems: 1, maxItems: 16, description: td("take.param.transfers") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

// brew：装水的酿酒桶 + 背包麦芽 → 发酵中的酒。barrel = 酿酒桶所在 endpoint。
export function createBrewSchema() {
  return Type.Object({
    barrel: createTransferEndpointSchema(),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

function createUpdateMemorySchema() {
  return Type.Object({
    operation: StringEnum(["add", "edit", "remove"], {
      description: td("update_memory.param.operation"),
    }),
    kind: Type.Optional(StringEnum(["self_knowledge", "common_sense", "skill", "other"], {
      description: td("update_memory.param.kind"),
    })),
    memory_index: Type.Optional(Type.Integer({
      minimum: 1,
      description: td("update_memory.param.memory_index"),
    })),
    new_string: Type.Optional(Type.String({
      description: td("update_memory.param.new_string"),
    })),
  });
}

function createCreateItemSchema() {
  return Type.Object({
    description: Type.String({ minLength: 1, description: td("create_item.param.description") }),
    location: Type.Optional(Type.String({ description: td("create_item.param.location") })),
    owner: Type.Optional(Type.String({ description: td("create_item.param.owner") })),
  });
}

function createDoNothingSchema() {
  return Type.Object({
    reason: Type.Optional(Type.String({ description: td("common.do_nothing_reason_description") })),
  });
}

function createSleepSchema() {
  return Type.Object({
    duration_game_minutes: Type.Integer({
      minimum: 1,
      maximum: 720,
      description: td("sleep.param.duration_game_minutes"),
    }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

function createWriteSchema() {
  return Type.Object({
    item_name: Type.String({ minLength: 1, description: td("write.param.item_name") }),
    title: Type.String({ minLength: 1, maxLength: 60, description: td("write.param.title") }),
    content: Type.String({ minLength: 1, maxLength: 800, description: td("write.param.content") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

function createReadSchema() {
  return Type.Object({
    title: Type.String({ minLength: 1, description: td("read.param.title") }),
    reason: Type.Optional(Type.String({ description: toolReasonDescription() })),
  });
}

// 类型从一个静态实例推导（schema 内容是 i18n，但结构稳定）
export const useItemSchema = createUseItemSchema();
export const dropItemSchema = createDropItemSchema();
export const offerSchema = createOfferSchema();
export const respondSchema = createRespondSchema();
export const putSchema = createPutSchema();
export const takeSchema = createTakeSchema();
export const updateMemorySchema = createUpdateMemorySchema();
export const createItemSchema = createCreateItemSchema();
export const doNothingSchema = createDoNothingSchema();
export const sleepSchema = createSleepSchema();
export const writeSchema = createWriteSchema();
export const readSchema = createReadSchema();

export type MoveToLocationParams = {
  location: string;
  reason?: string;
};
// 所有 item 引用的统一参数形态。详见 [[feedback_item_ref_by_index]]。
export type ItemRefParam = { name: string; index: number };

export type PlanFarmWorkOpParams = {
  kind: "plant" | "pest" | "harvest" | "uproot" | "water";
  slot_index?: number;
  seed?: ItemRefParam;
};
export type PlanFarmWorkParams = {
  farm?: string;
  farm_id?: string;
  ops: PlanFarmWorkOpParams[];
  reason?: string;
};
// axis tool 的 Params —— 见 schemas 工厂上方注释。形态严格按 schema 写明，不暴露
// 内部 axis 实现细节（factory 在 normalize 时按 axis spec 把 workstation/verb/sub_option 填好）。
export type MineParams = { mine: string; reason?: string };
export type ChopWoodParams = { lumberyard: string; inputs: ItemRefParam[]; reason?: string };
export type WoodworkParams = { workstation: string; sub_option: string; inputs: ItemRefParam[]; reason?: string };
export type BurnCharcoalParams = { inputs: ItemRefParam[]; reason?: string };
export type SmeltParams = { workstation: string; inputs: ItemRefParam[]; reason?: string };
export type SmithParams = { sub_option: string; inputs: ItemRefParam[]; reason?: string };
export type AssembleParams = { sub_option: string; inputs: ItemRefParam[]; reason?: string };
export type CookParams = { verb: string; inputs: ItemRefParam[]; reason?: string };
export type AlchemyParams = { inputs: ItemRefParam[]; reason?: string };
export type MillGrainParams = { inputs: ItemRefParam[]; reason?: string };
export type BoilSaltParams = { inputs: ItemRefParam[]; reason?: string };
export type TransferEndpointParam = { container?: string; item?: { name: string; index: number } };
export type StorageTransferParam = {
  kind: "item" | "liquid";
  item?: ItemRefParam;
  amount: number;
  to_item?: ItemRefParam;
  price_silver?: number;
};
export type PutParams = {
  to: string;
  transfers: StorageTransferParam[];
  reason?: string;
};
export type TakeParams = {
  from: string;
  transfers: StorageTransferParam[];
  reason?: string;
};
export type BrewParams = { barrel: TransferEndpointParam; reason?: string };
// 每个 axis Params 在 tool factory 里被 normalize 成 WorkstationActionTarget 形态发给 Godot。
export type AxisToolParams =
  | MineParams | ChopWoodParams | WoodworkParams | BurnCharcoalParams | SmeltParams | SmithParams
  | AssembleParams | CookParams | AlchemyParams | MillGrainParams | BoilSaltParams;
export type SayToParams = {
  character: string;
  text: string;
  volume: "near" | "far";
};
export type UseItemParams = Static<typeof useItemSchema>;
export type DropItemParams = Static<typeof dropItemSchema>;
export type OfferParams = Static<typeof offerSchema>;
export type RespondParams = Static<typeof respondSchema>;
export type UpdateMemoryParams = Static<typeof updateMemorySchema>;
export type CreateItemParams = Static<typeof createItemSchema>;
export type DoNothingParams = Static<typeof doNothingSchema>;
export type SleepParams = Static<typeof sleepSchema>;
export type WriteParams = Static<typeof writeSchema>;
export type ReadParams = Static<typeof readSchema>;
