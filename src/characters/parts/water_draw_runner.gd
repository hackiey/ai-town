extends RefCounted

# Draw-water action runner. This owns the durative lifecycle for well → liquid
# container transfers; LiquidOps remains the instantaneous liquid primitive.

const _FALLBACK_SECONDS_PER_LITER := 9.0
const _FALLBACK_STAMINA_PER_LITER := 0.15

var character = null
var _active: Dictionary = {}
var _completion: Callable = Callable()


func _init(owner) -> void:
	character = owner


func is_active() -> bool:
	return not _active.is_empty()


func amount_liters_for_action(action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": _msg("error.container_transfer.invalid_target")}
	var transfers_v: Variant = (target as Dictionary).get("transfers", [])
	if typeof(transfers_v) != TYPE_ARRAY or (transfers_v as Array).is_empty():
		return {"ok": false, "message": _msg("error.container_transfer.empty_transfers")}
	var total_liters: float = 0.0
	var transfers: Array = transfers_v as Array
	for tr_v in transfers:
		if typeof(tr_v) != TYPE_DICTIONARY:
			continue
		var tr := tr_v as Dictionary
		if str(tr.get("kind", "item")) != "liquid":
			continue
		var from_raw: Dictionary = tr.get("from", {}) if typeof(tr.get("from", {})) == TYPE_DICTIONARY else {}
		if str(from_raw.get("where", "")) != "well":
			continue
		var amount: float = float(tr.get("amount", 0.0))
		if amount <= 0.0:
			amount = 1.0
		total_liters += amount
	return {"ok": true, "amount_liters": total_liters}


func start_from_container_transfer(action_request: Dictionary, completion: Callable) -> Dictionary:
	if is_active():
		return {"ok": false, "message": _msg("error.water_draw.busy")}
	var amount_res: Dictionary = amount_liters_for_action(action_request)
	if not bool(amount_res.get("ok", false)):
		return amount_res
	var amount_liters: float = float(amount_res.get("amount_liters", 0.0))
	if amount_liters <= 0.0:
		return {"ok": false, "message": _msg("error.water_draw.amount_positive")}
	var precheck: Dictionary = _precheck_container_transfer(action_request)
	if not bool(precheck.get("ok", false)):
		return precheck
	var cost: Dictionary = resolve_draw_cost(amount_liters)
	var duration: float = float(cost.get("duration_seconds", 0.0))
	_active = {
		"action_request": action_request.duplicate(true),
		"amount_liters": amount_liters,
		"duration_seconds": duration,
		"started_at_game_seconds": GameClock.game_seconds,
		"deadline_game_seconds": GameClock.game_seconds + duration,
	}
	_completion = completion
	character.set("anim_state", "working")
	character.head_status().push_override(str(TranslationServer.translate("ui.water_draw.action_label")))
	_report_progress()
	if duration <= 0.0:
		_commit_active()
	return {"ok": true, "pending": true, "duration_seconds": duration, "amount_liters": amount_liters}


func tick(_delta: float) -> void:
	if _active.is_empty():
		return
	var deadline: float = float(_active.get("deadline_game_seconds", 0.0))
	if GameClock.game_seconds >= deadline:
		_commit_active()


func cancel(reason: String = "cancelled") -> Dictionary:
	if _active.is_empty():
		return {}
	var active: Dictionary = _active.duplicate(true)
	_active = {}
	_completion = Callable()
	character.head_status().clear_override()
	character.set("anim_state", "idle")
	character.perception().send_manifest()
	return {
		"actionCompleted": false,
		"cancelled": true,
		"reason": reason,
		"amount_liters": float(active.get("amount_liters", 0.0)),
	}


func preempt() -> void:
	if _active.is_empty():
		return
	_active = {}
	_completion = Callable()
	character.head_status().clear_override()
	character.set("anim_state", "idle")


func resolve_draw_cost(amount_liters: float) -> Dictionary:
	var amount: float = maxf(0.0, amount_liters)
	var inv: Dictionary = MechanicHost.invoke("well", "on_draw_cost", {"amount_liters": amount})
	if bool(inv.get("ok", false)):
		var rv: Variant = inv.get("return_value")
		if rv is Dictionary:
			var d: Dictionary = rv as Dictionary
			return {
				"duration_seconds": maxf(0.0, float(d.get("duration_seconds", 0.0))),
				"stamina_cost": maxf(0.0, float(d.get("stamina_cost", 0.0))),
			}
	push_warning("[WaterDrawRunner] well.on_draw_cost failed; using fallback: %s" % str(inv.get("error", "")))
	return {
		"duration_seconds": amount * _FALLBACK_SECONDS_PER_LITER,
		"stamina_cost": amount * _FALLBACK_STAMINA_PER_LITER,
	}


func draw_into_slot_now(dst_slot: Dictionary, source_node, amount_liters: float) -> Dictionary:
	var requested: float = maxf(0.0, amount_liters)
	var precheck: Dictionary = can_draw_into_slot(dst_slot, source_node, requested)
	if not bool(precheck.get("ok", false)):
		return precheck
	var cost: Dictionary = resolve_draw_cost(requested)
	var spend: Dictionary = StaminaWallet.try_spend(character, float(cost.get("stamina_cost", 0.0)), "well:draw")
	if not bool(spend.get("ok", false)):
		spend["code"] = "stamina_depleted"
		return spend
	var content: String = String(source_node.infinite_content)
	var mult: float = Impairment.well_mult(Impairment.work_impair(character))
	var effective: float = requested * mult
	var result: Dictionary = LiquidOps.fill_from_source(dst_slot, content, float(source_node.infinite_quality), effective)
	if not bool(result.get("ok", false)):
		return result
	result["requested_liters"] = requested
	result["effective_liters"] = effective
	result["well_mult"] = mult
	result["duration_seconds"] = float(cost.get("duration_seconds", 0.0))
	result["stamina_cost"] = float(spend.get("stamina_cost", 0.0))
	result["stamina_before"] = float(spend.get("stamina_before", character.stamina))
	result["stamina_after"] = float(spend.get("stamina_after", character.stamina))
	return result


func can_draw_into_slot(dst_slot: Dictionary, source_node, amount_liters: float) -> Dictionary:
	var requested: float = maxf(0.0, amount_liters)
	if requested <= 0.0:
		return {"ok": false, "message": _msg("error.water_draw.amount_positive")}
	if source_node == null or not is_instance_valid(source_node) or not source_node.is_infinite_source():
		return {"ok": false, "message": _msg("error.water_draw.invalid_source")}
	var content: String = String(source_node.infinite_content)
	if content != "water":
		return {"ok": false, "message": _msg("error.water_draw.not_water_source")}
	var dst := InventorySlotData.of(dst_slot).as_container()
	if dst == null:
		return {"ok": false, "message": _msg("error.water_draw.not_liquid_container")}
	if not dst.is_empty() and dst.content_id() != content:
		return {"ok": false, "message": _msg("error.water_draw.incompatible_content")}
	if dst.capacity() - dst.amount() <= 0.0:
		return {"ok": false, "message": _msg("error.water_draw.container_full")}
	return {"ok": true}


func _commit_active() -> void:
	if _active.is_empty():
		return
	var active: Dictionary = _active.duplicate(true)
	_active = {}
	character.head_status().clear_override()
	character.set("anim_state", "idle")
	var action_request: Dictionary = active.get("action_request", {})
	var structured: Dictionary = ContainerHandlers.run_container_transfer_now(character, action_request)
	var completion: Callable = _completion
	_completion = Callable()
	if not bool(structured.get("ok", false)):
		if completion.is_valid():
			completion.call(false, str(structured.get("message", _msg("error.water_draw.failed"))), {})
		return
	var result_v: Variant = structured.get("result", {})
	var result: Dictionary = result_v as Dictionary if typeof(result_v) == TYPE_DICTIONARY else {}
	result["duration_seconds"] = float(active.get("duration_seconds", 0.0))
	result["amount_liters"] = float(active.get("amount_liters", 0.0))
	character.perception().send_manifest()
	if completion.is_valid():
		completion.call(true, "", result)


func _precheck_container_transfer(action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": _msg("error.container_transfer.invalid_target")}
	var transfers_v: Variant = (target as Dictionary).get("transfers", [])
	if typeof(transfers_v) != TYPE_ARRAY:
		return {"ok": false, "message": _msg("error.container_transfer.empty_transfers")}
	var transfers: Array = transfers_v as Array
	for tr_v in transfers:
		if typeof(tr_v) != TYPE_DICTIONARY:
			continue
		var tr := tr_v as Dictionary
		if str(tr.get("kind", "item")) != "liquid":
			continue
		var from_raw: Dictionary = tr.get("from", {}) if typeof(tr.get("from", {})) == TYPE_DICTIONARY else {}
		if str(from_raw.get("where", "")) != "well":
			continue
		var to_ep: Dictionary = ContainerHandlers._resolve_liquid_endpoint(character, tr.get("to", {}))
		if not bool(to_ep.get("ok", false)):
			return {"ok": false, "message": str(to_ep.get("message", _msg("error.water_draw.invalid_slot")))}
		var well: Dictionary = ContainerHandlers._resolve_well(character, from_raw)
		if not bool(well.get("ok", false)):
			return {"ok": false, "message": str(well.get("message", _msg("error.water_draw.invalid_source")))}
		var amount: float = float(tr.get("amount", 0.0))
		if amount <= 0.0:
			amount = 1.0
		var pre: Dictionary = can_draw_into_slot(to_ep["slot"], well["node"], amount)
		if not bool(pre.get("ok", false)):
			return pre
	return {"ok": true}


func _report_progress() -> void:
	if _active.is_empty():
		return
	if character == null or not character.has_method("_on_backend_action_progress"):
		return
	var deadline: float = float(_active.get("deadline_game_seconds", GameClock.game_seconds))
	character.call("_on_backend_action_progress", {
		"actionCompleted": false,
		"inProgress": true,
		"kind": "water_draw",
		"duration": float(_active.get("duration_seconds", 0.0)),
		"amount_liters": float(_active.get("amount_liters", 0.0)),
		"remaining_game_seconds": maxf(0.0, deadline - GameClock.game_seconds),
		"label": str(TranslationServer.translate("ui.water_draw.action_label")),
	})


func _msg(key: String) -> String:
	var translated: String = str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key
