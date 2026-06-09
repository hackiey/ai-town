class_name ItemUse
extends RefCounted

# Shared item-use rules. Player UI can run these with a duration/progress bar;
# backend actions can execute the same script path without duplicating validation.

# 吃腐烂/馊掉的食物会生病：固定追加这么多 sickness（与新鲜度乘子无关）。
const ROTTEN_SICKNESS := 35.0


static func resolve(view: InventorySlotData, food_only: bool = false) -> Dictionary:
	if view.is_empty():
		return {"ok": false, "message": _msg("error.item_use.empty_slot")}
	var item := view.template()
	if item == null:
		return {"ok": false, "message": _fmt("error.item.unknown_format", [view.id()])}
	if food_only and item.kind != "food":
		return {"ok": false, "message": _fmt("error.item_use.not_food_format", [view.id(), item.kind])}
	var perishable := view.as_perishable()
	var spoiled := view.has_tag("spoiled") or (perishable != null and perishable.is_rotten())
	# 腐烂的可入口物（食物/饮料/腐食残渣）允许硬着头皮吃下去——但会生病（execute 里加 sickness）。
	# 其它东西腐了仍不可用。
	if perishable != null and perishable.is_rotten() and not (item.kind in ["food", "drink", "trash"]):
		return {"ok": false, "message": _fmt("error.item_use.rotten_unusable_format", [item.display_name])}
	# "可使用"判定：有 base_effects 即可；腐烂可入口物即使没有效果数据也可吃（吃了会生病）。
	var effects_preview := ItemEffects.compute_displayed(view)
	if effects_preview.is_empty() and not spoiled:
		if item.kind == "food":
			return {"ok": false, "message": _fmt("error.item_use.food_no_effects_format", [view.id()])}
		return {"ok": false, "message": _fmt("error.item_use.unusable_format", [item.display_name])}
	return {
		"ok": true,
		"item": item,
		"item_id": view.id(),
		"action_name": action_name(item),
		"duration_seconds": duration_seconds(item),
	}


static func action_name(item: Item) -> String:
	if item == null:
		return _msg("tool.tool_result.use_item.action_default")
	if item.kind == "food":
		return _fmt("tool.tool_result.use_item.eat_action_format", [item.display_name])
	return _fmt("tool.tool_result.use_item.use_action_format", [item.display_name])


static func duration_seconds(item: Item) -> float:
	if item == null:
		return 0.0
	return maxf(0.0, item.use_duration_seconds)


static func execute(character: Character, view: InventorySlotData, resolved: Dictionary) -> Dictionary:
	var item := resolved.get("item") as Item
	if item == null:
		return {"ok": false, "error": "use_item: item is null"}
	# 走 ItemEffects.compute_displayed(view) 取效果 dict（lua compute_effects 或默认公式），
	# 然后通过 ItemEffects.apply_to_caster 走统一 Effects.apply 路径。
	# lua 不再直接 affect.X side-effect；见 memory feedback_effects_lua_returns_dict。
	var effects := ItemEffects.compute_displayed(view)
	# 吃腐烂/馊食 → 生病：追加固定 sickness（tag spoiled 如 rotten_food，或 perishable 已腐的食物）。
	var perish := view.as_perishable()
	if view.has_tag("spoiled") or (perish != null and perish.is_rotten()):
		effects = effects.duplicate()
		effects["disease.stomach_illness"] = float(effects.get("disease.stomach_illness", 0.0)) + ROTTEN_SICKNESS
	if effects.is_empty():
		return {"ok": true, "effects": [], "applied": {}}
	var medicine := _extract_medicine_effect(character, view, effects)
	var immediate_v: Variant = medicine.get("immediate", {})
	effects = immediate_v as Dictionary if immediate_v is Dictionary else {}
	var summaries := ItemEffects.apply_to_caster(character, effects)
	var symptom_deltas_v: Variant = medicine.get("symptom_deltas", {})
	var symptom_deltas: Dictionary = symptom_deltas_v if symptom_deltas_v is Dictionary else {}
	if not symptom_deltas.is_empty():
		var applied := character.set_medicine_effect(str(medicine.get("source_id", view.id())), symptom_deltas)
		summaries.append({
			"ok": true,
			"summary": "%s medicine_effect %s %d symptoms/4h" % [character.name, "refreshed" if applied else "not_applied", symptom_deltas.size()],
		})
	var applied_effects := effects.duplicate()
	if not symptom_deltas.is_empty():
		applied_effects["medicine_effect"] = symptom_deltas
	return {"ok": true, "effects": summaries, "applied": applied_effects}


static func _extract_medicine_effect(character: Character, view: InventorySlotData, effects: Dictionary) -> Dictionary:
	if not view.has_tag("medicine"):
		return {"immediate": effects, "symptom_deltas": {}, "source_id": view.id()}
	var immediate := {}
	var symptom_deltas := {}
	for k in effects.keys():
		var key := str(k)
		var amount := float(effects[k])
		if key.begins_with("symptom."):
			var symptom_id := key.substr("symptom.".length())
			symptom_deltas[symptom_id] = float(symptom_deltas.get(symptom_id, 0.0)) + amount
			continue
		immediate[key] = amount
	return {
		"immediate": immediate,
		"symptom_deltas": symptom_deltas,
		"source_id": view.id(),
	}


static func completion_message(item: Item, character: Character) -> String:
	if item != null and item.kind == "food":
		return _fmt("tool.tool_result.use_item.eat_completed_format", [item.display_name, character.hunger, character.stamina])
	if item != null:
		return _fmt("tool.tool_result.use_item.use_completed_format", [item.display_name])
	return _msg("tool.tool_result.use_item.completed_default")


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


static func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
