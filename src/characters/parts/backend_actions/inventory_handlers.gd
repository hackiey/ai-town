class_name InventoryHandlers
extends RefCounted

# use / drop / pick_up 三个 inventory verb 的无状态 handler。
# 签名统一 (character, action_request[, completion]) → Dictionary：
#   - use_item 可能 deferred（duration>0 走 character.use_item_controller pending），需要 completion；
#   - drop / pick_up 同步即返回，无 completion。

# 拾取半径不另设常量：逐个地面物品读它自己 SiteMarker 的可交互半径（与玩家同源，不分叉）。


# use_item：先校验 itemId + target（暂只允许 self）→ 找背包槽 → 委托给 UseItemController。
# 返回 {ok, pending?} 走 dispatcher pending 协议。pending 时 controller 内部存 completion，
# deadline 到时通过它 fire 回 runner.finish。
static func run_use_item(character: Character, action_request: Dictionary, completion: Callable) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "use_item target must be object"}
	var t: Dictionary = target as Dictionary
	var item_id := str(t.get("itemId", "")).strip_edges()
	if item_id.is_empty():
		return {"ok": false, "message": "use_item 缺少 itemId"}
	var item: Item = Items.by_id(item_id)
	if item == null:
		return {"ok": false, "message": "未知物品：%s" % item_id}

	var actor_id := character.backend_character_id()
	var target_id := str(t.get("targetId", "")).strip_edges()
	if target_id in ["self", "me", "自己"]:
		target_id = actor_id
	if not target_id.is_empty() and target_id != actor_id:
		return {"ok": false, "message": "物品暂时只能自己使用"}

	var slot_index := character.first_inventory_slot_for_item(item_id)
	if slot_index < 0:
		return {"ok": false, "message": "背包里没有%s" % character.localize_item_name(item_id)}
	return character.use_item_controller().start(action_request, slot_index, item.kind == "food", completion)


# drop_item / pick_up：地面物品。target wire 同 actions.ts ItemTarget：{itemId, slotIndex?, quantity?}。
# slotIndex 在 drop 用来定位多 stack 同物品里 LLM 真正想丢的那一格；pick_up_item 忽略。


static func run_drop_item(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "drop_item target must be object"}
	var t: Dictionary = target as Dictionary
	var item_id := str(t.get("itemId", "")).strip_edges()
	if item_id.is_empty():
		return {"ok": false, "message": "drop_item 缺少 itemId"}
	var slot_index := int(t.get("slotIndex", -1))
	if slot_index < 0:
		slot_index = character.first_inventory_slot_for_item(item_id)
	if slot_index < 0 or slot_index >= character.inventory.size():
		return {"ok": false, "message": "背包里没有%s" % character.localize_item_name(item_id)}
	var slot: Dictionary = character.inventory[slot_index]
	if str(slot.get("item_id", "")) != item_id:
		return {"ok": false, "message": "槽位 %d 不是%s" % [slot_index, character.localize_item_name(item_id)]}
	var want_qty := int(t.get("quantity", int(slot.get("quantity", 0))))
	if want_qty <= 0:
		want_qty = int(slot.get("quantity", 0))
	# 先快照（保 quality / freshness / durability / displayed_effects），再 remove，
	# 用 snapshot.quantity = taken 副本喂 spawner。
	var snapshot: Dictionary = slot.duplicate(true)
	var taken := character.inventory_ops().remove_item(slot_index, want_qty)
	if taken <= 0:
		return {"ok": false, "message": "无法丢弃 %s" % character.localize_item_name(item_id)}
	snapshot["quantity"] = taken
	GroundItemSpawner.spawn_for_character(character, snapshot)
	# wire contract: DropItemEventData = {itemId, quantity}。affectedCharacterIds 走 voice_far
	# 让附近人也能看到"X 丢下了 Y"（player.gd 路径只填 [actor] 是因为 player 丢东西不强求广播，
	# NPC 这里走 far 让旁观者能感知到 ground item 出现）。
	character.emit_world_event("drop_item", {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"itemId": item_id,
		"quantity": taken,
	})
	return {"ok": true, "result": {"itemId": item_id, "quantity": taken}}


static func run_pick_up_item(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "pick_up_item target must be object"}
	var t: Dictionary = target as Dictionary
	var item_id := str(t.get("itemId", "")).strip_edges()
	if item_id.is_empty():
		return {"ok": false, "message": "pick_up_item 缺少 itemId"}
	# 找各自拾取半径内、离我最近的同 item_id GroundItem（半径逐物品读其 SiteMarker）。
	var nearest: GroundItem = null
	var best_dist := INF
	var char_pos: Vector3 = character.global_position
	for n in character.get_tree().get_nodes_in_group("ground_items"):
		if not (n is GroundItem):
			continue
		var gi: GroundItem = n
		if gi.item_id != item_id:
			continue
		var d := char_pos.distance_to(gi.global_position)
		if d <= SiteMarker.interaction_radius_of(gi) and d < best_dist:
			best_dist = d
			nearest = gi
	if nearest == null:
		return {"ok": false, "message": "附近没有 %s" % character.localize_item_name(item_id)}
	# 全有全无：用 receive_inventory_stacks 原子加，装不下时它会自己 rollback。
	var qty := nearest.quantity()
	var stack: Dictionary = nearest.slot_data.duplicate(true)
	stack["quantity"] = qty
	var stacks: Array[Dictionary] = [stack]
	var recv := character.inventory_ops().receive_stacks(stacks)
	if not bool(recv.get("ok", false)):
		return {"ok": false, "message": str(recv.get("message", "背包装不下"))}
	Db.delete_ground_item(nearest.db_id)
	nearest.queue_free()
	return {"ok": true, "result": {"itemId": item_id, "quantity": qty}}
