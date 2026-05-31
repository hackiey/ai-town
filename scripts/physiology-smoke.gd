extends Node

# 端到端验证 data/mechanics/physiology.lua：
#   - 不需要 town/server/backend，只用最小 scene + 自身 autoload
#   - 直接 ScriptExecutor.load_module + call_hook 跑各种 hunger / hp 输入
#   - 检查 raw_effects 里 lua 声明的 affect.* 是不是符合预期
#
# Effects.apply 端会把 fake_target as Character 转 null 然后报 error，但 raw_effects
# 仍然记录了 lua 声明的原始 effect dict —— 我们要的就是这个。
#
# 跑法: godot --headless --main-scene res://scripts/physiology_smoke.tscn

const PHYSIOLOGY_PATH := "res://data/mechanics/physiology.lua"


func _ready() -> void:
	var ok := _run_all()
	print("\n[smoke] result: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


func _run_all() -> bool:
	var source := FileAccess.get_file_as_string(PHYSIOLOGY_PATH)
	if source.is_empty():
		print("[smoke] FAIL: cannot read physiology.lua")
		return false

	var state := ScriptExecutor.load_module(source, "physiology")
	if state == null:
		print("[smoke] FAIL: load_module failed")
		return false

	var fake_target := Node.new()
	fake_target.name = "FakeChar"
	add_child(fake_target)

	var ok := true

	# ── on_slow_tick 场景 ────────────────────────────────────────────

	var r1 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 100.0, "max_hp": 100.0,
		"stamina": 100.0, "max_stamina": 100.0,
		"hunger": 100.0, "max_hunger": 100.0, "has_hungry": false,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok1 := _has_effect_where_float(r1, "modify_hunger", "amount", -2.083) \
		and not _has_effect(r1, "add_condition") \
		and not _has_effect(r1, "modify_hp")
	_report("1. 10-minute tick hunger=100 → -2.083 hunger only", ok1, r1)
	ok = ok and ok1

	var simulated_hunger := 100.0
	var ok_decay := true
	for _i in range(24):
		var r_decay := ScriptExecutor.call_hook(state, "on_slow_tick", {
			"character": fake_target, "hp": 100.0, "max_hp": 100.0,
			"stamina": 100.0, "max_stamina": 100.0,
			"hunger": simulated_hunger, "max_hunger": 100.0, "has_hungry": simulated_hunger <= 50.0,
			"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
		})
		simulated_hunger += _effect_float_sum(r_decay, "modify_hunger", "amount")
		ok_decay = ok_decay and not _has_effect(r_decay, "modify_hp")
	ok_decay = ok_decay and absf(simulated_hunger - 50.0) < 0.01
	_report("1b. hunger=100 after 4 hours → 50", ok_decay, { "raw_effects": [{ "type": "modify_hunger", "amount": simulated_hunger - 100.0 }] })
	ok = ok and ok_decay

	var r2 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 100.0, "max_hp": 100.0,
		"stamina": 80.0, "max_stamina": 100.0,
		"hunger": 52.083333, "max_hunger": 100.0, "has_hungry": false,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok2 := _has_effect_where(r2, "add_condition", "condition_id", "hungry") \
		and _has_effect_where_float(r2, "modify_hunger", "amount", -2.083) \
		and _has_effect_where_float(r2, "modify_stamina", "amount", -10.0) \
		and not _has_effect(r2, "modify_hp")
	_report("2. hunger reaches 50 → +hungry and stamina cap 70", ok2, r2)
	ok = ok and ok2

	var r3 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 100.0, "max_hp": 100.0,
		"stamina": 55.0, "max_stamina": 100.0,
		"hunger": 50.0, "max_hunger": 100.0, "has_hungry": true,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok3 := _has_effect_where_float(r3, "modify_hunger", "amount", -0.833) \
		and not _has_effect(r3, "add_condition") \
		and not _has_effect(r3, "remove_condition")
	_report("3. hunger=50 has_hungry → -0.833 hunger, no re-add", ok3, r3)
	ok = ok and ok3

	var r4 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 100.0, "max_hp": 100.0,
		"stamina": 48.0, "max_stamina": 100.0,
		"hunger": 90.0, "max_hunger": 100.0, "has_hungry": true,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok4 := _has_effect_where(r4, "remove_condition", "condition_id", "hungry")
	_report("4. hunger stays above clear threshold → -hungry", ok4, r4)
	ok = ok and ok4

	var r5 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 100.0, "max_hp": 100.0,
		"stamina": 33.0, "max_stamina": 100.0,
		"hunger": 50.5, "max_hunger": 100.0, "has_hungry": false,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok5 := _has_effect_where_float(r5, "modify_hunger", "amount", -1.133) \
		and _has_effect_where(r5, "add_condition", "condition_id", "hungry") \
		and not _has_effect(r5, "remove_condition")
	_report("5. hunger crosses below 50 → +hungry", ok5, r5)
	ok = ok and ok5

	var r6 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 10.0, "max_hp": 100.0,
		"stamina": 0.0, "max_stamina": 100.0,
		"hunger": 0.0, "max_hunger": 100.0, "has_hungry": true,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok6 := _has_effect_where_float(r6, "modify_hp", "amount", -0.333) \
		and not _has_effect(r6, "set_alive")
	_report("6. hunger=0 hp=10 → -0.333hp, alive", ok6, r6)
	ok = ok and ok6

	var r7 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 2.0, "max_hp": 100.0,
		"stamina": 0.0, "max_stamina": 100.0,
		"hunger": 0.0, "max_hunger": 100.0, "has_hungry": true,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok7 := _has_effect_where_float(r7, "modify_hp", "amount", -0.333) \
		and not _has_effect(r7, "set_alive")
	_report("7. hunger=0 hp=2 → -0.333hp, alive", ok7, r7)
	ok = ok and ok7

	var r8 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 0.2, "max_hp": 100.0,
		"stamina": 0.0, "max_stamina": 100.0,
		"hunger": 0.0, "max_hunger": 100.0, "has_hungry": true,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok8 := _has_effect_where_float(r8, "modify_hp", "amount", -0.2) \
		and _has_effect_where_bool(r8, "set_alive", "alive", false)
	_report("8. hunger=0 hp=0.2 → -0.2hp clamp + dead", ok8, r8)
	ok = ok and ok8

	# ── on_hunger_changed（吃饭路径）──────────────────────────────────

	var r9 := ScriptExecutor.call_hook(state, "on_hunger_changed", {
		"character": fake_target, "hunger": 80.0, "has_hungry": true,
	})
	var ok9 := _has_effect_where(r9, "remove_condition", "condition_id", "hungry") \
		and not _has_effect(r9, "modify_hp")
	_report("9. on_hunger_changed hunger=80 → -hungry only", ok9, r9)
	ok = ok and ok9

	var r10 := ScriptExecutor.call_hook(state, "on_hunger_changed", {
		"character": fake_target, "hunger": 55.0, "has_hungry": true,
	})
	var ok10: bool = (r10.get("raw_effects", []) as Array).size() == 0
	_report("10. on_hunger_changed hunger=55 still hungry → no-op", ok10, r10)
	ok = ok and ok10

	var r11 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 100.0, "max_hp": 100.0,
		"stamina": 50.0, "max_stamina": 100.0,
		"hunger": 80.0, "max_hunger": 100.0, "has_hungry": false,
		"rest": 50.0, "max_rest": 100.0, "is_sleeping": false,
	})
	var ok11 := _has_effect_where_float(r11, "modify_hunger", "amount", -2.083) \
		and _has_effect_where_float(r11, "modify_rest", "amount", -0.333) \
		and _has_effect_where_float(r11, "modify_stamina", "amount", -0.333)
	_report("11. awake rest=50 stamina=50 → hunger/rest/stamina cap", ok11, r11)
	ok = ok and ok11

	var r12 := ScriptExecutor.call_hook(state, "on_slow_tick", {
		"character": fake_target, "hp": 100.0, "max_hp": 100.0,
		"stamina": 20.0, "max_stamina": 100.0,
		"hunger": 100.0, "max_hunger": 100.0, "has_hungry": false,
		"rest": 100.0, "max_rest": 100.0, "is_sleeping": true,
	})
	var ok12 := _has_effect_where_float(r12, "modify_hunger", "amount", -2.083) \
		and _has_effect_where_float(r12, "modify_stamina", "amount", 5.0)
	_report("12. physiology tick full state → +5 stamina", ok12, r12)
	ok = ok and ok12

	fake_target.queue_free()
	return ok


