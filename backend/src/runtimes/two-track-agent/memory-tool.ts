// Two-track agent 的 update_memory tool。共享 toolset 不提供这个工具——
// memory 写入策略是 per-agent 核心差异点（见 [[feedback_agent_memory_strategy_per_agent]]）。
// 这里用 schemas.updateMemorySchema + 本 agent 的 memory.ts 拼起来。

import type { AgentTool, AgentToolResult } from "@mariozechner/pi-agent-core";
import {
  type MemoryToolDetails,
  type UpdateMemoryParams,
  updateMemorySchema,
} from "../../agent-shared/game-tools/index.js";
import { td } from "../../agent-shared/game-tools/i18n.js";
import type { GameTimeSnapshot } from "../../godot-link/protocol.js";
import type { AgentMemoryKind, PromptMemorySections } from "../../agent-shared/prompt-context/types.js";
import type { RuntimeStorage } from "../../agent-host/storage.js";
import { updateTwoTrackAgentMemory } from "./memory.js";

export function createTwoTrackUpdateMemoryTool(
  memoryStorage: RuntimeStorage,
  townId: string,
  characterId: string,
  gameTime?: GameTimeSnapshot,
  promptMemory?: PromptMemorySections,
): AgentTool<typeof updateMemorySchema, MemoryToolDetails> {
  const memoryIdByIndex = new Map((promptMemory?.all ?? []).map((memory) => [memory.promptIndex, memory.id]));
  return {
    label: td("update_memory.label"),
    name: "update_memory",
    description: td("update_memory.description"),
    parameters: updateMemorySchema,
    execute: async (_toolCallId: string, args: UpdateMemoryParams): Promise<AgentToolResult<MemoryToolDetails>> => {
      const operation = args.operation as MemoryToolDetails["operation"];
      const kind = args.kind as AgentMemoryKind | undefined;
      const memoryIndex = args.memory_index;
      if (args.operation === "add" && !kind) {
        throw new Error(td("update_memory.error_kind_required"));
      }
      if (args.operation === "add" && !args.new_string?.trim()) {
        throw new Error(td("update_memory.error_add_requires_new"));
      }
      if ((args.operation === "edit" || args.operation === "remove") && memoryIndex == null) {
        throw new Error(td("update_memory.error_index_required"));
      }
      if (args.operation === "edit" && args.new_string == null) {
        throw new Error(td("update_memory.error_new_required"));
      }
      const memoryId = memoryIndex != null ? memoryIdByIndex.get(memoryIndex) : undefined;
      if ((args.operation === "edit" || args.operation === "remove") && promptMemory && !memoryId) {
        return {
          content: [{ type: "text", text: td("update_memory.result_not_found") }],
          details: { operation, memoryIndex },
        };
      }

      const result = await updateTwoTrackAgentMemory(memoryStorage, {
        operation,
        kind,
        memoryIndex,
        memoryId,
        newString: args.new_string,
        gameTime,
        townId,
        characterId,
      });

      const text = result.status === "added"
        ? td("update_memory.result_added")
        : result.status === "updated"
          ? td("update_memory.result_updated")
          : result.status === "removed"
            ? td("update_memory.result_removed")
            : result.status === "not_found"
              ? td("update_memory.result_not_found")
              : td("update_memory.result_unchanged");

      return {
        content: [{ type: "text", text }],
        details: {
          operation,
          memoryIndex: result.memoryIndex,
          memoryId: result.memoryId,
        },
      };
    },
  };
}
