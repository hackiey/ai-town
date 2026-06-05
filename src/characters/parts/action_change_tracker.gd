class_name ActionChangeTracker
extends RefCounted

# Backend action 完成时附带的 character_changes 快照/diff 辅助。
# 用法：
#   var before := ActionChangeTracker.capture(character)
#   ...动作执行...
#   var after := ActionChangeTracker.capture(character)
#   var changes := ActionChangeTracker.build(before, after)
# 纯函数，无状态。由 BackendActionRunner.finish() 调用。


static func capture(character: Character) -> Dictionary:
	if character == null:
		return {}
	return {
		"attributes": {
			"hp": roundf(character.hp),
			"stamina": roundf(character.stamina),
			"hunger": roundf(character.hunger),
			"rest": roundf(character.rest),
			"temperature": snappedf(character.temperature, 0.1),
			"alive": bool(character.alive),
			"burning": bool(character.burning),
		},
		"backpack": _capture_backpack(character),
		"wallet_centi": int(character.wallet_centi),
	}


static func build(before: Dictionary, after: Dictionary) -> Dictionary:
	if before.is_empty() or after.is_empty():
		return {}
	var changes: Dictionary = {}
	var attributes := _attribute_changes(before.get("attributes", {}), after.get("attributes", {}))
	if not attributes.is_empty():
		changes["attributes"] = attributes
	var backpack := _backpack_changes(before.get("backpack", {}), after.get("backpack", {}))
	# 钱包不在 inventory 里（wallet_centi 单独存），交易/买卖的银币进出必须单独 diff，
	# 否则 character_changes 只剩物品那半，渲染出"获得 木炭"却没有"失去 银币"。
	# 以 silver_coin 入项并入 backpack 段，复用 backend quantity 渲染（delta 走 silver 浮点）。
	_append_wallet_change(backpack, before.get("wallet_centi", 0), after.get("wallet_centi", 0))
	if not backpack.is_empty():
		changes["backpack"] = backpack
	return changes


static func _append_wallet_change(out: Array[Dictionary], before_v: Variant, after_v: Variant) -> void:
	var before_centi := int(before_v)
	var after_centi := int(after_v)
	if before_centi == after_centi:
		return
	out.append({
		"kind": "quantity",
		"item_id": "silver_coin",
		"display_name": "",
		"before": before_centi / 100.0,
		"after": after_centi / 100.0,
		"delta": (after_centi - before_centi) / 100.0,
	})


static func _capture_backpack(character: Character) -> Dictionary:
	var totals: Dictionary = {}
	var slots: Array[Dictionary] = []
	for i in character.inventory.size():
		var slot: Dictionary = character.inventory[i]
		var view := InventorySlotData.of(slot)
		var summary := _slot_change_summary(i, view)
		slots.append(summary)
		if view.is_empty():
			continue
		var key := _slot_quantity_key(view)
		var existing: Dictionary = totals.get(key, {
			"item_id": view.id(),
			"display_name": view.display_name(),
			"quality": view.quality(),
			"quantity": 0,
		})
		existing["quantity"] = int(existing.get("quantity", 0)) + view.quantity()
		totals[key] = existing
	return {"totals": totals, "slots": slots}


static func _slot_change_summary(index: int, view: InventorySlotData) -> Dictionary:
	if view.is_empty():
		return {"slot_index": index, "empty": true}
	var tmpl: Item = view.template()
	var max_dur := int(tmpl.properties.get("max_durability", 0)) if tmpl != null else 0
	# durability=-1 表示此物不计耐久（max=0）。否则取 typed durability 列或回退 max。
	var dura_v: Variant = view.durability()
	var durability := -1
	if max_dur > 0:
		durability = max_dur if dura_v == null else int(dura_v)
	var container := view.as_container()
	# container_amount / container_content 用 typed 列；只有 container 类才有意义。
	# diff 用 "amount/content" 作 stable key，对比 "amount 涨了 / content 变了" 由 backend 渲染。
	var container_state := ""
	if container != null:
		container_state = "%s/%s" % [container.amount(), container.content_id()]
	return {
		"slot_index": index,
		"empty": false,
		"item_id": view.id(),
		"display_name": view.display_name(),
		"quantity": view.quantity(),
		"quality": view.quality(),
		"durability": durability,
		"max_durability": max_dur,
		"container_state": container_state,
	}


