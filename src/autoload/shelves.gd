extends Node

const Money = preload("res://src/sim/characters/money.gd")
const INTERACTION_RADIUS := 3.0

var _shelves_by_id: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	if not RunMode.is_runtime():
		set_process(false)
		return
	call_deferred("_prune_orphan_shelf_storage")


func register_shelf(node: ShelfNode) -> void:
	if node == null:
		return
	var shelf_id := node.effective_shelf_id()
	if shelf_id.is_empty():
		push_warning("[Shelves] skipped shelf with empty shelf_id: %s" % node.name)
		return
	if _shelves_by_id.has(shelf_id) and _shelves_by_id[shelf_id] != node:
		push_warning("[Shelves] duplicate shelf_id '%s', replacing previous node" % shelf_id)
	_shelves_by_id[shelf_id] = node


func unregister_shelf(node: ShelfNode) -> void:
	if node == null:
		return
	var shelf_id := node.effective_shelf_id()
	if shelf_id.is_empty():
		return
	if _shelves_by_id.get(shelf_id) == node:
		_shelves_by_id.erase(shelf_id)


func find_shelf_node(shelf_id: String) -> ShelfNode:
	var wanted := shelf_id.strip_edges()
	if wanted.is_empty():
		return null
	var node: Variant = _shelves_by_id.get(wanted)
	if node is ShelfNode and is_instance_valid(node):
		return node as ShelfNode
	_shelves_by_id.erase(wanted)
	return null


func nearby_snapshots_for(character: Character, max_distance: float = INTERACTION_RADIUS) -> Array[Dictionary]:
	if character == null:
		return []
	var out: Array[Dictionary] = []
	var max_sq := max_distance * max_distance
	for node_v in _shelves_by_id.values():
		var node := node_v as ShelfNode
		if node == null or not is_instance_valid(node):
			continue
		if character.global_position.distance_squared_to(node.get_approach_node().global_position) > max_sq:
			continue
		out.append(_snapshot_for_shelf(node, character))
	_sort_snapshots(out)
	return out


func owned_snapshots_for(character: Character) -> Array[Dictionary]:
	if character == null:
		return []
	var out: Array[Dictionary] = []
	var character_id := character.backend_character_id()
	for node_v in _shelves_by_id.values():
		var node := node_v as ShelfNode
		if node == null or not is_instance_valid(node):
			continue
		if not node.is_managed_by(character_id):
			continue
		out.append(_snapshot_for_shelf(node, character))
	_sort_snapshots(out)
	return out


func _prune_orphan_shelf_storage() -> void:
	if Db == null or not Db.has_method("prune_shelf_storage"):
		return
	var valid_shelf_ids: Array[String] = []
	for shelf_id_v in _shelves_by_id.keys():
		var shelf_id := str(shelf_id_v).strip_edges()
		if not shelf_id.is_empty():
			valid_shelf_ids.append(shelf_id)
	Db.prune_shelf_storage(valid_shelf_ids)


# ─── InventoryAdapter API（read-only；写路径见 update_shelf / buy_from_shelf）───
# 把 shelf listings "投影" 成 slot dict 列表 —— 让 lua 端的 world.find_items 可以
# 像查 Character / Container 一样查货架陈列。每个 listing → 一个虚拟 slot：
#   slot_index = listing.slot_index
#   slot.item_id / quantity / quality / aspect 字段 沿用 listing.slot
#   slot._listing_price_centi / _listing_id / _listing_owner_character_id：view-only
#     overlay（下划线前缀强调不持久化；item_instances 表无这些列）。
# 价格用 centi（1 silver = 100 centi）整数存储；显示走 Money.format_silver_from_centi。

