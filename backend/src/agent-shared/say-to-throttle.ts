// say_to speaker 端节流公式。
// 在 createSayToTool 入口 await 这么久才 submit action，模拟"说话前的准备耗时"，
// 天然 throttle speaker 自己下一句的频率。
//
// 历史上还做过 listener 端延迟分发（NPC→NPC say_to 推迟 publish 到 wake bus），
// 想压低对话节奏但反而把 sensory 事件挤到周期性 working-memory 唤醒后面，已移除。
//
// 公式：max(5 秒, ceil(len/8) 秒)。默认 5 秒地板，超过 40 字按 ~8 字/秒（接近中文阅读速度）。
//   例：5 字 → 5s；40 字 → 5s；80 字 → 10s；160 字 → 20s。

const SAY_TO_MIN_MS = 5_000;
const SAY_TO_MS_PER_CHAR = 1000 / 8;

export function sayToThrottleMs(text: string): number {
  const length = typeof text === "string" ? text.length : 0;
  return Math.max(SAY_TO_MIN_MS, Math.ceil(length * SAY_TO_MS_PER_CHAR));
}
