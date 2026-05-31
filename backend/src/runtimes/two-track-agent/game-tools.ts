// Two-track agent 的完整工具集 = shared 工具集 + 本 agent 自己的 update_memory。

import type { AgentTool } from "@mariozechner/pi-agent-core";
import {
  createSharedGameAgentTools,
  type CreateGameAgentToolsOptions,
} from "../../agent-shared/game-tools/index.js";
import { createTwoTrackUpdateMemoryTool } from "./memory-tool.js";

export function createTwoTrackAgentTools(options: CreateGameAgentToolsOptions): AgentTool<any>[] {
  const tools = createSharedGameAgentTools(options);
  const agentKind = options.agentKind ?? "npc";
  // god agent 不写 memory（它是世界搭建者，不是住民）
  if (agentKind === "god" || !options.characterId) {
    return tools;
  }
  return [
    ...tools,
    createTwoTrackUpdateMemoryTool(options.memoryStorage, options.townId, options.characterId),
  ];
}
