import type { AgentTool, AgentToolResult, AgentToolUpdateCallback } from "@mariozechner/pi-agent-core";
import type { GameTimeSnapshot } from "../../godot-link/protocol.js";
import { localizeStringValue, resolveCharacterIdByName } from "../name-resolver/index.js";
import type { AgentCurrentContext, ItemIndexEntry } from "../prompt-context/types.js";
import { sayToThrottleMs } from "../say-to-throttle.js";
import { td } from "./i18n.js";
import {
  formatMoveToLocationToolResult,
  formatPlanFarmWorkToolResult,
  formatSayToToolResult,
  submitToolAction,
} from "./action-results.js";
import {
  createAssembleSchema,
  createAlchemySchema,
  createBoilSaltSchema,
  createBurnCharcoalSchema,
  createChopWoodSchema,
  createCookSchema,
  createItemSchema,
  createMillGrainSchema,
  createMineSchema,
  createMoveToLocationSchema,
  createPlanFarmWorkSchema,
  createPutSchema,
  createTakeSchema,
  createBrewSchema,
  createSayToSchema,
  createSmeltSchema,
  createSmithSchema,
  createWoodworkSchema,
  doNothingSchema,
  dropItemSchema,
  offerSchema,
  readSchema,
  respondSchema,
  sleepSchema,
  tendAnimalSchema,
  useItemSchema,
  writeSchema,
  type AssembleParams,
  type AlchemyParams,
  type BoilSaltParams,
  type BurnCharcoalParams,
  type ChopWoodParams,
  type CookParams,
  type CreateItemParams,
  type DoNothingParams,
  type DropItemParams,
  type ItemRefParam,
  type MillGrainParams,
  type MineParams,
  type MoveToLocationParams,
  type OfferParams,
  type PlanFarmWorkParams,
  type PutParams,
  type BrewParams,
  type TakeParams,
  type TransferEndpointParam,
  type ReadParams,
  type RespondParams,
  type SayToParams,
  type SleepParams,
  type SmeltParams,
  type SmithParams,
  type TendAnimalParams,
  type UseItemParams,
  type WoodworkParams,
  type WriteParams,
} from "./schemas.js";
import {
  isMoveTargetError,
  normalizePlanFarmWorkOps,
  normalizeWorkstationActionInputs,
  resolveContainerOrShelfTarget,
  resolveCraftWorkstation,
  resolveFlatItemByIndex,
  resolveItemByIndex,
  resolveItemTarget,
  resolveMoveTarget,
  resolveOptionalKnownTargetName,
  resolvePlanFarm,
  resolveScopedItemByIndex,
  resolveSpeechTarget,
  resolveTradeTarget,
} from "./targets.js";
import { getCraftSpec, verbForWorkstation, type CraftSlug } from "./craft-registry.js";
import type { ActionName, WorkstationActionTarget, TransferWire, ContainerEndpoint } from "../../godot-link/actions.js";
import type {
  AgentToolInterrupts,
  CharacterActionToolDetails,
  CreateGameAgentToolsOptions,
  DoNothingToolDetails,
  MoveToLocationToolDetails,
  WorldEventToolDetails,
} from "./types.js";

const DEFAULT_RUNTIME_ACTION_TIMEOUT_MS = 120_000;
const TIME_SCALED_ACTION_TIMEOUT_BUFFER_MS = 60_000;
const TIME_SCALED_MINUTE_TIMEOUT_MS = 15_000;

type ToolRuntime = Pick<CreateGameAgentToolsOptions, "actions" | "memoryStorage" | "getCurrentContext">;

function timeScaledActionTimeoutMs(durationMinutes: number): number {
  const minutes = Number.isFinite(durationMinutes) ? Math.max(0, durationMinutes) : 0;
  return Math.max(
    DEFAULT_RUNTIME_ACTION_TIMEOUT_MS,
    Math.ceil(minutes * TIME_SCALED_MINUTE_TIMEOUT_MS) + TIME_SCALED_ACTION_TIMEOUT_BUFFER_MS,
  );
}

function planFarmWorkTimeoutMs(ops: PlanFarmWorkParams["ops"]): number {
  const durationMinutes = ops.reduce((total, op) => total + farmOpDurationMinutes(op.kind) + 1, 0);
  return timeScaledActionTimeoutMs(durationMinutes);
}

function farmOpDurationMinutes(kind: PlanFarmWorkParams["ops"][number]["kind"]): number {
  switch (kind) {
    case "plant": return 1;
    case "pest": return 5;
    case "water": return 15;
    case "harvest": return 1;
    case "uproot": return 2;
  }
}

function containerTransferTimeoutMs(wire: TransferWire[]): number | undefined {
  const wellLiters = wire.reduce((sum, tr) => {
    if (tr.kind !== "liquid" || tr.from.where !== "well") return sum;
    return sum + Math.max(0, tr.amount);
  }, 0);
  if (wellLiters <= 0) return undefined;
  return timeScaledActionTimeoutMs(wellLiters * 0.15);
}

