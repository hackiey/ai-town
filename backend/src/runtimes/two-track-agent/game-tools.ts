// Two-track action 轨工具集 = shared 工具集。
// action 轨不再有 update_memory —— memory 写入是 thinking 轨的职责（见 thinking-track.ts
// 仍用 createTwoTrackUpdateMemoryTool）。action 只做快速反应，长期记忆交给慢轨沉淀。

import type { AgentTool } from "@mariozechner/pi-agent-core";
import {
  createSharedGameAgentTools,
  type CreateGameAgentToolsOptions,
} from "../../agent-shared/game-tools/index.js";

export function createTwoTrackAgentTools(options: CreateGameAgentToolsOptions): AgentTool<any>[] {
  return createSharedGameAgentTools(options);
}
