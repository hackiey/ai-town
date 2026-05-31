import type { WorldEvent } from "../../godot-link/events.js";
import type { AgentRuntime, AgentRuntimeContext } from "../../agent-host/runtime.js";

export class NullAgentRuntime implements AgentRuntime {
  readonly name = "null";

  attach(_ctx: AgentRuntimeContext): void {
    return;
  }

  async onEvent(_event: WorldEvent, _ctx: AgentRuntimeContext): Promise<void> {
    return;
  }

  async detach(_ctx: AgentRuntimeContext): Promise<void> {
    return;
  }
}

export function createNullAgentRuntime(_params?: { name: string }): NullAgentRuntime {
  return new NullAgentRuntime();
}
