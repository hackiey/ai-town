extends Node

# 端到端验证 stamina 架构：
#   1. lua 层：well.on_draw_cost / crops.on_action_cost / mining.on_attempt_cost 返值正确
#   2. GDScript 层：StaminaWallet.try_spend / grant 的边界（足/不足/0/负数/cap）
#
# 跑法: godot --headless --main-scene res://scripts/stamina_smoke.tscn

const WELL_LUA   := "res://data/mechanics/well.lua"
const CROPS_LUA  := "res://data/mechanics/crops.lua"
const MINING_LUA := "res://data/mechanics/mining.lua"


# 最小 character stub：只有 wallet 用到的字段/方法。
class FakeChar:
	extends RefCounted
	var stamina: float = 100.0
	var max_stamina: float = 100.0


func _ready() -> void:
	var ok := _run_lua() and _run_wallet()
	print("\n[stamina-smoke] result: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


# ─── lua hooks ────────────────────────────────────────────────────

func _run_lua() -> bool:
	var ok := true
	ok = _check_well() and ok
	ok = _check_crops() and ok
	ok = _check_mining() and ok
	return ok


func _check_well() -> bool:
	var state: Variant = _load("well", WELL_LUA)
	if state == null:
		return _fail("well.lua load failed")
	var r := ScriptExecutor.call_hook(state, "on_draw_cost", {})
	var rv: Variant = r.get("return_value")
	if not (rv is Dictionary):
		return _fail("well.on_draw_cost did not return dict")
	var d: Dictionary = rv
	var ok_case := absf(float(d.get("stamina_cost", 0.0)) - 3.0) < 0.001 \
		and absf(float(d.get("duration_seconds", 0.0)) - 180.0) < 0.001
	_report("well.on_draw_cost = {stamina=3, duration=180}", ok_case, d)
	var r10 := ScriptExecutor.call_hook(state, "on_draw_cost", {"amount_liters": 10.0})
	var d10_v: Variant = r10.get("return_value")
	if not (d10_v is Dictionary):
		return _fail("well.on_draw_cost(10L) did not return dict") and ok_case
	var d10: Dictionary = d10_v
	var ok_linear := absf(float(d10.get("stamina_cost", 0.0)) - 1.5) < 0.001 \
		and absf(float(d10.get("duration_seconds", 0.0)) - 90.0) < 0.001
	_report("well.on_draw_cost(10L) = {stamina=1.5, duration=90}", ok_linear, d10)
	return ok_case and ok_linear


func _check_crops() -> bool:
	var state: Variant = _load("crops", CROPS_LUA)
	if state == null:
		return _fail("crops.lua load failed")
	# 期望：plant/harvest=3/60，pest/uproot=3/120，water=10/900，unknown=0/0
	var cases := [
		{"kind": "plant",   "stamina": 3.0,  "duration": 60.0},
		{"kind": "harvest", "stamina": 3.0,  "duration": 60.0},
		{"kind": "pest",    "stamina": 3.0,  "duration": 120.0},
		{"kind": "uproot",  "stamina": 3.0,  "duration": 120.0},
		{"kind": "water",   "stamina": 10.0, "duration": 900.0},
		{"kind": "bogus",   "stamina": 0.0,  "duration": 0.0},
	]
	var all := true
	for c_v in cases:
		var c: Dictionary = c_v
		var r := ScriptExecutor.call_hook(state, "on_action_cost", {"kind": c["kind"]})
		var d_v: Variant = r.get("return_value")
		if not (d_v is Dictionary):
			all = _fail("on_action_cost(%s) non-dict" % c["kind"]) and all
			continue
		var d: Dictionary = d_v
		var ok_case := absf(float(d.get("stamina_cost", 0.0)) - float(c["stamina"])) < 0.001 \
			and absf(float(d.get("duration_seconds", 0.0)) - float(c["duration"])) < 0.001
		_report("crops.on_action_cost(%s)" % c["kind"], ok_case, d)
		all = ok_case and all
	return all


func _check_mining() -> bool:
	var state: Variant = _load("mining", MINING_LUA)
	if state == null:
		return _fail("mining.lua load failed")
	var r := ScriptExecutor.call_hook(state, "on_attempt_cost", {})
	var rv: Variant = r.get("return_value")
	if not (rv is Dictionary):
		return _fail("mining.on_attempt_cost did not return dict")
	var d: Dictionary = rv
	var ok_case := absf(float(d.get("stamina_cost", 0.0)) - 6.0) < 0.001 \
		and absf(float(d.get("interval_game_seconds", 0.0)) - 600.0) < 0.001 \
		and absf(float(d.get("duration_seconds", 0.0)) - 3600.0) < 0.001
	_report("mining.on_attempt_cost = {stamina=6, interval=600, duration=3600}", ok_case, d)
	return ok_case


# ─── StaminaWallet ────────────────────────────────────────────────

func _run_wallet() -> bool:
	var ok := true

	# 1. 充足体力 spend 5 → ok，扣 5
	var c1 := FakeChar.new()
	var r1 := StaminaWallet.try_spend(c1, 5.0, "test:1")
	var ok1 := bool(r1.get("ok", false)) and absf(c1.stamina - 95.0) < 0.001 \
		and absf(float(r1.get("stamina_cost", 0.0)) - 5.0) < 0.001
	_report("wallet: spend 5 from 100 → 95", ok1, r1)
	ok = ok1 and ok

	# 2. 体力 3 spend 5 → fail code=stamina_depleted，不改 stamina
	var c2 := FakeChar.new()
	c2.stamina = 3.0
	var r2 := StaminaWallet.try_spend(c2, 5.0, "test:2")
	var ok2 := not bool(r2.get("ok", true)) and str(r2.get("code", "")) == "stamina_depleted" \
		and absf(c2.stamina - 3.0) < 0.001
	_report("wallet: spend 5 from 3 → reject, stamina untouched", ok2, r2)
	ok = ok2 and ok

	# 3. spend 0 → ok 无副作用
	var c3 := FakeChar.new()
	c3.stamina = 50.0
	var r3 := StaminaWallet.try_spend(c3, 0.0, "test:3")
	var ok3 := bool(r3.get("ok", false)) and absf(c3.stamina - 50.0) < 0.001
	_report("wallet: spend 0 → no-op", ok3, r3)
	ok = ok3 and ok

	# 4. spend 负数 → 拒（防呆，不改 stamina）
	var c4 := FakeChar.new()
	c4.stamina = 50.0
	var r4 := StaminaWallet.try_spend(c4, -5.0, "test:4")
	var ok4 := bool(r4.get("ok", false)) and absf(c4.stamina - 50.0) < 0.001
	_report("wallet: spend -5 → no-op (rejected)", ok4, r4)
	ok = ok4 and ok

	# 5. grant 20 from 50 → 70
	var c5 := FakeChar.new()
	c5.stamina = 50.0
	var r5 := StaminaWallet.grant(c5, 20.0, "test:5")
	var ok5 := bool(r5.get("ok", false)) and absf(c5.stamina - 70.0) < 0.001
	_report("wallet: grant 20 from 50 → 70", ok5, r5)
	ok = ok5 and ok

	# 6. grant 200 from 50 → clamp at max_stamina(100)
	var c6 := FakeChar.new()
	c6.stamina = 50.0
	var r6 := StaminaWallet.grant(c6, 200.0, "test:6")
	var ok6 := bool(r6.get("ok", false)) and absf(c6.stamina - 100.0) < 0.001
	_report("wallet: grant 200 from 50 → clamp at 100", ok6, r6)
	ok = ok6 and ok

	# 7. grant 20 with max_cap=60 from 50 → clamp at 60
	var c7 := FakeChar.new()
	c7.stamina = 50.0
	var r7 := StaminaWallet.grant(c7, 20.0, "test:7", 60.0)
	var ok7 := bool(r7.get("ok", false)) and absf(c7.stamina - 60.0) < 0.001
	_report("wallet: grant 20 from 50 with cap=60 → clamp at 60", ok7, r7)
	ok = ok7 and ok

	# 8. can_afford
	var c8 := FakeChar.new()
	c8.stamina = 10.0
	var ok8 := StaminaWallet.can_afford(c8, 5.0) and not StaminaWallet.can_afford(c8, 15.0) \
		and StaminaWallet.can_afford(c8, 0.0)
	_report("wallet: can_afford(5)=true, (15)=false, (0)=true", ok8, {})
	ok = ok8 and ok

	return ok


# ─── helpers ──────────────────────────────────────────────────────

func _load(name: String, path: String) -> Variant:
	var src := FileAccess.get_file_as_string(path)
	if src.is_empty():
		return null
	return ScriptExecutor.load_module(src, name)


func _report(label: String, ok_case: bool, payload: Variant) -> void:
	print("[%s] %s | %s" % ["PASS" if ok_case else "FAIL", label, JSON.stringify(payload)])


func _fail(msg: String) -> bool:
	print("[FAIL] " + msg)
	return false