func adapter_listing_slots(node: ShelfNode) -> Array:
	if node == null:
		return []
	var shelf_id := node.effective_shelf_id()
	var listings := Db.list_shelf_listings(shelf_id)
	if listings.is_empty():
		return []
	var by_idx: Dictionary = {}
	var max_idx := -1
	for listing in listings:
		var idx := int(listing.get("slot_index", -1))
		if idx < 0:
			continue
		var slot: Dictionary = (listing.get("slot", {}) as Dictionary).duplicate(true)
		slot["_listing_price_centi"] = int(listing.get("price_centi", 0))
		slot["_listing_id"] = str(listing.get("listing_id", ""))
		slot["_listing_owner_character_id"] = str(listing.get("owner_character_id", ""))
		by_idx[idx] = slot
		if idx > max_idx:
			max_idx = idx
	var out: Array = []
	for i in (max_idx + 1):
		out.append(by_idx.get(i, InventorySlotData.empty()))
	return out


func update_shelf(seller: Character, shelf_id: String, ops: Array) -> Dictionary:
	var shelf := find_shelf_node(shelf_id)
	if shelf == null:
		return {"ok": false, "message": "未知货架：%s" % shelf_id}
	var seller_id := seller.backend_character_id()
	if not shelf.is_managed_by(seller_id):
		return {"ok": false, "message": "这不是你的货架"}
	if not _is_character_near_shelf(seller, shelf):
		return {"ok": false, "message": "你现在不在货架附近（需要 3 米内）"}
	if ops.is_empty():
		return {"ok": false, "message": "update_shelf 至少需要一个操作"}
	var changes: Array[String] = []
	for op_v in ops:
		if typeof(op_v) != TYPE_DICTIONARY:
			return {"ok": false, "message": "货架操作必须是对象"}
		var op: Dictionary = op_v as Dictionary
		var op_type := str(op.get("type", op.get("kind", op.get("op", "")))).strip_edges()
		match op_type:
			"add":
				var added := _apply_add_op(seller, shelf, op)
				if not bool(added.get("ok", false)):
					return added
				changes.append(str(added.get("message", "上架成功")))
			"update":
				var updated := _apply_update_item_op(seller, shelf, op)
				if not bool(updated.get("ok", false)):
					return updated
				changes.append(str(updated.get("message", "更新成功")))
			"remove":
				var removed := _apply_remove_item_op(seller, shelf, op)
				if not bool(removed.get("ok", false)):
					return removed
				changes.append(str(removed.get("message", "下架成功")))
			_:
				return {"ok": false, "message": "不支持的货架操作：%s" % op_type}
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend != null and backend.has_method("send_world_event"):
		# Wire contract: backend renders the human description from `changes`
		# (see backend/src/agent-shared/event-descriptions/shelf.ts). Do not
		# include prose here.
		backend.call("send_world_event", "shelf_updated", {
			"actorId": seller_id,
			"affectedCharacterIds": seller.perception().voice_affected_character_ids("far"),
			"shelfId": shelf.effective_shelf_id(),
			"locationId": shelf.effective_location_id(),
			"changes": changes,
		})
	refresh_contexts_for_shelf(shelf.effective_shelf_id(), [seller_id])
	return {
		"ok": true,
		"message": "; ".join(changes),
		"changes": changes,
	}


