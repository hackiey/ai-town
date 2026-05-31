import type { AgentTool, AgentToolResult, AgentToolUpdateCallback } from "@mariozechner/pi-agent-core";
import type { ShelfOp } from "../../godot-link/actions.js";
import type { GameTimeSnapshot } from "../../godot-link/protocol.js";
import { getActiveLocale, t } from "../../i18n/index.js";
import { localizeStringValue } from "../name-resolver/index.js";
import type { AgentCurrentContext } from "../prompt-context/types.js";
import { sayToThrottleMs } from "../say-to-throttle.js";
import { td } from "./i18n.js";
import {
  formatMoveToLocationToolResult,
  formatPlanFarmWorkToolResult,
  formatSayToToolResult,
  submitToolAction,
} from "./action-results.js";
import {
  buyFromShelfSchema,
  createAssembleSchema,
  createBoilSaltSchema,
  createBurnCharcoalSchema,
  createCookSchema,
  createDrawWaterSchema,
  createItemSchema,
  createBuyFromShelfSchema,
  createMillGrainSchema,
  createMineSchema,
  createMoveToLocationSchema,
  createPlanFarmWorkSchema,
  createSayToSchema,
  createSmeltSchema,
  createSmithSchema,
  createUpdateShelfSchema,
  createUseContainerSchema,
  createViewShelfSchema,
  createWoodworkSchema,
  doNothingSchema,
  dropItemSchema,
  offerSchema,
  pickUpItemSchema,
  readSchema,
  respondSchema,
  sleepSchema,
  updateShelfSchema,
  useItemSchema,
  viewShelfSchema,
  writeSchema,
  type AssembleParams,
  type BoilSaltParams,
  type BurnCharcoalParams,
  type BuyFromShelfParams,
  type CookParams,
  type CreateItemParams,
  type DoNothingParams,
  type DrawWaterParams,
  type DropItemParams,
  type ItemRefParam,
  type MillGrainParams,
  type MineParams,
  type MoveToLocationParams,
  type OfferParams,
  type PickUpItemParams,
  type PlanFarmWorkParams,
  type ReadParams,
  type RespondParams,
  type SayToParams,
  type SleepParams,
  type SmeltParams,
  type SmithParams,
  type UpdateShelfParams,
  type UseContainerParams,
  type UseItemParams,
  type ViewShelfParams,
  type WoodworkParams,
  type WriteParams,
} from "./schemas.js";
import {
  isMoveTargetError,
  normalizePlanFarmWorkOps,
  normalizeWorkstationActionInputs,
  resolveCraftWorkstation,
  resolveItemByIndex,
  resolveItemTarget,
  resolveMoveTarget,
  resolveOptionalKnownTargetName,
  resolvePlanFarm,
  resolveShelfTarget,
  resolveSpeechTarget,
  resolveTradeTarget,
  resolveUseWorkstationName,
} from "./targets.js";
import { getCraftSpec, verbForWorkstation, type CraftSlug } from "./craft-registry.js";
import type { ActionName, WorkstationActionTarget } from "../../godot-link/actions.js";
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
// 12 个按 proficiency skill axis 拆分的 tool 替代旧 use_workstation —— 见 craft-registry.ts +
// docs/proficiency_system.md。每个 tool 一个 wire action，共享 WorkstationActionTarget 形态。
// workstation 检测仍由 Godot _find_workstation 兜底（[[feedback_godot_is_authority]]）。

function mineActionTimeoutMs(workstationId: string): number | undefined {
  if (workstationId === "gold_mine_workstation" || workstationId === "silver_mine_workstation") {
    return timeScaledActionTimeoutMs(60);
  }
  return undefined;
}