function sleepActionTimeoutMs(durationMinutes: number): number {
  return timeScaledActionTimeoutMs(durationMinutes);
}

export function createMoveToLocationTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, MoveToLocationToolDetails> {
  return {
    label: td("move_to_location.label"),
    name: "move_to_location",
    description: td("move_to_location.description"),
    parameters: createMoveToLocationSchema(),
    execute: async (_toolCallId: string, rawArgs: unknown, signal, onUpdate) => {
      const args = rawArgs as MoveToLocationParams;
      const resolved = resolveMoveTarget(args.location, currentContext);
      if (isMoveTargetError(resolved)) {
        throw new Error(resolved.error);
      }
      return submitToolAction(
        runtime.actions,
        characterId,
        "move_to_location",
        resolved.target,
        args.reason ?? td("move_to_location.reason_default_format", { label: resolved.label }),
        {
          toolName: "move_to_location",
          displayTarget: resolved.label,
          gameTime: currentContext?.gameTime,
          signal,
          onUpdate,
          interrupts,
          formatResult: async (record, context) => formatMoveToLocationToolResult(
            record,
            context.target,
            context.displayTarget,
            await runtime.getCurrentContext?.() ?? currentContext,
          ),
        },
      );
    },
  };
}

// 唯一农事工具：一次提交一份"plant slot1 + plant slot2 + water + harvest slot5" 完整工单。
// runtime 走 FarmActionQueue 串行执行，挂起 tool 直到全部完成（或被打断）。
// result 回包形态：{ completed: [{kind, slot_index, result}, ...], remaining: [...], interrupted, reason }
export function createPlanFarmWorkTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("plan_farm_work.label"),
    name: "plan_farm_work",
    description: td("plan_farm_work.description"),
    parameters: createPlanFarmWorkSchema(),
    execute: async (_toolCallId: string, rawArgs: unknown, signal, onUpdate) => {
      const args = rawArgs as PlanFarmWorkParams;
      const farm = resolvePlanFarm(args.farm ?? args.farm_id, currentContext);
      if (isMoveTargetError(farm)) {
        throw new Error(farm.error);
      }
      const ops = normalizePlanFarmWorkOps(args.ops, currentContext);
      return submitToolAction(
        runtime.actions,
        characterId,
        "plan_farm_work",
        { farmId: farm.id, ops },
        args.reason ?? td("plan_farm_work.reason_default_format", { count: ops.length, label: farm.label }),
        {
          toolName: "plan_farm_work",
          resultNote: td("plan_farm_work.result_note"),
          displayTarget: td("plan_farm_work.display_target_format", { label: farm.label }),
          gameTime,
          signal,
          timeoutMs: planFarmWorkTimeoutMs(ops),
          onUpdate,
          interrupts,
          formatResult: formatPlanFarmWorkToolResult,
        },
      );
    },
  };
}

// ───────────────────────────── 工作台 axis tools ─────────────────────────────
// 按 proficiency skill axis 拆分的 tool 替代旧 use_workstation —— 见 craft-registry.ts +
// docs/proficiency_system.md。每个 tool 一个 wire action，共享 WorkstationActionTarget 形态。
// workstation 检测仍由 Godot _find_workstation 兜底（[[feedback_godot_is_authority]]）。

function mineActionTimeoutMs(workstationId: string): number | undefined {
  if (workstationId === "gold_mine_workstation" || workstationId === "silver_mine_workstation") {
    return timeScaledActionTimeoutMs(60);
  }
  return undefined;
}

// production axis 共享的执行体：装配 WorkstationActionTarget + submitToolAction。
async function runAxisCraftAction(opts: {
  axis: CraftSlug;
  runtime: ToolRuntime;
  characterId: string;
  currentContext: AgentCurrentContext | undefined;
  gameTime: GameTimeSnapshot | undefined;
  signal: AbortSignal | undefined;
  onUpdate: AgentToolUpdateCallback<CharacterActionToolDetails> | undefined;
  interrupts: AgentToolInterrupts | undefined;
  workstation: { id: string; label: string };
  verb: string;
  subOption: string;
  inputs: ItemRefParam[] | undefined;
  reason: string | undefined;
  timeoutMs?: number;
}) {
  const { inputItemIds, inputItemSlotIndices } = normalizeWorkstationActionInputs(opts.axis, opts.inputs, opts.currentContext);
  const target: WorkstationActionTarget = {
    workstationId: opts.workstation.id,
    verb: opts.verb,
    subOption: opts.subOption,
    inputItemIds,
    inputItemSlotIndices,
  };
  // CraftSlug 是 plain string（真值在 data/skills/crafts.json）；ActionName 是 actions.ts
  // 的窄 union。两者内容上 100% 对齐——actions.ts 的 wire action 列表与 crafts.json 同步维护——
  // 类型上需要在这个边界 cast 一次，保留 ActionName 对其他调用方的窄类型保护。
  const actionName = opts.axis as ActionName;
  return submitToolAction(
    opts.runtime.actions,
    opts.characterId,
    actionName,
    target,
    opts.reason ?? td(`${opts.axis}.reason_default_format`, { label: opts.workstation.label }),
    {
      toolName: actionName,
      resultNote: td(`${opts.axis}.result_note`),
      displayTarget: opts.workstation.label,
      gameTime: opts.gameTime,
      signal: opts.signal,
      timeoutMs: opts.timeoutMs,
      onUpdate: opts.onUpdate,
      interrupts: opts.interrupts,
    },
  );
}