func buy_from_shelf(
	buyer: Character,
	shelf_id: String,
	listing_id: String,
	quantity: int,
	total_price_centi: int = -1,
	source_trade_id: String = "",
	emit_sale_event: bool = true
) -> Dictionary:
	var shelf := find_shelf_node(shelf_id)
	if shelf == null:
		return {"ok": false, "message": "未知货架：%s" % shelf_id}
	if not _is_character_near_shelf(buyer, shelf):
		return {"ok": false, "message": "你不在货架附近（需要 3 米内）"}
	var listing := Db.get_shelf_listing(listing_id)
	if listing.is_empty():
		return {"ok": false, "message": "未知货架物品：%s" % listing_id}
	if str(listing.get("shelf_id", "")) != shelf.effective_shelf_id():
		return {"ok": false, "message": "该货物不在指定货架上"}
	var seller_id := str(listing.get("owner_character_id", ""))
	var seller := _character_node_by_id(seller_id)
	if seller == null:
		return {"ok": false, "message": "卖家当前不在场景中"}
	var slot: Dictionary = (listing.get("slot", {}) as Dictionary).duplicate(true)
	var available := int(slot.get("quantity", 0))
	var wanted_qty := maxi(quantity, 1)
	if available < wanted_qty:
		return {"ok": false, "message": "货架库存不足（当前只有 %d）" % available}
	var agreed_centi := total_price_centi
	if agreed_centi < 0:
		agreed_centi = int(listing.get("price_centi", 0)) * wanted_qty
	if agreed_centi < 0:
		return {"ok": false, "message": "价格无效"}
	# Wallet 转账：买家扣 centi → 卖家加 centi。失败保护：先 spend，spend 成功后 add；
	# 货物入库失败回滚买家 wallet（卖家此时已加 centi → 退回去）。
	var payment := buyer.inventory_ops().pay_centi(agreed_centi)
	if not bool(payment.get("ok", false)):
		return payment
	seller.wallet_add(agreed_centi)
	var sold_stack := slot.duplicate(true)
	sold_stack["quantity"] = wanted_qty
	var sold_stacks: Array[Dictionary] = [sold_stack]
	var buyer_receive := buyer.inventory_ops().receive_stacks(sold_stacks)
	if not bool(buyer_receive.get("ok", false)):
		# 回滚转账
		var _seller_refund := seller.inventory_ops().pay_centi(agreed_centi)
		buyer.inventory_ops().refund_centi(agreed_centi)
		return {
			"ok": false,
			"message": str(buyer_receive.get("message", "你现在装不下这个货物")),
		}
	if wanted_qty >= available:
		Db.delete_shelf_listing(listing_id)
	else:
		slot["quantity"] = available - wanted_qty
		Db.save_shelf_listing(
			shelf.effective_shelf_id(),
			int(listing.get("slot_index", 0)),
			listing_id,
			seller_id,
			int(listing.get("price_centi", 0)),
			slot,
			shelf.effective_location_id()
		)
	if emit_sale_event:
		_emit_sale_event(
			shelf,
			seller_id,
			buyer.backend_character_id(),
			listing_id,
			sold_stack,
			wanted_qty,
			agreed_centi,
			source_trade_id,
			buyer.perception().voice_affected_character_ids("far")
		)
	refresh_contexts_for_shelf(shelf.effective_shelf_id(), [buyer.backend_character_id(), seller_id])
	return {
		"ok": true,
		"message": "买下了 %s x%d，支付 %s" % [
			InventorySlotData.of(sold_stack).display_name(),
			wanted_qty,
			Money.format_silver_from_centi(agreed_centi),
		],
		"listing_id": listing_id,
		"quantity": wanted_qty,
		"price_centi": agreed_centi,
		"seller_character_id": seller_id,
	}


func refresh_contexts_for_shelf(shelf_id: String, extra_character_ids: Array = []) -> void:
	var shelf := find_shelf_node(shelf_id)
	if shelf == null:
		return
	# 受影响者：调用方显式传入的 extra_character_ids（如成交买卖双方）+ 当前站在货架旁的人。
	# 货架归属已改 group，不再单独 notify 某个 owner——相关组员若在场会被下面的近邻扫描覆盖。
	var notify := {}
	for character_id_v in extra_character_ids:
		var character_id := str(character_id_v).strip_edges()
		if not character_id.is_empty():
			notify[character_id] = true
	for character in _all_characters():
		if character == null:
			continue
		if _is_character_near_shelf(character, shelf):
			notify[character.backend_character_id()] = true
	for character_id in notify.keys():
		var node := _character_node_by_id(str(character_id))
		if node != null and node.has_method("send_perception_manifest"):
			node.call_deferred("send_perception_manifest")