// 10 个 production axis 共享的执行体：装配 WorkstationActionTarget + submitToolAction。
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
      const verb = verbForWorkstation("woodwork", workstation.id)!;
      return runAxisCraftAction({
        axis: "woodwork", runtime, characterId, currentContext, gameTime, signal, onUpdate, interrupts,
        workstation, verb, subOption: args.sub_option?.trim() ?? "", inputs: args.inputs,
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

// 容器 (take/put/inspect) —— 从旧 use_workstation 路由层剥离成独立工具，schema 把 verb 一级化。
// 三个 wire action（deposit_to_container / withdraw_from_container / inspect_container）不变。
export function createUseContainerTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("use_container.label"),
    name: "use_container",
    description: td("use_container.description"),
    parameters: createUseContainerSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as UseContainerParams;
      // 容器型 workstation 在 nearbyWorkstations 里：id === workstationId === containerId
      // （见 assemble-from-manifest.ts:457-460）。沿用 resolveUseWorkstationName 已有逻辑。
      const workstation = resolveUseWorkstationName(args.container, currentContext);
      if (isMoveTargetError(workstation)) throw new Error(workstation.error);
      // inspect: 直接发 inspect_container。
      if (args.verb === "inspect") {
        return submitToolAction(
          runtime.actions,
          characterId,
          "inspect_container",
          { containerId: workstation.id },
          args.reason ?? td("inspect_container.reason_format", { label: workstation.label }),
          { toolName: "use_container", displayTarget: workstation.label, gameTime, signal, onUpdate, interrupts },
        );
      }
      // take / put：必须给 item + quantity。
      if (!args.item?.name?.trim()) {
        throw new Error(td(args.verb === "take" ? "withdraw_from_container.error_missing_item" : "deposit_to_container.error_missing_item"));
      }
      const resolved = args.verb === "put"
        ? resolveItemByIndex(args.item, "backpack", currentContext)
        : resolveItemByIndex(args.item, { kind: "container", containerId: workstation.id }, currentContext);
      if (isMoveTargetError(resolved)) throw new Error(resolved.error);
      const quantity = args.quantity ?? 1;
      const actionKind = args.verb === "take" ? "withdraw_from_container" : "deposit_to_container";
      const reasonKey = args.verb === "take" ? "withdraw_from_container.reason_format" : "deposit_to_container.reason_format";
      const target: { containerId: string; itemId: string; quantity: number; containerSlotIndex?: number; actorSlotIndex?: number } = {
        containerId: workstation.id, itemId: resolved.id, quantity,
      };
      if (args.verb === "take" && resolved.slotIndex != null) target.containerSlotIndex = resolved.slotIndex;
      if (args.verb === "put" && resolved.slotIndex != null) target.actorSlotIndex = resolved.slotIndex;
      return submitToolAction(
        runtime.actions, characterId, actionKind, target,
        args.reason ?? td(reasonKey, { label: workstation.label }),
        { toolName: "use_container", displayTarget: workstation.label, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

// 打水 —— well 直接使用型工作台。沿用 WorkstationActionTarget 形态走同一 Godot 路径。
export function createDrawWaterTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  interrupts?: AgentToolInterrupts,
): AgentTool<any, CharacterActionToolDetails> {
  const gameTime = currentContext?.gameTime;
  return {
    label: td("draw_water.label"),
    name: "draw_water",
    description: td("draw_water.description"),
    parameters: createDrawWaterSchema(),
    execute: async (_toolCallId, rawArgs, signal, onUpdate) => {
      const args = rawArgs as DrawWaterParams;
      const into = resolveItemByIndex(args.into, "backpack", currentContext);
      if (isMoveTargetError(into)) throw new Error(into.error);
      const target: WorkstationActionTarget = {
        workstationId: "well",
        verb: "direct",
        subOption: "",
        inputItemIds: [into.id],
        inputItemSlotIndices: [into.slotIndex],
      };
      return submitToolAction(
        runtime.actions,
        characterId,
        "draw_water",
        target,
        args.reason ?? td("draw_water.reason_default_format", { item: into.label }),
        {
          toolName: "draw_water",
          resultNote: td("draw_water.result_note"),
          displayTarget: into.label,
          gameTime, signal, onUpdate, interrupts,
        },
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

export function createPickUpItemTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof pickUpItemSchema, CharacterActionToolDetails> {
  return {
    label: td("pick_up_item.label"),
    name: "pick_up_item",
    description: td("pick_up_item.description"),
    parameters: pickUpItemSchema,
    execute: async (_toolCallId: string, args: PickUpItemParams, signal, onUpdate) => {
      const item = resolveItemByIndex(args.item, "nearby", currentContext);
      if (isMoveTargetError(item)) {
        throw new Error(item.error);
      }
      return submitToolAction(
        runtime.actions,
        characterId,
        "pick_up_item",
        // nearby perception 不带 instance id；Godot 按距离/默认规则选实例。quantity 缺省 1。
        {
          itemId: item.id,
          ...(args.quantity != null ? { quantity: args.quantity } : {}),
        },
        td("pick_up_item.reason_format", { item: item.label }),
        { displayTarget: item.label, gameTime, signal, onUpdate, interrupts },
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

export function createUpdateShelfTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof updateShelfSchema, CharacterActionToolDetails> {
  return {
    label: td("update_shelf.label"),
    name: "update_shelf",
    description: td("update_shelf.description"),
    parameters: createUpdateShelfSchema(),
    execute: async (_toolCallId: string, args: UpdateShelfParams, signal, onUpdate) => {
      const shelf = resolveShelfTarget(args.shelf, currentContext, "owned");
      if (isMoveTargetError(shelf)) {
        throw new Error(shelf.error);
      }
      // add 从我的背包补到货架 → entry.item 走 backpack 索引，slotIndex 透传让 Godot 取对那份；
      // update / remove 操作的是这个货架已有 listing → entry.item 走 shelf 索引，listingId 透传。
      const shelfScope = { kind: "shelf" as const, shelfId: shelf.id };
      const resolveAdd = (entry: { item: { name: string; index: number } }) => {
        const r = resolveItemByIndex(entry.item, "backpack", currentContext);
        if (isMoveTargetError(r)) throw new Error(r.error);
        return r;
      };
      const resolveShelf = (entry: { item: { name: string; index: number } }) => {
        const r = resolveItemByIndex(entry.item, shelfScope, currentContext);
        if (isMoveTargetError(r)) throw new Error(r.error);
        return r;
      };
      const ops: ShelfOp[] = [
        ...(args.add ?? []).map((entry) => {
          const r = resolveAdd(entry);
          return {
            type: "add" as const,
            itemId: r.id,
            ...(r.slotIndex != null ? { slotIndex: r.slotIndex } : {}),
            quantity: entry.quantity,
            priceSilver: entry.price_silver,
          };
        }),
        ...(args.update ?? []).map((entry) => {
          const r = resolveShelf(entry);
          return {
            type: "update" as const,
            itemId: r.id,
            ...(r.listingId != null ? { listingId: r.listingId } : {}),
            quantity: entry.quantity,
            priceSilver: entry.price_silver,
          };
        }),
        ...(args.remove ?? []).map((entry) => {
          const r = resolveShelf(entry);
          return {
            type: "remove" as const,
            itemId: r.id,
            ...(r.listingId != null ? { listingId: r.listingId } : {}),
            ...(entry.quantity != null ? { quantity: entry.quantity } : {}),
          };
        }),
      ];
      if (ops.length <= 0) {
        throw new Error("update_shelf 至少需要 add、update、remove 其中一组");
      }
      return submitToolAction(
        runtime.actions,
        characterId,
        "update_shelf",
        { shelfId: shelf.id, ops },
        args.reason ?? td("update_shelf.reason_format", { label: shelf.label }),
        { displayTarget: shelf.label, gameTime, signal, onUpdate, interrupts },
      );
    },
  };
}

export function createViewShelfTool(
  currentContext?: AgentCurrentContext,
): AgentTool<typeof viewShelfSchema, { shelfId: string; listingCount: number }> {
  return {
    label: td("view_shelf.label"),
    name: "view_shelf",
    description: td("view_shelf.description"),
    parameters: createViewShelfSchema(),
    execute: async (_toolCallId: string, args: ViewShelfParams) => {
      const shelf = resolveShelfTarget(args.shelf, currentContext, "nearby");
      if (isMoveTargetError(shelf)) {
        throw new Error(shelf.error);
      }
      const shelfContext = (currentContext?.nearbyShelves ?? []).find((entry) => entry.id === shelf.id);
      if (!shelfContext) {
        throw new Error(td("view_shelf.error_not_visible"));
      }
      const lines = shelfContext.listings.length === 0
        ? [td("view_shelf.result_empty")]
        : shelfContext.listings.map((listing) => (
          `[${listing.index ?? "?"}] ${listing.displayName ?? listing.itemId ?? listing.listingId} x${listing.quantity} @ ${listing.priceText ?? `${listing.priceSilver.toFixed(2)} 银`}`
        ));
      return {
        content: [{ type: "text", text: [`# 货架内容`, `货架：${shelf.label}`, `内容：${lines.join("；")}`].join("\n") }],
        details: {
          shelfId: shelfContext.id,
          listingCount: shelfContext.listings.length,
        },
      };
    },
  };
}

export function createBuyFromShelfTool(
  runtime: ToolRuntime,
  characterId: string,
  currentContext?: AgentCurrentContext,
  gameTime?: GameTimeSnapshot,
  interrupts?: AgentToolInterrupts,
): AgentTool<typeof buyFromShelfSchema, CharacterActionToolDetails> {
  return {
    label: td("buy_from_shelf.label"),
    name: "buy_from_shelf",
    description: td("buy_from_shelf.description"),
    parameters: createBuyFromShelfSchema(),
    execute: async (_toolCallId: string, args: BuyFromShelfParams, signal, onUpdate) => {
      const shelf = resolveShelfTarget(args.shelf, currentContext, "nearby");
      if (isMoveTargetError(shelf)) {
        throw new Error(shelf.error);
      }
      const item = resolveItemByIndex(args.item, { kind: "shelf", shelfId: shelf.id }, currentContext);
      if (isMoveTargetError(item)) {
        throw new Error(item.error);
      }
      if (item.listingId == null) {
        throw new Error(t("error.unknown_shelf_listing", getActiveLocale(), { listing: args.item.name }));
      }
      return submitToolAction(
        runtime.actions,
        characterId,
        "buy_from_shelf",
        { shelfId: shelf.id, listingId: item.listingId, quantity: args.quantity },
        args.reason ?? td("buy_from_shelf.reason_format", { label: item.label }),
        { displayTarget: item.label, gameTime, signal, onUpdate, interrupts },
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
      const offer = args.offer.map((line) => resolveOfferTradeLine(line, _currentContext));
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

// 容器三件套（deposit / withdraw / inspect）的 LLM 工具是 createUseContainerTool（上方）：
// verb=take/put/inspect。三个 Godot action_kind 仍独立（deposit_to_container / withdraw_from_container
// / inspect_container），由 createUseContainerTool 内部按 verb 分发。

const CURRENCY_ITEM_IDS = new Set(["silver_coin", "gold_coin"]);

// offer 行：item 是 {name, index}，从背包反查；slotIndex 透传给 Godot 让其精确扣对应堆叠。
// 钱包货币（silver_coin / gold_coin）以"虚拟背包行"形式出现在背包列表头部（见
// prependWalletEntriesToBackpack），entry.slotIndex 为 undefined —— 不传 slotIndex 给
// Godot，Godot 端按 item id 自动从 wallet 扣。LLM 看到的是统一的 {name, index} 模型，
// 不用记"货币要特殊处理"。
function resolveOfferTradeLine(
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