static func _slot_quantity_key(view: InventorySlotData) -> String:
	return "%s|q%d|%s" % [view.id(), view.quality(), view.display_name()]


static func _attribute_changes(before_v: Variant, after_v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(before_v) != TYPE_DICTIONARY or typeof(after_v) != TYPE_DICTIONARY:
		return out
	var before: Dictionary = before_v
	var after: Dictionary = after_v
	for key in ["hp", "stamina", "hunger", "rest", "temperature", "burning"]:
		var old: Variant = before.get(key)
		var now: Variant = after.get(key)
		if old == now:
			continue
		out.append({
			"field": key,
			"before": old,
			"after": now,
		})
	return out


static func _backpack_changes(before_v: Variant, after_v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(before_v) != TYPE_DICTIONARY or typeof(after_v) != TYPE_DICTIONARY:
		return out
	var before: Dictionary = before_v
	var after: Dictionary = after_v
	_append_quantity_changes(out, before.get("totals", {}), after.get("totals", {}))
	_append_slot_state_changes(out, before.get("slots", []), after.get("slots", []))
	return out


static func _append_quantity_changes(out: Array[Dictionary], before_v: Variant, after_v: Variant) -> void:
	if typeof(before_v) != TYPE_DICTIONARY or typeof(after_v) != TYPE_DICTIONARY:
		return
	var before: Dictionary = before_v
	var after: Dictionary = after_v
	var keys: Dictionary = {}
	for key in before.keys():
		keys[key] = true
	for key in after.keys():
		keys[key] = true
	for key in keys.keys():
		var old_entry: Dictionary = before.get(key, {})
		var new_entry: Dictionary = after.get(key, {})
		var old_qty := int(old_entry.get("quantity", 0))
		var new_qty := int(new_entry.get("quantity", 0))
		if old_qty == new_qty:
			continue
		var source: Dictionary = new_entry if not new_entry.is_empty() else old_entry
		out.append({
			"kind": "quantity",
			"item_id": str(source.get("item_id", "")),
			"display_name": str(source.get("display_name", "")),
			"quality": int(source.get("quality", 0)),
			"before": old_qty,
			"after": new_qty,
			"delta": new_qty - old_qty,
		})


static func _append_slot_state_changes(out: Array[Dictionary], before_v: Variant, after_v: Variant) -> void:
	if typeof(before_v) != TYPE_ARRAY or typeof(after_v) != TYPE_ARRAY:
		return
	var before: Array = before_v
	var after: Array = after_v
	var count: int = mini(before.size(), after.size())
	for i in count:
		var old: Dictionary = before[i]
		var now: Dictionary = after[i]
		if bool(old.get("empty", true)) or bool(now.get("empty", true)):
			continue
		if str(old.get("item_id", "")) != str(now.get("item_id", "")):
			continue
		if int(old.get("durability", -1)) >= 0 and int(now.get("durability", -1)) >= 0 and int(old.get("durability", -1)) != int(now.get("durability", -1)):
			out.append({
				"kind": "durability",
				"item_id": str(now.get("item_id", "")),
				"display_name": str(now.get("display_name", "")),
				"before": int(old.get("durability", 0)),
				"after": int(now.get("durability", 0)),
				"max": int(now.get("max_durability", 0)),
			})
		var old_container := str(old.get("container_state", ""))
		var new_container := str(now.get("container_state", ""))
		if not old_container.is_empty() and old_container != new_container:
			out.append({
				"kind": "container",
				"item_id": str(now.get("item_id", "")),
				"display_name": str(now.get("display_name", "")),
				"before": old_container,
				"after": new_container,
			})