func _apply_add_op(seller: Character, shelf: ShelfNode, op: Dictionary) -> Dictionary:
	var item_name := str(op.get("item", op.get("item_name", ""))).strip_edges()
	var quantity := int(op.get("quantity", 0))
	var price_centi := int(op.get("price_centi", op.get("priceCenti", -1)))
	if item_name.is_empty():
		return {"ok": false, "message": "add 操作缺少 item"}
	if quantity <= 0:
		return {"ok": false, "message": "add.quantity 必须大于 0"}
	if price_centi < 0:
		return {"ok": false, "message": "add.price_centi 必须是非负 centi 整数（1 银 = 100 centi）"}
	var extracted := _extract_named_item_across_inventory(seller, item_name, quantity)
	if not bool(extracted.get("ok", false)):
		return extracted
	var stacks := _as_dict_array(extracted.get("stacks", []))
	var stored := _store_stacks_on_shelf(seller, shelf, stacks, price_centi)
	if not bool(stored.get("ok", false)):
		seller.inventory_ops().restore_extracted_stacks(stacks)
		return stored
	var repriced := _reprice_matching_item_listings(seller, shelf, item_name, price_centi)
	if not bool(repriced.get("ok", false)):
		return repriced
	return {
		"ok": true,
		"message": "已新增 %s x%d 到货架，定价 %s" % [
			_display_name_for_item(item_name, stacks),
			quantity,
			Money.format_silver_from_centi(price_centi),
		],
	}


func _apply_update_item_op(seller: Character, shelf: ShelfNode, op: Dictionary) -> Dictionary:
	var item_name := str(op.get("item", op.get("item_name", ""))).strip_edges()
	var target_quantity := int(op.get("quantity", 0))
	var price_centi := int(op.get("price_centi", op.get("priceCenti", -1)))
	if item_name.is_empty():
		return {"ok": false, "message": "update 操作缺少 item"}
	if target_quantity <= 0:
		return {"ok": false, "message": "update.quantity 必须大于 0"}
	if price_centi < 0:
		return {"ok": false, "message": "update.price_centi 必须是非负 centi 整数（1 银 = 100 centi）"}
	var seller_id := seller.backend_character_id()
	var before_listings := _matching_shelf_listings(shelf, seller_id, item_name)
	var current_total := _total_listing_quantity(before_listings)
	if current_total < target_quantity:
		var extracted := _extract_named_item_across_inventory(seller, item_name, target_quantity - current_total)
		if not bool(extracted.get("ok", false)):
			return extracted
		var stacks := _as_dict_array(extracted.get("stacks", []))
		var stored := _store_stacks_on_shelf(seller, shelf, stacks, price_centi)
		if not bool(stored.get("ok", false)):
			seller.inventory_ops().restore_extracted_stacks(stacks)
			return stored
	elif current_total > target_quantity:
		var planned := _plan_matching_item_removal(seller, shelf, item_name, current_total - target_quantity)
		if not bool(planned.get("ok", false)):
			return planned
		var removed := _apply_matching_item_removal(seller, shelf, planned)
		if not bool(removed.get("ok", false)):
			return removed
	var repriced := _reprice_matching_item_listings(seller, shelf, item_name, price_centi)
	if not bool(repriced.get("ok", false)):
		return repriced
	return {
		"ok": true,
		"message": "已把 %s 调整为 x%d，定价 %s" % [
			_display_name_for_item(item_name),
			target_quantity,
			Money.format_silver_from_centi(price_centi),
		],
	}