export function createMineTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("mine.label"),
    name: "mine",
    description: td("mine.description"),
    parameters: createMineSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as MineParams;
      const workstation = resolveCraftWorkstation("mine", args.mine, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "mine", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("mine").fixedVerb!, subOption: "", inputs: undefined,
        reason: args.reason, timeoutMs: mineActionTimeoutMs(workstation.id),
      });
    },
  };
}

export function createChopWoodTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("chop_wood.label"),
    name: "chop_wood",
    description: td("chop_wood.description"),
    parameters: createChopWoodSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as ChopWoodParams;
      const workstation = resolveCraftWorkstation("chop_wood", args.lumberyard, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "chop_wood", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("chop_wood").fixedVerb!, subOption: "", inputs: args.inputs,
        reason: args.reason,
      });
    },
  };
}

export function createWoodworkTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("woodwork.label"),
    name: "woodwork",
    description: td("woodwork.description"),
    parameters: createWoodworkSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as WoodworkParams;
      const workstation = resolveCraftWorkstation("woodwork", args.workstation, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "woodwork", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("woodwork").fixedVerb!, subOption: args.sub_option.trim(), inputs: args.inputs,
        reason: args.reason,
      });
    },
  };
}

export function createBurnCharcoalTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("burn_charcoal.label"),
    name: "burn_charcoal",
    description: td("burn_charcoal.description"),
    parameters: createBurnCharcoalSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as BurnCharcoalParams;
      const workstation = resolveCraftWorkstation("burn_charcoal", undefined, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "burn_charcoal", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("burn_charcoal").fixedVerb!, subOption: "", inputs: args.inputs,
        reason: args.reason,
      });
    },
  };
}

export function createSmeltTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("smelt.label"),
    name: "smelt",
    description: td("smelt.description"),
    parameters: createSmeltSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as SmeltParams;
      const workstation = resolveCraftWorkstation("smelt", args.workstation, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      const verb = verbForWorkstation("smelt", workstation.id)!;
      return runAxisCraftAction({
        axis: "smelt", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb, subOption: "", inputs: args.inputs, reason: args.reason,
      });
    },
  };
}

export function createSmithTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("smith.label"),
    name: "smith",
    description: td("smith.description"),
    parameters: createSmithSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as SmithParams;
      const workstation = resolveCraftWorkstation("smith", undefined, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "smith", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("smith").fixedVerb!, subOption: args.sub_option.trim(),
        inputs: args.inputs, reason: args.reason,
      });
    },
  };
}

export function createAssembleTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("assemble.label"),
    name: "assemble",
    description: td("assemble.description"),
    parameters: createAssembleSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as AssembleParams;
      const workstation = resolveCraftWorkstation("assemble", undefined, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "assemble", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("assemble").fixedVerb!, subOption: args.sub_option.trim(),
        inputs: args.inputs, reason: args.reason,
      });
    },
  };
}

export function createCookTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("cook.label"),
    name: "cook",
    description: td("cook.description"),
    parameters: createCookSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as CookParams;
      const workstation = resolveCraftWorkstation("cook", undefined, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "cook", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: args.verb.trim(), subOption: "", inputs: args.inputs, reason: args.reason,
      });
    },
  };
}

export function createAlchemyTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("alchemy.label"),
    name: "alchemy",
    description: td("alchemy.description"),
    parameters: createAlchemySchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as AlchemyParams;
      const workstation = resolveCraftWorkstation("alchemy", undefined, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "alchemy", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("alchemy").fixedVerb!, subOption: "", inputs: args.inputs,
        reason: args.reason,
      });
    },
  };
}

export function createMillGrainTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("mill_grain.label"),
    name: "mill_grain",
    description: td("mill_grain.description"),
    parameters: createMillGrainSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as MillGrainParams;
      const workstation = resolveCraftWorkstation("mill_grain", undefined, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "mill_grain", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("mill_grain").fixedVerb!, subOption: "", inputs: args.inputs,
        reason: args.reason,
      });
    },
  };
}

export function createBoilSaltTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("boil_salt.label"),
    name: "boil_salt",
    description: td("boil_salt.description"),
    parameters: createBoilSaltSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as BoilSaltParams;
      const workstation = resolveCraftWorkstation("boil_salt", undefined, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      return runAxisCraftAction({
        axis: "boil_salt", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb: getCraftSpec("boil_salt").fixedVerb!, subOption: "", inputs: args.inputs,
        reason: args.reason,
      });
    },
  };
}