func _report(label: String, passed: bool, result: Dictionary) -> void:
	var status := "OK  " if passed else "FAIL"
	print("[smoke] %s  %s  effects=%s" % [status, label, _summarize(result)])


func _summarize(result: Dictionary) -> Array:
	var out: Array = []
	for e in result.get("raw_effects", []):
		var t := str(e.get("type", "?"))
		match t:
			"add_condition":
				out.append("+%s" % str(e.get("condition_id", "?")))
			"remove_condition":
				out.append("-%s" % str(e.get("condition_id", "?")))
			"modify_hp":
				out.append("hp%+.1f" % float(e.get("amount", 0.0)))
			"modify_hunger":
				out.append("hunger%+.1f" % float(e.get("amount", 0.0)))
			"modify_rest":
				out.append("rest%+.1f" % float(e.get("amount", 0.0)))
			"modify_stamina":
				out.append("stamina%+.1f" % float(e.get("amount", 0.0)))
			"set_alive":
				out.append("alive=%s" % str(e.get("alive", "?")))
			_:
				out.append(t)
	return out


func _has_effect(result: Dictionary, type: String) -> bool:
	for e in result.get("raw_effects", []):
		if str(e.get("type", "")) == type:
			return true
	return false


func _effect_float_sum(result: Dictionary, type: String, key: String) -> float:
	var total := 0.0
	for e in result.get("raw_effects", []):
		if str(e.get("type", "")) == type:
			total += float(e.get(key, 0.0))
	return total


func _has_effect_where(result: Dictionary, type: String, key: String, value: String) -> bool:
	for e in result.get("raw_effects", []):
		if str(e.get("type", "")) == type and str(e.get(key, "")) == value:
			return true
	return false


func _has_effect_where_float(result: Dictionary, type: String, key: String, value: float) -> bool:
	for e in result.get("raw_effects", []):
		if str(e.get("type", "")) == type and absf(float(e.get(key, 0.0)) - value) < 0.01:
			return true
	return false


func _has_effect_where_bool(result: Dictionary, type: String, key: String, value: bool) -> bool:
	for e in result.get("raw_effects", []):
		if str(e.get("type", "")) == type and bool(e.get(key, not value)) == value:
			return true
	return false
