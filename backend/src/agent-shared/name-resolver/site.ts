// "Navigable site" = location 或 workstation。move_to_location 工具 / 寻路目标
// 用这个抽象来允许 LLM 给"建筑/地点名"或"具体工作台名"任一种 string。

import { resolveLocationIdByName } from "./location.js";
import { resolveWorkstationIdByName } from "./workstation.js";

export function resolveNavigableSiteIdByName(value: unknown): string | undefined {
  return resolveLocationIdByName(value) ?? resolveWorkstationIdByName(value);
}
