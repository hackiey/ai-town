import type { AppDb } from "../../db/sqlite.js";
import type { FarmPlotView, FarmView } from "./types.js";

// LEFT JOIN location_markers 把 ownerGroup 拼进来——farm 自己不存归属，靠 locationId
// 指向的 LocationMarker。Godot 场景树是真值（继承解析在 town_world.gd），DB 只是 mirror。
const SELECT_FARMS_IN = `
  SELECT f.farmId, f.locationId, f.totalSlots, f.moisture, f.pestCountToday, f.lastProcessedDay,
         lm.ownerGroup AS ownerGroup
  FROM farm_states AS f
  LEFT JOIN location_markers AS lm
    ON lm.townId = f.townId AND lm.locationId = f.locationId
  WHERE f.townId = ? AND f.farmId IN
`;

const SELECT_PLOTS_IN = `
  SELECT farmId, plotIndex, varietyId, spawnedAtGameHour, stage,
         careScoreSum, careScoreCount, harvestsDone, hasPest
  FROM farm_plots
  WHERE townId = ? AND farmId IN
`;

// 一次性 SELECT 全部目标 farm 的 states + plots，按 farmId 分组返回。
// Manifest 给的 farmIds 数量一般 ≤ 10，单次 IN 查询足够。
export function getFarmsByIds(db: AppDb, townId: string, farmIds: string[]): FarmView[] {
  if (farmIds.length === 0) return [];
  const placeholders = farmIds.map(() => "?").join(",");
  const stateRows = safeAll(db, `${SELECT_FARMS_IN} (${placeholders})`, [townId, ...farmIds]);
  const plotRows = safeAll(db, `${SELECT_PLOTS_IN} (${placeholders})`, [townId, ...farmIds]);
  const plotsByFarm = new Map<string, FarmPlotView[]>();
  for (const raw of plotRows) {
    const row = raw as Record<string, unknown>;
    const farmId = String(row.farmId ?? "");
    if (!farmId) continue;
    const list = plotsByFarm.get(farmId) ?? [];
    list.push(rowToPlotView(row));
    plotsByFarm.set(farmId, list);
  }
  const farms: FarmView[] = [];
  for (const raw of stateRows) {
    const row = raw as Record<string, unknown>;
    const farmId = String(row.farmId ?? "");
    if (!farmId) continue;
    farms.push({
      farmId,
      locationId: String(row.locationId ?? ""),
      ownerGroup: row.ownerGroup == null ? undefined : String(row.ownerGroup),
      totalSlots: Number(row.totalSlots ?? 0),
      moisture: Number(row.moisture ?? 0),
      pestCountToday: Number(row.pestCountToday ?? 0),
      lastProcessedDay: Number(row.lastProcessedDay ?? -1),
      plots: (plotsByFarm.get(farmId) ?? []).sort((a, b) => a.plotIndex - b.plotIndex),
    });
  }
  return farms;
}

function rowToPlotView(r: Record<string, unknown>): FarmPlotView {
  return {
    plotIndex: Number(r.plotIndex ?? 0),
    varietyId: r.varietyId == null ? undefined : String(r.varietyId),
    spawnedAtGameHour: Number(r.spawnedAtGameHour ?? 0),
    stage: r.stage == null ? undefined : String(r.stage),
    careScoreSum: Number(r.careScoreSum ?? 0),
    careScoreCount: Number(r.careScoreCount ?? 0),
    harvestsDone: Number(r.harvestsDone ?? 0),
    hasPest: Number(r.hasPest ?? 0) !== 0,
  };
}

function safeAll(db: AppDb, sql: string, params: unknown[]): unknown[] {
  try {
    return db.prepare(sql).all(...params) as unknown[];
  } catch {
    return [];
  }
}
