import type { AgentRuntimeFactory } from "../agent-host/runtime.js";
import { createNullAgentRuntime } from "./null/runtime.js";

export const runtimeFactories: Record<string, AgentRuntimeFactory> = {
  null: createNullAgentRuntime,
};

export type RuntimeName = keyof typeof runtimeFactories;

export function createRuntime(name: RuntimeName) {
  return runtimeFactories[name]({ name });
}