// put / take —— 只允许“背包 <-> 一个附近储物目标”。物品编号永远来自统一全局 [N]。
export function createPutTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("put.label"),
    name: "put",
    description: td("put.description"),
    parameters: createPutSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as PutParams;
      const wire = buildPutWire(args, currentContext);
      return submitToolAction(
        runtime.actions,
        characterId,
        "put",
        { transfers: wire },
        args.reason ?? td("put.reason_format", { label: args.to }),
        { toolName: "put", displayTarget: args.to, gameTime, signal, timeoutMs: containerTransferTimeoutMs(wire), onUpdate, interrupts },
      );
    },
  };
}

export function createTakeTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("take.label"),
    name: "take",
    description: td("take.description"),
    parameters: createTakeSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as TakeParams;
      const wire = buildTakeWire(args, currentContext);
      return submitToolAction(
        runtime.actions,
        characterId,
        "take",
        { transfers: wire },
        args.reason ?? td("take.reason_format", { label: args.from }),
        { toolName: "take", displayTarget: args.from, gameTime, signal, timeoutMs: containerTransferTimeoutMs(wire), onUpdate, interrupts },
      );
    },
  };
}

export function buildPutWire(args: PutParams, currentContext?: AgentCurrentContext): TransferWire[] {
  const target = resolveStorageTarget(args.to, currentContext, "put");
  if (target.id === "well") throw new Error(td("put.error.destination_well"));
  const wire: TransferWire[] = [];
  for (const tr of args.transfers ?? []) {
    if (tr.kind === "liquid") {
      const source = resolveBackpackItemEndpoint(tr.item, currentContext, "put");
      const to = tr.to_item
        ? resolveTargetStorageItemEndpoint(tr.to_item, target, currentContext, "put")
        : storageTargetToEndpoint(target);
      if (to.isShelf && tr.price_silver != null) to.priceCenti = Math.round(tr.price_silver * 100);
      if (to.where === "well") throw new Error(td("put.error.destination_well"));
      wire.push({ kind: "liquid", amount: tr.amount, from: source.endpoint, to });
    } else {
      const source = resolveBackpackItemEndpoint(tr.item, currentContext, "put");
      const to = storageTargetToEndpoint(target);
      if (to.isShelf && tr.price_silver != null) to.priceCenti = Math.round(tr.price_silver * 100);
      const amount = CURRENCY_ITEM_IDS.has(source.itemId) ? tr.amount : Math.round(tr.amount);
      wire.push({ kind: "item", itemId: source.itemId, amount, from: source.endpoint, to });
    }
  }
  return wire;
}

export function buildTakeWire(args: TakeParams, currentContext?: AgentCurrentContext): TransferWire[] {
  const target = resolveStorageTarget(args.from, currentContext, "take");
  const wire: TransferWire[] = [];
  for (const tr of args.transfers ?? []) {
    if (tr.kind === "liquid") {
      const from = target.id === "well" && !tr.item
        ? { where: "well", containerId: "well" } as ContainerEndpoint
        : target.kind === "ground"
          ? resolveGroundItemEndpoint(tr.item, currentContext, "take").endpoint
        : resolveTargetStorageItemEndpoint(tr.item, target, currentContext, "take");
      const to = tr.to_item
        ? resolveBackpackItemEndpoint(tr.to_item, currentContext, "take").endpoint
        : { where: "backpack" } as ContainerEndpoint;
      wire.push({ kind: "liquid", amount: tr.amount, from, to });
    } else {
      const resolved = target.kind === "ground"
        ? resolveGroundItemEndpoint(tr.item, currentContext, "take")
        : resolveStorageItemForTarget(tr.item, target, currentContext, "take");
      const source = resolved.endpoint;
      const itemId = resolved.itemId;
      const amount = CURRENCY_ITEM_IDS.has(itemId) ? tr.amount : Math.round(tr.amount);
      wire.push({ kind: "item", itemId, amount, from: source, to: { where: "backpack" } });
    }
  }
  return wire;
}

type ResolvedStorageItem = {
  itemId: string;
  endpoint: ContainerEndpoint;
  entry: ItemIndexEntry;
};

type ResolvedStorageTarget = { id: string; label: string; kind: "container" | "shelf" | "workstation" | "ground" };

function resolveStorageTarget(name: string, ctx: AgentCurrentContext | undefined, tool: "put" | "take"): ResolvedStorageTarget {
  if (tool === "take" && isNearbyGroundTarget(name)) {
    return { id: "__nearby_ground", label: td("take.ground_target"), kind: "ground" };
  }
  if (resolveCharacterIdByName(name)) {
    throw new Error(td(`${tool}.error.person_target`, { label: name.trim() }));
  }
  const site = resolveContainerOrShelfTarget(name, ctx);
  if (isMoveTargetError(site)) throw new Error(site.error);
  if (!site.directlyInteractable) throw new Error(td(`${tool}.error.target_not_nearby`, { label: site.label }));
  return site;
}

