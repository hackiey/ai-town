// 共享工具集装配。注意：update_memory 不在这里——它的实现是 per-agent 的，
// 每个 agent 自己 createXxxAgentMemoryTool 然后和这里返回的工具列表 concat 起来。
// 见 [[feedback_agent_memory_strategy_per_agent]]。

import type { AgentTool } from "@mariozechner/pi-agent-core";
import { listProficiencyCrafts, skillIdForCraft, type CraftSlug } from "./craft-registry.js";
import {
  createAssembleTool,
  createBoilSaltTool,
  createBurnCharcoalTool,
  createCookTool,
  createCreateItemTool,
  createDoNothingTool,
  createDrawWaterTool,
  createDropItemTool,
  createMillGrainTool,
  createMineTool,
  createMoveToLocationTool,
  createOfferTool,
  createPickUpItemTool,
  createPlanFarmWorkTool,
  createPutTakeTool,
  createReadTool,
  createRespondTool,
  createSayToTool,
  createSleepTool,
  createSmeltTool,
  createSmithTool,
  createUseItemTool,
  createViewContainerTool,
  createWoodworkTool,
  createWriteTool,
} from "./tool-factories.js";
import type { AgentCurrentContext } from "../prompt-context/types.js";
import type { AgentToolInterrupts, CreateGameAgentToolsOptions } from "./types.js";

// craft slug → 对应工厂函数。所有 craft tool 工厂签名一致；通过这张表统一过滤注册。
type AxisToolFactory = (
  options: CreateGameAgentToolsOptions,
  characterId: string,
  currentContext: AgentCurrentContext | undefined,
  interrupts: AgentToolInterrupts | undefined,
) => AgentTool<any>;

const AXIS_TOOL_FACTORIES: Record<CraftSlug, AxisToolFactory> = {
  mine: createMineTool,
  woodwork: createWoodworkTool,
  burn_charcoal: createBurnCharcoalTool,
  smelt: createSmeltTool,
  smith: createSmithTool,
  assemble: createAssembleTool,
  cook: createCookTool,
  mill_grain: createMillGrainTool,
  boil_salt: createBoilSaltTool,
};

// NPC 是否被授予 craft 对应的手艺。判定：currentContext.proficiency 表里有
// skillIdForCraft(craft) 这个 key（任意 value，含 0）= 已授予。
// 真值来源：npcs.json 的 `proficiency` 字段 → boot 期 db.gd 写 npc_proficiency 表。
//
// 与"看得见但 access_denied"不同：access_denied 是工具在但被某次调用拒绝；
// 这里是工具完全不暴露给 LLM —— edda_hale 不会想着去铸金币，省 token + 防误调。
function isAxisAccessibleTo(
  craft: CraftSlug,
  currentContext: AgentCurrentContext | undefined,
): boolean {
  if (!currentContext?.proficiency) return false;
  const skillId = skillIdForCraft(craft);
  return currentContext.proficiency.some((p) => p.skillId === skillId);
}

export function createSharedGameAgentTools(options: CreateGameAgentToolsOptions): AgentTool<any>[] {
  const agentKind = options.agentKind ?? "npc";
  if (agentKind === "god") {
    return [
      createCreateItemTool(options),
      createDoNothingTool(),
    ];
  }

  const characterId = options.characterId;
  if (!characterId) {
    throw new Error("characterId is required for npc/player agent tools");
  }

  const gameTime = options.currentContext?.gameTime;
  const interrupts = options.interrupts;

  // 通用社交 / 物品交互工具（无 craft 门槛，所有 NPC 都暴露）
  const tools: AgentTool<any>[] = [
    createMoveToLocationTool(options, characterId, options.currentContext, interrupts),
    createSayToTool(options, characterId, options.currentContext, interrupts),
    createUseItemTool(options, characterId, options.currentContext, gameTime, interrupts),
    createPickUpItemTool(options, characterId, options.currentContext, gameTime, interrupts),
    createDropItemTool(options, characterId, options.currentContext, gameTime, interrupts),
  ];

  // 工作台 craft 手艺工具：按 NPC proficiency 过滤注册。
  // 见 docs/proficiency_issues.md #1 + craft-registry.ts。
  // 离对应工作台太远时 Godot 拒掉返回 tool error（同 plan_farm_work 契约，proximity
  // 由 Godot 侧裁决）；"完全不会这门手艺"则在这一层就不暴露。
  for (const craft of listProficiencyCrafts()) {
    if (!isAxisAccessibleTo(craft, options.currentContext)) continue;
    tools.push(AXIS_TOOL_FACTORIES[craft](options, characterId, options.currentContext, interrupts));
  }

  // 通用交互工具（不归 craft，无 proficiency 门槛）：
  //   - put_take：货架/容器统一存取（存入+取出合一），全员可用
  //   - view_container：查看货架/容器内容（货架带标价），全员可用
  //   - draw_water：井边直接使用型，无手艺
  // 未来想加 proficiency gating 到 craft 工具时，**不要**误伤这些。
  tools.push(createPutTakeTool(options, characterId, options.currentContext, interrupts));
  tools.push(createViewContainerTool(options.currentContext));
  tools.push(createDrawWaterTool(options, characterId, options.currentContext, interrupts));

  // 通信 / 交易 / 休息 / 兜底
  tools.push(createOfferTool(options, characterId, options.currentContext, gameTime, interrupts));
  tools.push(createSleepTool(options, characterId, options.currentContext, interrupts));
  tools.push(createDoNothingTool());

  // 所有工具永远 expose 给 LLM —— 旧版按 currentContext.X.length 做的 gating 取消。
  // schema 在对应集合为空时降级成 free-form string，调用是否合法（有 trade /
  // 有 owned shelf / 在 shelf 旁）一律由 Godot 端校验后返回 tool error。
  tools.push(createRespondTool(options, characterId, options.currentContext, gameTime, interrupts));
  // 常驻注册 plan_farm_work：让 LLM 始终知道这工具存在；不在田边时由 Godot 端的 farm
  // runner 拒掉错误回到 LLM 当作行为信号。schema 在 farm 名 enum 为空时自动降级成自由
  // string，不会因为 currentContext 不全而崩。
  tools.push(createPlanFarmWorkTool(options, characterId, options.currentContext, interrupts));

  // write/read：通用可书写/可阅读物品。多数情况下因为没有 writable/readable 道具而走 Godot 端
  // 错误路径；特定 (group, item_name) 组合（如 royal_treasurer 群成员 + "王室薪水记录"）走
  // 脏检查到虚拟账本路径，read 会自动拼上 mining_log 系统真值供查账。
  tools.push(createWriteTool(options, characterId, gameTime, interrupts));
  tools.push(createReadTool(options, characterId, gameTime, interrupts));

  return tools;
}
