// Two-track action 轨 session 模块。
// runtime.ts 只 import 这个 index，内部拆分对外部透明。

export {
  ActionTrackSession,
  readWorkingMemoryFromStorage,
  WORKING_MEMORY_STORAGE_KEY,
  type ActionTrackSessionOptions,
} from "./session.js";
import { stableHash } from "../../../agent-shared/utils/primitives.js";

// 错峰起点：把 NPC 的 idle/thinking tick 起点散开 1..interval。
// action 轨自己不 idle tick，但 PiAgentRuntime 仍然按 characterId 调度 thinking 轨用得到。
export function initialIdleTickOffsetGameMinutes(characterId: string, idleTickGameMinutes: number): number {
  return 1 + (stableHash(characterId) % Math.max(1, idleTickGameMinutes));
}