func _apply_remove_item_op(seller: Character, shelf: ShelfNode, op: Dictionary) -> Dictionary:
	var item_name := str(op.get("item", op.get("item_name", ""))).strip_edges()
	if item_name.is_empty():
		return {"ok": false, "message": "remove 操作缺少 item"}
	var seller_id := seller.backend_character_id()
	var listings := _matching_shelf_listings(shelf, seller_id, item_name)
	var available := _total_listing_quantity(listings)
	if available <= 0:
		return {"ok": false, "message": "货架上没有 %s" % item_name}
	var requested := int(op.get("quantity", available))
	var quantity := available if requested <= 0 else requested
	if quantity > available:
		return {"ok": false, "message": "货架上的 %s 只有 %d" % [item_name, available]}
	var planned := _plan_matching_item_removal(seller, shelf, item_name, quantity)
	if not bool(planned.get("ok", false)):
		return planned
	var removed := _apply_matching_item_removal(seller, shelf, planned)
	if not bool(removed.get("ok", false)):
		return removed
	return {
		"ok": true,
		"message": "已下架 %s x%d" % [
			_display_name_for_item(item_name, [], listings),
			quantity,
		],
	}


func _extract_named_item_across_inventory(owner: Character, item_name: String, quantity: int) -> Dictionary:
	var remaining := maxi(quantity, 0)
	var extracted: Array[Dictionary] = []
	if remaining <= 0:
		return {"ok": true, "stacks": extracted}
	for slot_index in owner.inventory_ops().find_matching_slot_indices(item_name):
		if remaining <= 0:
			break
		var slot := owner.inventory_ops().get_slot(slot_index)
		var take := mini(int(slot.get("quantity", 0)), remaining)
		if take <= 0:
			continue
		var stack := owner.inventory_ops().extract_stack(slot_index, take)
		if stack.is_empty():
			continue
		extracted.append(stack)
		remaining -= take
	if remaining > 0:
		owner.inventory_ops().restore_extracted_stacks(extracted)
		return {"ok": false, "message": "背包里没有足够的 %s" % item_name}
	return {"ok": true, "stacks": extracted}


func _store_stacks_on_shelf(seller: Character, shelf: ShelfNode, stacks: Array, price_centi: int) -> Dictionary:
	var planned := _plan_store_stacks_on_shelf(seller, shelf, stacks)
	if not bool(planned.get("ok", false)):
		return planned
	var shelf_id := shelf.effective_shelf_id()
	var seller_id := seller.backend_character_id()
	for stack_v in stacks:
		if typeof(stack_v) != TYPE_DICTIONARY:
			continue
		var stack: Dictionary = (stack_v as Dictionary).duplicate(true)
		var remaining := int(stack.get("quantity", 0))
		if remaining <= 0:
			continue
		for listing_v in Db.list_shelf_listings(shelf_id):
			if remaining <= 0:
				break
			var listing: Dictionary = listing_v as Dictionary
			if str(listing.get("owner_character_id", "")).strip_edges() != seller_id:
				continue
			var slot: Dictionary = (listing.get("slot", {}) as Dictionary).duplicate(true)
			if not InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(stack)):
				continue
			var room := Character.INVENTORY_STACK_MAX - int(slot.get("quantity", 0))
			if room <= 0:
				continue
			var move := mini(room, remaining)
			slot["quantity"] = int(slot.get("quantity", 0)) + move
			Db.save_shelf_listing(
				shelf_id,
				int(listing.get("slot_index", 0)),
				str(listing.get("listing_id", "")),
				seller_id,
				int(listing.get("price_centi", 0)),
				slot,
				shelf.effective_location_id()
			)
			remaining -= move
		while remaining > 0:
			var slot_index := Db.next_empty_shelf_slot(shelf_id, shelf.slot_count)
			if slot_index < 0:
				return {"ok": false, "message": "货架已经摆满了"}
			var chunk := mini(remaining, Character.INVENTORY_STACK_MAX)
			var placed := stack.duplicate(true)
			placed["quantity"] = chunk
			Db.save_shelf_listing(
				shelf_id,
				slot_index,
				_new_listing_id(shelf_id),
				seller_id,
				price_centi,
				placed,
				shelf.effective_location_id()
			)
			remaining -= chunk
	return {"ok": true}


