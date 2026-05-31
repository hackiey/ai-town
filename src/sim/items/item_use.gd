class_name ItemUse
extends RefCounted

# Shared item-use rules. Player UI can run these with a duration/progress bar;
# backend actions can execute the same script path without duplicating validation.

static func resolve(view: InventorySlotData, food_only: bool = false) -> Dictionary:
	if view.is_empty():
		return {"ok": false, "message": "物品槽位为空"}
	var item := view.template()
	if item == null:
		return {"ok": false, "message": "未知物品：%s" % view.id()}
	if food_only and item.kind != "food":
		return {"ok": false, "message": "/eat %s 不是食物（kind=%s）" % [view.id(), item.kind]}
	var perishable := view.as_perishable()
	if perishable != null and perishable.is_rotten():
		var rotten_message := "%s 已经腐烂，不能使用"
		if item.kind == "food":
			rotten_message = "%s 已经腐烂，吃了会生病"
		return {"ok": false, "message": rotten_message % item.display_name}
	# "可使用"判定：有 base_effects（无论 slot 上还是 template 上）即可。lua source
	# 可选（特殊条件物品才写 compute_effects）。
	var effects_preview := ItemEffects.compute_displayed(view)
	if effects_preview.is_empty():
		if item.kind == "food":
			return {"ok": false, "message": "/eat %s 没有效果数据（base_effects 空）" % view.id()}
		return {"ok": false, "message": "%s 无法直接使用" % item.display_name}
	return {
		"ok": true,
		"item": item,
		"item_id": view.id(),
		"action_name": action_name(item),
		"duration_seconds": duration_seconds(item),
	}


static func action_name(item: Item) -> String:
	if item == null:
		return "使用物品"
	if item.kind == "food":
		return "吃%s" % item.display_name
	return "使用%s" % item.display_name


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
	if effects.is_empty():
		return {"ok": true, "effects": [], "applied": {}}
	var summaries := ItemEffects.apply_to_caster(character, effects)
	return {"ok": true, "effects": summaries, "applied": effects}


static func completion_message(item: Item, character: Character) -> String:
	if item != null and item.kind == "food":
		return "吃了 %s（饱食 %.0f / 体力 %.0f）" % [item.display_name, character.hunger, character.stamina]
	if item != null:
		return "使用了 %s" % item.display_name
	return "使用了物品"