function isNearbyGroundTarget(name: string | undefined): boolean {
  const normalized = (name ?? "").trim().toLowerCase().replace(/\s+/g, "");
  return ["附近地面", "地面", "nearbyground", "ground"].includes(normalized);
}

function resolveFlatStorageItem(ref: ItemRefParam | undefined, ctx: AgentCurrentContext | undefined, tool: "put" | "take"): ResolvedStorageItem {
  if (!ref) throw new Error(td(`${tool}.error.missing_item`));
  const flat = resolveFlatItemByIndex(ref, ctx);
  if (isMoveTargetError(flat)) throw new Error(flat.error);
  return { itemId: flat.id, endpoint: entryToEndpoint(flat.entry), entry: flat.entry };
}

function resolveBackpackItemEndpoint(ref: ItemRefParam | undefined, ctx: AgentCurrentContext | undefined, tool: "put" | "take"): ResolvedStorageItem {
  const resolved = resolveFlatStorageItem(ref, ctx, tool);
  if (resolved.entry.scope !== "backpack") {
    throw new Error(td(`${tool}.error.item_not_backpack`));
  }
  return resolved;
}

function resolveTargetStorageItemEndpoint(
  ref: ItemRefParam | undefined,
  target: ResolvedStorageTarget,
  ctx: AgentCurrentContext | undefined,
  tool: "put" | "take",
): ContainerEndpoint {
  const resolved = resolveFlatStorageItem(ref, ctx, tool);
  if (!isStorageScope(resolved.entry.scope)) {
    throw new Error(td(`${tool}.error.item_not_storage`));
  }
  if (resolved.entry.containerId !== target.id) {
    throw new Error(td(`${tool}.error.item_not_in_target`, { label: target.label }));
  }
  return resolved.endpoint;
}

function resolveStorageItemForTarget(
  ref: ItemRefParam | undefined,
  target: ResolvedStorageTarget,
  ctx: AgentCurrentContext | undefined,
  tool: "put" | "take",
): ResolvedStorageItem {
  const resolved = resolveFlatStorageItem(ref, ctx, tool);
  if (!isStorageScope(resolved.entry.scope)) {
    throw new Error(td(`${tool}.error.item_not_storage`));
  }
  if (resolved.entry.containerId !== target.id) {
    throw new Error(td(`${tool}.error.item_not_in_target`, { label: target.label }));
  }
  return resolved;
}

function resolveGroundItemEndpoint(ref: ItemRefParam | undefined, ctx: AgentCurrentContext | undefined, tool: "take"): ResolvedStorageItem {
  const resolved = resolveFlatStorageItem(ref, ctx, tool);
  if (resolved.entry.scope !== "nearby") {
    throw new Error(td("take.error.item_not_ground"));
  }
  return resolved;
}

function isStorageScope(scope: ItemIndexEntry["scope"]): boolean {
  return scope === "container" || scope === "shelf" || scope === "workstation_storage";
}

// 一个扁平条目 → wire endpoint（按它所在的 scope 定位）。
function entryToEndpoint(e: ItemIndexEntry): ContainerEndpoint {
  if (e.scope === "container" || e.scope === "shelf" || e.scope === "workstation_storage") {
    return { where: "node", containerId: e.containerId, slotIndex: e.slotIndex, isShelf: e.scope === "shelf" };
  }
  if (e.scope === "nearby") {
    return e.groundItemId ? { where: "ground", groundItemId: e.groundItemId } : { where: "ground" };
  }
  return { where: "backpack", slotIndex: e.slotIndex };
}

function storageTargetToEndpoint(target: ResolvedStorageTarget): ContainerEndpoint {
  return { where: "node", containerId: target.id, isShelf: target.kind === "shelf" };
}

// 把 transfer endpoint 解析成液体来源 endpoint。
// 来源必须是具体液体容器 item（桶/酿酒桶/杯），或水井这类无限液体源。
function resolveLiquidSourceEndpoint(ep: TransferEndpointParam, ctx?: AgentCurrentContext): ContainerEndpoint {
  if (ep.item) {
    return resolveContainerItemEndpoint(ep, ctx, td("brew.error.liquid_container_invalid"));
  }
  if (ep.container) {
    const site = resolveContainerOrShelfTarget(ep.container, ctx);
    if (isMoveTargetError(site)) throw new Error(site.error);
    if (site.id === "well") return { where: "well", containerId: site.id };
    throw new Error(td("brew.error.liquid_source_specific_item_format", { label: site.label }));
  }
  throw new Error(td("brew.error.liquid_endpoint_required"));
}