func _plan_store_stacks_on_shelf(seller: Character, shelf: ShelfNode, stacks: Array) -> Dictionary:
	var seller_id := seller.backend_character_id()
	var used_slots := {}
	var virtual_listings: Array[Dictionary] = []
	for listing_v in Db.list_shelf_listings(shelf.effective_shelf_id()):
		var listing: Dictionary = (listing_v as Dictionary).duplicate(true)
		used_slots[int(listing.get("slot_index", -1))] = true
		virtual_listings.append(listing)
	for stack_v in stacks:
		if typeof(stack_v) != TYPE_DICTIONARY:
			continue
		var stack: Dictionary = stack_v as Dictionary
		var remaining := int(stack.get("quantity", 0))
		if remaining <= 0:
			continue
		for index in virtual_listings.size():
			if remaining <= 0:
				break
			var listing := virtual_listings[index]
			if str(listing.get("owner_character_id", "")).strip_edges() != seller_id:
				continue
			var slot: Dictionary = (listing.get("slot", {}) as Dictionary).duplicate(true)
			if not InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(stack)):
				continue
			var room := Character.INVENTORY_STACK_MAX - int(slot.get("quantity", 0))
			if room <= 0:
				continue
			var move := mini(room, remaining)
			slot["quantity"] = int(slot.get("quantity", 0)) + move
			listing["slot"] = slot
			virtual_listings[index] = listing
			remaining -= move
		while remaining > 0:
			var slot_index := _next_unused_shelf_slot(used_slots, shelf.slot_count)
			if slot_index < 0:
				return {"ok": false, "message": "货架已经摆满了"}
			var placed := (stack as Dictionary).duplicate(true)
			placed["quantity"] = mini(remaining, Character.INVENTORY_STACK_MAX)
			used_slots[slot_index] = true
			virtual_listings.append({
				"slot_index": slot_index,
				"owner_character_id": seller_id,
				"slot": placed,
			})
			remaining -= int(placed.get("quantity", 0))
	return {"ok": true}


func _plan_matching_item_removal(seller: Character, shelf: ShelfNode, item_name: String, quantity: int) -> Dictionary:
	var seller_id := seller.backend_character_id()
	var listings := _matching_shelf_listings(shelf, seller_id, item_name)
	if listings.is_empty():
		return {"ok": false, "message": "货架上没有 %s" % item_name}
	var available := _total_listing_quantity(listings)
	if quantity <= 0 or quantity > available:
		return {"ok": false, "message": "货架上的 %s 只有 %d" % [item_name, available]}
	var remaining := quantity
	var entries: Array[Dictionary] = []
	for index in range(listings.size() - 1, -1, -1):
		if remaining <= 0:
			break
		var listing := listings[index]
		var slot: Dictionary = (listing.get("slot", {}) as Dictionary).duplicate(true)
		var take := mini(int(slot.get("quantity", 0)), remaining)
		if take <= 0:
			continue
		var removed_stack := slot.duplicate(true)
		removed_stack["quantity"] = take
		entries.append({
			"listing": listing.duplicate(true),
			"quantity": take,
			"stack": removed_stack,
		})
		remaining -= take
	if remaining > 0:
		return {"ok": false, "message": "货架上的 %s 只有 %d" % [item_name, available]}
	return {
		"ok": true,
		"entries": entries,
		"quantity": quantity,
		"listings": listings,
	}


