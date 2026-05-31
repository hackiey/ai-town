// 货币显示工具。和 src/sim/characters/money.gd 对齐：1 silver = 100 centi。
// 价格在 DB / wire 上是 centi (int)；显示给 LLM / UI 时除 100 是 silver (float)。

export const CENTI_PER_SILVER = 100;

export function centiToSilver(centi: number): number {
  return centi / CENTI_PER_SILVER;
}

export function silverToCenti(silver: number): number {
  return Math.round(silver * CENTI_PER_SILVER);
}

// "7.50 银" / "0 银"
export function formatSilverFromCenti(centi: number): string {
  if (!Number.isFinite(centi) || centi <= 0) return "0 银";
  return `${(centi / CENTI_PER_SILVER).toFixed(2)} 银`;
}

// silver(decimal) → 显示串。0.5 → "0.50 银"，3 → "3.00 银"。
export function formatSilver(silver: number): string {
  if (!Number.isFinite(silver) || silver <= 0) return "0 银";
  return `${silver.toFixed(2)} 银`;
}