function resolveContainerItemEndpoint(ep: TransferEndpointParam, ctx: AgentCurrentContext | undefined, fallbackError: string): ContainerEndpoint {
  if (!ep.item) throw new Error(fallbackError);
  if (ep.container) {
    const site = resolveContainerOrShelfTarget(ep.container, ctx);
    if (isMoveTargetError(site)) throw new Error(site.error);
    const scoped = site.kind === "shelf"
      ? resolveScopedItemByIndex(ep.item, { kind: "shelf", shelfId: site.id }, ctx)
      : resolveScopedItemByIndex(ep.item, { kind: "container", containerId: site.id }, ctx);
    if (isMoveTargetError(scoped)) throw new Error(scoped.error);
    return { where: "node", containerId: site.id, slotIndex: scoped.slotIndex, isShelf: site.kind === "shelf" };
  }
  const flat = resolveFlatItemByIndex(ep.item, ctx);
  if (isMoveTargetError(flat)) throw new Error(flat.error);
  return entryToEndpoint(flat.entry);
}

// 酿酒 —— 装水的酿酒桶 + 背包麦芽 → 发酵中的酒。Godot BrewHandlers 执行。
export function createBrewTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("brew.label"),
    name: "brew",
    description: td("brew.description"),
    parameters: createBrewSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as BrewParams;
      const barrel = resolveLiquidSourceEndpoint(args.barrel, currentContext);
      return submitToolAction(
        runtime.actions,
        characterId,
        "brew",
        { barrel },
        args.reason ?? td("brew.reason_default"),
        { toolName: "brew", displayTarget: td("brew.display_target"), gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

export function createSayToTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  const toolName = "say_to";
  return {
    label: td("say_to.label"),
    name: toolName,
    description: td("say_to.description"),
    parameters: createSayToSchema(),
    execute: async (_toolCallId: string, rawArgs: unknown, signal, onUpdate) => {
      const args = rawArgs as SayToParams;
      const targetCharacter = resolveSpeechTarget(args.character, currentContext);
      if (isMoveTargetError(targetCharacter)) {
        throw new Error(targetCharacter.error);
      }
      // speaker 端节流：sleep 这段时间视为"NPC 在准备开口"，submit 还没发，气泡还没弹。
      // 详见 say-to-throttle.ts。
      await new Promise<void>((resolve) => setTimeout(resolve, sayToThrottleMs(args.text)));
      return submitToolAction(
        runtime.actions,
        characterId,
        toolName,
        { text: args.text, volume: args.volume, targetCharacterId: targetCharacter.id },
        td("say_to.reason_format", { label: targetCharacter.label, volume: args.volume }),
        {
          toolName,
          displayTarget: td("say_to.display_target_format", { label: targetCharacter.label, text: args.text }),
          gameTime,
          formatResult: formatSayToToolResult,
          signal,
          onUpdate,
          interrupts,
        },
      );
    },
  };
}

export function createUseItemTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof useItemSchema, CharacterActionToolDetails> {
  return {
    label: td("use_item.label"),
    name: "use_item",
    description: td("use_item.description"),
    parameters: useItemSchema,
    execute: async (_toolCallId: string, args: UseItemParams, signal, onUpdate) => {
      const item = resolveItemByIndex(args.item, "backpack", currentContext);
      if (isMoveTargetError(item)) {
        throw new Error(item.error);
      }
      const target = resolveOptionalKnownTargetName(args.target, currentContext, characterId);
      if (isMoveTargetError(target)) {
        throw new Error(target.error);
      }
      return submitToolAction(
        runtime.actions,
        characterId,
        "use_item",
        {
          itemId: item.id,
          ...(item.slotIndex != null ? { slotIndex: item.slotIndex } : {}),
          ...(target ? { targetId: target } : {}),
        },
        args.reason ?? td("use_item.reason_default_format", { item: item.label }),
        { displayTarget: target ? `${item.label} -> ${localizeStringValue(target)}` : item.label, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

export function createDropItemTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof dropItemSchema, CharacterActionToolDetails> {
  return {
    label: td("drop_item.label"),
    name: "drop_item",
    description: td("drop_item.description"),
    parameters: dropItemSchema,
    execute: async (_toolCallId: string, args: DropItemParams, signal, onUpdate) => {
      const item = resolveItemByIndex(args.item, "backpack", currentContext);
      if (isMoveTargetError(item)) {
        throw new Error(item.error);
      }
      return submitToolAction(
        runtime.actions,
        characterId,
        "drop_item",
        {
          itemId: item.id,
          ...(item.slotIndex != null ? { slotIndex: item.slotIndex } : {}),
          ...(args.quantity != null ? { quantity: args.quantity } : {}),
        },
        td("drop_item.reason_format", { item: item.label }),
        { displayTarget: item.label, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

export function createTendAnimalTool(
  runtime: ToolRuntime,
  characterId: string,
  _currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof tendAnimalSchema, CharacterActionToolDetails> {
  return {
    label: td("tend_animal.label"),
    name: "tend_animal",
    description: td("tend_animal.description"),
    parameters: tendAnimalSchema,
    execute: async (_toolCallId: string, args: TendAnimalParams, signal, onUpdate) => {
      const species = String(args.species ?? "").trim().toLowerCase();
      if (!species) {
        throw new Error(td("tend_animal.error.no_species"));
      }
      return submitToolAction(
        runtime.actions,
        characterId,
        "tend_animal",
        { verb: args.verb as "feed" | "slaughter", species },
        args.reason ?? td("tend_animal.reason_format", { verb: args.verb, species }),
        { displayTarget: species, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

export function createOfferTool(
  runtime: ToolRuntime,
  characterId: string,
  _currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof offerSchema, CharacterActionToolDetails> {
  return {
    label: td("offer.label"),
    name: "offer",
    description: td("offer.description"),
    parameters: offerSchema,
    execute: async (_toolCallId: string, args: OfferParams, signal, onUpdate) => {
      const target = resolveTradeTarget(args.character, _currentContext);
      if (isMoveTargetError(target)) {
        throw new Error(target.error);
      }
      const offer = args.offer.map((line) => resolveTradeOfferLine(line, _currentContext));
      const request = args.request.map((line) => resolveRequestTradeLine(line));
      return submitToolAction(
        runtime.actions,
        characterId,
        "offer",
        {
          characterId: target.id,
          offer,
          request,
        },
        td("offer.reason_format", { label: target.label }),
        { displayTarget: target.label, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

// respond 按 kind 分派回应不同类型请求。当前只支持 "trade"（回应别人对你的 offer 议价报价）；
// 未来扩 "group_join" 等新 kind 时这里加 case + Godot _run_respond 加新 mechanic dispatch。
export function createRespondTool(
  runtime: ToolRuntime,
  characterId: string,
  _currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof respondSchema, CharacterActionToolDetails> {
  return {
    label: td("respond.label"),
    name: "respond",
    description: td("respond.description"),
    parameters: respondSchema,
    execute: async (_toolCallId: string, args: RespondParams, signal, onUpdate) => {
      const kind = args.kind;
      if (kind === "trade") {
        const buyer = resolveTradeTarget(args.character, _currentContext);
        if (isMoveTargetError(buyer)) {
          throw new Error(buyer.error);
        }
        return submitToolAction(
          runtime.actions,
          characterId,
          "respond",
          { kind, buyerCharacterId: buyer.id, response: args.response as "accept" | "reject" },
          args.response === "accept"
            ? td("respond.reason_accept", { label: buyer.label })
            : td("respond.reason_reject", { label: buyer.label }),
          { displayTarget: buyer.label, gameTime, signal, onUpdate, interrupts },
        );
      }
      throw new Error(td("respond.error.unsupported_kind", { kind }));
    },
  };
}

// 注：update_memory tool 不在 shared—— memory 写入策略是 per-agent 的核心差异点
// （见 [[feedback_agent_memory_strategy_per_agent]]），每个 agent 在自己目录里实现自己的
// createUpdateMemoryTool，用 schemas.ts 的 updateMemorySchema + 自己的 memory 模块。

export function createCreateItemTool(
  runtime: ToolRuntime,
): AgentTool<typeof createItemSchema, WorldEventToolDetails> {
  return {
    label: td("create_item.label"),
    name: "create_item",
    description: td("create_item.description"),
    parameters: createItemSchema,
    execute: async (_toolCallId: string, args: CreateItemParams): Promise<AgentToolResult<WorldEventToolDetails>> => {
      const event = await runtime.actions.emitWorldEvent({
        type: "create_item",
        actorId: "god",
        text: td("create_item.event_text_format", { description: args.description }),
        data: { description: args.description, location: args.location, owner: args.owner },
      });

      return {
        content: [{ type: "text", text: td("create_item.result_recorded") }],
        details: { eventId: event.id },
      };
    },
  };
}

export function createSleepTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof sleepSchema, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  const toolName = "sleep";
  return {
    label: td("sleep.label"),
    name: toolName,
    description: td("sleep.description"),
    parameters: sleepSchema,
    execute: async (_toolCallId: string, args: SleepParams, signal, onUpdate) => {
      return submitToolAction(
        runtime.actions,
        characterId,
        "sleep",
        { durationGameMinutes: args.duration_game_minutes },
        args.reason ?? td("sleep.reason_default_format", { minutes: args.duration_game_minutes }),
        {
          toolName,
          displayTarget: td("sleep.display_target_format", { minutes: args.duration_game_minutes }),
          gameTime,
          signal,
          timeoutMs: sleepActionTimeoutMs(args.duration_game_minutes),
          onUpdate,
          interrupts,
        },
      );
    },
  };
}

// 容器存取的 LLM 工具是 createPutTool / createTakeTool（上方）。
// verb=take/put/inspect。三个 Godot action_kind 仍独立（deposit_to_container / withdraw_from_container
// / inspect_container），由 createUseContainerTool 内部按 verb 分发。

const CURRENCY_ITEM_IDS = new Set(["silver_coin", "gold_coin"]);

// offer 行：item 是 {name, index}，从背包反查；slotIndex 透传给 Godot 让其精确扣对应堆叠。
// 钱包货币（silver_coin / gold_coin）以"虚拟背包行"形式出现在背包列表头部（见
// prependWalletEntriesToBackpack），entry.slotIndex 为 undefined —— 不传 slotIndex 给
// Godot，Godot 端按 item id 自动从 wallet 扣。LLM 看到的是统一的 {name, index} 模型，
// 不用记"货币要特殊处理"。
function resolveTradeOfferLine(
  line: { item: { name: string; index: number }; count: number },
  currentContext?: AgentCurrentContext,
): { item: string; count: number; slotIndex?: number } {
  const item = resolveItemByIndex(line.item, "backpack", currentContext);
  if (!isMoveTargetError(item)) {
    const count = validateTradeLineCount(line.count, item.id, item.label);
    return item.slotIndex != null
      ? { item: item.id, count, slotIndex: item.slotIndex }
      : { item: item.id, count };
  }
  // 背包里没有这件 → 可能是货架主把自家货架上的货拿出来 offer（主动卖）。货架货不在 # 背包
  // 列表里，没有 backpack index，所以退回纯 name→slug 解析；究竟有没有货、人在不在货架旁，
  // 由 Godot 端（背包 + 附近自家货架）裁决。见 [[feedback_godot_is_authority]]。
  const byName = resolveItemTarget(line.item.name, currentContext);
  if (isMoveTargetError(byName)) {
    throw new Error(item.error); // 名字也认不出 → 保留更具体的背包错误
  }
  const count = validateTradeLineCount(line.count, byName.id, byName.label);
  return { item: byName.id, count };
}

// request 行：item 是字符串（对方背包不可见，无 index），按名字解析成 itemId 即可。
function resolveRequestTradeLine(
  line: { item: string; count: number },
): { item: string; count: number } {
  const itemId = resolveItemTarget(line.item, undefined);
  if (isMoveTargetError(itemId)) {
    throw new Error(itemId.error);
  }
  const count = validateTradeLineCount(line.count, itemId.id, itemId.label);
  return { item: itemId.id, count };
}

function validateTradeLineCount(count: number, itemId: string, itemLabel: string): number {
  if (CURRENCY_ITEM_IDS.has(itemId)) {
    const centi = Math.round(count * 100);
    if (!Number.isFinite(count) || centi < 1) {
      throw new Error(td("trade_line.error.invalid_currency_count", { item: itemLabel }));
    }
    return centi / 100;
  }
  if (!Number.isInteger(count) || count < 1) {
    throw new Error(td("trade_line.error.invalid_count", { item: itemLabel }));
  }
  return count;
}

// write / read 是通用可书写/可阅读物品机制（未来 inscribable paper、scroll、notebook 走这里）。
// Godot 端做实物校验：write 需要背包/附近容器有名为 item_name 的可书写道具，read 需要
// 同名可阅读物品。当前没有 writable/readable 标签的实物，所以通用路径会失败——但 Godot 端
// 对特定 (actor, item_name) 组合做脏检查走虚拟账本路径（如玛格达 + "王室薪水记录"）。
export function createWriteTool(
  runtime: ToolRuntime,
  characterId: string,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof writeSchema, CharacterActionToolDetails> {
  return {
    label: td("write.label"),
    name: "write",
    description: td("write.description"),
    parameters: writeSchema,
    execute: async (_toolCallId: string, args: WriteParams, signal, onUpdate) => {
      return submitToolAction(
        runtime.actions,
        characterId,
        "write",
        { itemName: args.item_name, title: args.title, content: args.content },
        args.reason ?? td("write.reason_format", { title: args.title }),
        { displayTarget: args.title, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

export function createReadTool(
  runtime: ToolRuntime,
  characterId: string,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof readSchema, CharacterActionToolDetails> {
  return {
    label: td("read.label"),
    name: "read",
    description: td("read.description"),
    parameters: readSchema,
    execute: async (_toolCallId: string, args: ReadParams, signal, onUpdate) => {
      return submitToolAction(
        runtime.actions,
        characterId,
        "read",
        { title: args.title },
        args.reason ?? td("read.reason_format", { title: args.title }),
        { displayTarget: args.title, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

export function createDoNothingTool(): AgentTool<typeof doNothingSchema, DoNothingToolDetails> {
  return {
    label: td("do_nothing.label"),
    name: "do_nothing",
    description: td("do_nothing.description"),
    parameters: doNothingSchema,
    execute: async (_toolCallId: string, args: DoNothingParams): Promise<AgentToolResult<DoNothingToolDetails>> => ({
      content: [{ type: "text", text: args.reason ? td("do_nothing.result_with_reason_format", { reason: args.reason }) : td("do_nothing.result_default") }],
      details: args.reason ? { didNothing: true, reason: args.reason } : { didNothing: true },
    }),
  };
}