func _apply_matching_item_removal(seller: Character, shelf: ShelfNode, planned: Dictionary) -> Dictionary:
	var entries: Array = planned.get("entries", [])
	var returned_stacks: Array[Dictionary] = []
	for entry_v in entries:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_v as Dictionary
		returned_stacks.append((entry.get("stack", {}) as Dictionary).duplicate(true))
	var receive := seller.inventory_ops().receive_stacks(returned_stacks)
	if not bool(receive.get("ok", false)):
		return receive
	for entry_v in entries:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_v as Dictionary
		var listing: Dictionary = entry.get("listing", {})
		var listing_id := str(listing.get("listing_id", "")).strip_edges()
		if listing_id.is_empty():
			continue
		var slot: Dictionary = (listing.get("slot", {}) as Dictionary).duplicate(true)
		var available := int(slot.get("quantity", 0))
		var take := clampi(int(entry.get("quantity", 0)), 0, available)
		if take >= available:
			Db.delete_shelf_listing(listing_id)
			continue
		slot["quantity"] = available - take
		Db.save_shelf_listing(
			shelf.effective_shelf_id(),
			int(listing.get("slot_index", 0)),
			listing_id,
			seller.backend_character_id(),
			int(listing.get("price_centi", 0)),
			slot,
			shelf.effective_location_id()
		)
	return {"ok": true, "returned_stacks": returned_stacks}


func _reprice_matching_item_listings(seller: Character, shelf: ShelfNode, item_name: String, price_centi: int) -> Dictionary:
	var listings := _matching_shelf_listings(shelf, seller.backend_character_id(), item_name)
	if listings.is_empty():
		return {"ok": false, "message": "货架上没有 %s" % item_name}
	for listing in listings:
		var listing_id := str(listing.get("listing_id", "")).strip_edges()
		if listing_id.is_empty():
			continue
		Db.update_shelf_listing_price(listing_id, price_centi)
	return {"ok": true}


