extends Node

# 矿场系统的 GDScript orchestrator —— 规则全在 data/mechanics/mining.lua。
# 每次挖矿尝试让 lua 用固定 p 决定是否产出。
# 真值在 SQLite mine_state 表（schema 在 Db._GAME_WORLD_SCHEMA）。

# mine_id (= location id) → 每次挥镐固定产出概率。
# swing 间隔 10 game-min（mining.lua ATTEMPT_INTERVAL_SECONDS），一次 dig action 6 swing。
# 当前经济目标：
#   gold_mine   0.2 × 6 × 10h × 1 工人 ≈ 12 ore/day
#   silver_mine 0.3 × 6 × 10h × 2 工人 ≈ 36 ore/day
#   iron_mine   0.5 × 6 × 10h × 1 工人 ≈ 30 ore/day
const _FIXED_P: Dictionary = {
	"gold_mine":   0.2,
	"silver_mine": 0.3,
	"iron_mine":   0.5,
}

const _MINE_BY_WORKSTATION: Dictionary = {
	"gold_mine_workstation": "gold_mine",
	"silver_mine_workstation": "silver_mine",
	"iron_mine_workstation": "iron_mine",
}

# 国营矿：产出自动入领主国库，矿工找玛格达 offer_trade 兑银币。
# 不在此集合中的矿（如铁矿）走私营，产出直接进矿工背包。
const _STATE_OWNED_MINES: Dictionary = {
	"gold_mine": true,
	"silver_mine": true,
}


func _ready() -> void:
	if not RunMode.is_runtime():
		set_process(false)
		return
	_ensure_seed()


func _ensure_seed() -> void:
	for mine_id in _FIXED_P.keys():
		var p := float(_FIXED_P[mine_id])
		var existing: Dictionary = Db.get_mine_state(String(mine_id))
		if existing.is_empty():
			Db.save_mine_state(String(mine_id), p, 0, 0)
		elif not is_equal_approx(float(existing.get("currentP", p)), p):
			Db.save_mine_state(String(mine_id), p, 0, 0)


# ─── Public API ───────────────────────────────────────────────────────

func current_p(mine_id: String) -> float:
	mine_id = mine_id_for_workstation(mine_id)
	var row: Dictionary = Db.get_mine_state(mine_id)
	if row.is_empty():
		return 0.0
	return float(row.get("currentP", 0.0))


# 挖矿开销查询：真值在 mining.lua on_attempt_cost。
# 返回 {stamina_cost, interval_game_seconds, duration_seconds}。
const _ATTEMPT_COST_FALLBACK := {
	"stamina_cost": 0.0,
	"interval_game_seconds": 0.0,
	"duration_seconds": 0.0,
}


func attempt_cost() -> Dictionary:
	var inv := MechanicHost.invoke("mining", "on_attempt_cost", {})
	if not bool(inv.get("ok", false)):
		push_warning("[Mines] on_attempt_cost failed: %s" % inv.get("error", ""))
		return _ATTEMPT_COST_FALLBACK
	var rv: Variant = inv.get("return_value")
	if not (rv is Dictionary):
		push_warning("[Mines] on_attempt_cost returned non-dict")
		return _ATTEMPT_COST_FALLBACK
	var d: Dictionary = rv as Dictionary
	return {
		"stamina_cost": float(d.get("stamina_cost", 0.0)),
		"interval_game_seconds": float(d.get("interval_game_seconds", 0.0)),
		"duration_seconds": float(d.get("duration_seconds", 0.0)),
	}


# 一次挖矿尝试：lua 用 math.random() < p 决定。计数永远写。
# work_impair：醉酒/生病时临时压低有效命中率（不写回矿脉 currentP），同采矿熟练度一处口径。
func try_yield(mine_id: String, work_impair: float = 0.0) -> bool:
	mine_id = mine_id_for_workstation(mine_id)
	if Db.get_mine_state(mine_id).is_empty():
		return false
	var p: float = maxf(0.0, current_p(mine_id) - work_impair)
	var result := MechanicHost.invoke("mining", "on_attempt", { "current_p": p })
	var rv: Variant = result.get("return_value")
	var success: bool = bool(rv) if (rv is bool) else false
	Db.inc_mine_counters(mine_id, 1, 1 if success else 0)
	return success


func is_mine(mine_id: String) -> bool:
	return _FIXED_P.has(mine_id) or _MINE_BY_WORKSTATION.has(mine_id)


func mine_id_for_workstation(workstation_id: String) -> String:
	return str(_MINE_BY_WORKSTATION.get(workstation_id, workstation_id))


# 是否走 treasury_vault 路由（国营矿）。
# 私营矿（如 iron_mine）产出直接入矿工背包。
func routes_to_treasury(mine_or_workstation_id: String) -> bool:
	var mid := mine_id_for_workstation(mine_or_workstation_id)
	return bool(_STATE_OWNED_MINES.get(mid, false))
