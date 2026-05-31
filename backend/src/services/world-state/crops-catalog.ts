// Backend variety catalog 退化为"展示型常量"——stage 公式 / stage id 列表 / maturation
// 全部下沉到 Godot (data/mechanics/crops.lua)，再由 Godot 算好 stage 写盘
// (farm_plots.stage)。Backend 不再镜像公式 / variety stages 数组，避免单位 / 阶段
// 漂移；只保留 backend 渲染 needsWater / tooWet 还需要的 moisture 区间，以及
// fallback displayName。
//
// stage 显示名走 i18n catalog 的 prompt.context.crop_stage.*，per-variety 覆盖见
// cropStageDisplayName。
//
// ripe 判定：stage === "ripe"（generic 末态 id 由 Lua 端 stages 列表保证恒为
// "ripe"）；如果哪天有 variety 末态不叫 ripe，把判定升级成查表，但目前不需要。

import { getActiveLocale, has, t } from "../../i18n/index.js";

export type CropVarietyCatalogEntry = {
  id: string;
  displayName: string;
  optimalMoistureMin: number;
  optimalMoistureMax: number;
};

const VARIETIES: Record<string, CropVarietyCatalogEntry> = {
  tomato: {
    id: "tomato",
    displayName: "番茄",
    optimalMoistureMin: 0.2,
    optimalMoistureMax: 0.8,
  },
  wheat: {
    id: "wheat",
    displayName: "小麦",
    optimalMoistureMin: 0.2,
    optimalMoistureMax: 0.8,
  },
  flax: {
    id: "flax",
    displayName: "亚麻",
    optimalMoistureMin: 0.2,
    optimalMoistureMax: 0.8,
  },
};

export function getVariety(id: string | undefined): CropVarietyCatalogEntry | undefined {
  if (!id) return undefined;
  return VARIETIES[id];
}

export const RIPE_STAGE = "ripe";

export function isRipeStage(stage: string | undefined): boolean {
  return stage === RIPE_STAGE;
}

// stage 显示名：先按 variety 覆盖（prompt.context.crop_stage.<variety>.<stage>），
// 没命中走 default (prompt.context.crop_stage.default.<stage>)，再没命中返回 stage 字面。
// Godot 端 Varieties.display_stage_name 走完全相同的 fallback 链。
export function cropStageDisplayName(varietyId: string | undefined, stage: string | undefined): string {
  if (!stage) return "";
  const locale = getActiveLocale();
  if (varietyId) {
    const varietyKey = `prompt.context.crop_stage.${varietyId}.${stage}`;
    if (has(varietyKey, locale)) {
      return t(varietyKey, locale);
    }
  }
  const defaultKey = `prompt.context.crop_stage.default.${stage}`;
  if (has(defaultKey, locale)) {
    return t(defaultKey, locale);
  }
  return stage;
}