func _matching_shelf_listings(shelf: ShelfNode, seller_id: String, item_name: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for listing_v in Db.list_shelf_listings(shelf.effective_shelf_id()):
		var listing: Dictionary = listing_v as Dictionary
		if str(listing.get("owner_character_id", "")).strip_edges() != seller_id:
			continue
		var slot: Dictionary = listing.get("slot", {})
		if _shelf_item_matches_slot(item_name, slot):
			out.append(listing.duplicate(true))
	return out


func _total_listing_quantity(listings: Array) -> int:
	var total := 0
	for listing_v in listings:
		if typeof(listing_v) != TYPE_DICTIONARY:
			continue
		var listing: Dictionary = listing_v as Dictionary
		total += int((listing.get("slot", {}) as Dictionary).get("quantity", 0))
	return total


func _next_unused_shelf_slot(used_slots: Dictionary, slot_count: int) -> int:
	for slot_index in slot_count:
		if not used_slots.has(slot_index):
			return slot_index
	return -1


func _display_name_for_item(item_name: String, stacks: Array = [], listings: Array = []) -> String:
	for stack_v in stacks:
		if typeof(stack_v) == TYPE_DICTIONARY:
			var stack: Dictionary = stack_v as Dictionary
			if not stack.is_empty():
				return InventorySlotData.of(stack).display_name()
	for listing_v in listings:
		if typeof(listing_v) != TYPE_DICTIONARY:
			continue
		var listing: Dictionary = listing_v as Dictionary
		var slot: Dictionary = listing.get("slot", {})
		if not slot.is_empty():
			return InventorySlotData.of(slot).display_name()
	return item_name


# Backend perception 只看 id + directlyInteractable 来分 direct/near band；其余字段
# （listings / displayName / ownerGroup / slotCount 等）由 backend 自己查 shelves +
# shelf_listings 表装配 ShelfContext，这里不必重复算。trade_runner._eligible_trade_shelf_candidates
# 也只读 id。owned_snapshots_for / nearby_snapshots_for 都用这条同款 snapshot。
func _snapshot_for_shelf(node: ShelfNode, viewer: Character) -> Dictionary:
	return {
		"id": node.effective_shelf_id(),
		"directlyInteractable": _is_character_near_shelf(viewer, node),
	}


func _is_character_near_shelf(character: Character, shelf: ShelfNode) -> bool:
	if character == null or shelf == null:
		return false
	var radius := maxf(shelf.interaction_radius, INTERACTION_RADIUS)
	# 用 approach marker 作 anchor —— shelf .tscn 加 mesh 后角色站在 mesh 前
	# 0.5m 时距 origin 仍可能 > radius；workstation / container 也走同一规则。
	var anchor := shelf.get_approach_node().global_position
	return character.global_position.distance_squared_to(anchor) <= radius * radius


func _emit_sale_event(
	shelf: ShelfNode,
	seller_character_id: String,
	buyer_character_id: String,
	listing_id: String,
	stack: Dictionary,
	quantity: int,
	price_centi: int,
	source_trade_id: String = "",
	visible_to_character_ids: Array = []
) -> void:
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null or not backend.has_method("send_world_event"):
		return
	var affected: Array = []
	affected.append(buyer_character_id)
	if seller_character_id != buyer_character_id:
		affected.append(seller_character_id)
	for entry in visible_to_character_ids:
		var id := str(entry)
		if id.is_empty() or id == buyer_character_id or id == seller_character_id:
			continue
		affected.append(id)
	var data := {
		"actorId": buyer_character_id,
		"affectedCharacterIds": affected,
		"buyerCharacterId": buyer_character_id,
		"sellerCharacterId": seller_character_id,
		"shelfId": shelf.effective_shelf_id(),
		"listingId": listing_id,
		"item": InventorySlotData.of(stack).to_backend_dict(),
		"quantity": quantity,
		"priceCenti": price_centi,
		"priceSilver": price_centi / 100.0,
		"locationId": shelf.effective_location_id(),
	}
	if not source_trade_id.is_empty():
		data["tradeId"] = source_trade_id
	backend.call("send_world_event", "shelf_item_sold", data)


func _new_listing_id(shelf_id: String) -> String:
	return "%s_listing_%d" % [shelf_id, Time.get_ticks_usec()]


func _shelf_item_matches_slot(item_name: String, slot: Dictionary) -> bool:
	var wanted := _normalize_shelf_item_name(item_name)
	if wanted.is_empty():
		return false
	var view := InventorySlotData.of(slot)
	var item_id := str(slot.get("item_id", "")).strip_edges()
	var candidates: Array[String] = []
	candidates.append(view.display_name())
	if not item_id.is_empty():
		candidates.append_array(_shelf_item_aliases(item_id))
	for candidate in candidates:
		if _normalize_shelf_item_name(candidate) == wanted:
			return true
	return false


func _shelf_item_aliases(item_id: String) -> Array[String]:
	var aliases: Array[String] = [item_id, item_id.replace("_", " "), tr("item.%s.name" % item_id)]
	var tmpl := Items.by_id(item_id)
	if tmpl != null and not tmpl.display_name.is_empty():
		aliases.append(tmpl.display_name)
	return aliases


func _normalize_shelf_item_name(value: String) -> String:
	return value.strip_edges().to_lower().replace("_", " ").replace("（", "(").replace("）", ")")


func _sort_snapshots(snapshots: Array[Dictionary]) -> void:
	snapshots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", ""))
	)


func _character_node_by_id(character_id: String) -> Character:
	var wanted := character_id.strip_edges()
	if wanted.is_empty():
		return null
	for character in _all_characters():
		if character != null and character.backend_character_id() == wanted:
			return character
	return null


func _all_characters() -> Array[Character]:
	var out: Array[Character] = []
	var tree := get_tree()
	if tree == null:
		return out
	for group_name in ["npcs", "players"]:
		for node in tree.get_nodes_in_group(group_name):
			if node is Character:
				out.append(node as Character)
	return out


# 同 BackendActionRunner._as_dict_array：从 Dictionary 拿出的 Array 会丢失 typed 标签，
# .assign() 复制重打 Array[Dictionary]，给 character.receive/restore/rollback_inventory_stacks 用。
func _as_dict_array(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(value) == TYPE_ARRAY:
		out.assign(value as Array)
	return out
