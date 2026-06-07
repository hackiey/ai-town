class_name ContainerHandlers
extends RefCounted

# 统一存取（put_take）：一串 transfers，每条把东西从一个容器搬到另一个容器。
# 容器 = 背包 / 附近容器 node（仓库·水井） / 地面物品 / 它们里的容器 item（桶·杯·酿酒桶）。
#
# transfer wire 形状（backend 已把扁平 index 解析成具体 endpoint）：
#   { kind: "item"|"liquid", amount: number,
#     itemId?: string,                       # item kind：搬哪种离散物
#     from: Endpoint, to: Endpoint }
#   Endpoint = { where: "backpack"|"node"|"ground"|"well",
#                containerId?, slotIndex?, groundItemId? }
#
# 液体：amount=升，按量加权平均品质（LiquidOps）。well = 无限源。
# 离散：amount=个数；货币(silver/gold coin) 在背包侧走钱包 centi。
# 一切 Character 级；玩家与 NPC 同一路径。

const _NEAR_RADIUS := 3.0
const _NEAR_SQ := _NEAR_RADIUS * _NEAR_RADIUS


static func run_put_take(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "put_take target must be object"}
	var transfers_v: Variant = (target as Dictionary).get("transfers", [])
	if typeof(transfers_v) != TYPE_ARRAY or (transfers_v as Array).is_empty():
		return {"ok": false, "message": "put_take 没有指定 transfers"}
	if Containers == null:
		return {"ok": false, "message": "Containers autoload is unavailable"}

	var lines: Array = []
	var moves: Array = []
	for tr_v in (transfers_v as Array):
		if typeof(tr_v) != TYPE_DICTIONARY:
			continue
		var tr := tr_v as Dictionary
		var kind := str(tr.get("kind", "item"))
		var res: Dictionary
		if kind == "liquid":
			res = _do_liquid(character, tr, lines)
		else:
			res = _do_item(character, tr, lines)
		if bool(res.get("ok", false)):
			moves.append(res)

	if moves.is_empty():
		return {"ok": false, "message": "；".join(lines) if not lines.is_empty() else "没有可搬运的内容"}

	character.emit_world_event("container_put_take", {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"moves": moves,
	})

	var msg_lines: Array = []
	for l in lines:
		msg_lines.append(str(l))
	return {"ok": true, "message": "\n".join(msg_lines), "result": {"moves": moves}}


# ─── 液体 transfer ────────────────────────────────────────────────────

static func _do_liquid(character: Character, tr: Dictionary, lines: Array) -> Dictionary:
	var amount := float(tr.get("amount", 0.0))
	if amount <= 0.0:
		amount = 1.0
	var to_ep := _resolve_liquid_endpoint(character, tr.get("to", {}))
	if not bool(to_ep.get("ok", false)):
		lines.append(str(to_ep.get("message", "目标容器无效")))
		return {}
	var from_raw: Dictionary = tr.get("from", {}) if typeof(tr.get("from", {})) == TYPE_DICTIONARY else {}
	var dst_slot: Dictionary = to_ep["slot"]

	var result: Dictionary
	if str(from_raw.get("where", "")) == "well":
		var well := _resolve_well(character, from_raw)
		if not bool(well.get("ok", false)):
			lines.append(str(well.get("message", "水井无效")))
			return {}
		result = LiquidOps.fill_from_source(dst_slot, str(well["content"]), float(well["quality"]), amount)
		if bool(result.get("ok", false)):
			(to_ep["commit"] as Callable).call()
	else:
		var from_ep := _resolve_liquid_endpoint(character, from_raw)
		if not bool(from_ep.get("ok", false)):
			lines.append(str(from_ep.get("message", "源容器无效")))
			return {}
		var src_slot: Dictionary = from_ep["slot"]
		result = LiquidOps.transfer_between_slots(src_slot, dst_slot, amount)
		if bool(result.get("ok", false)):
			(from_ep["commit"] as Callable).call()
			(to_ep["commit"] as Callable).call()

	if not bool(result.get("ok", false)):
		lines.append(str(result.get("message", "倒不动")))
		return {}
	var moved := float(result.get("moved", 0.0))
	var content := str(dst_slot.get("container_content", ""))
	var content_name := character.localize_item_name(content) if content != "" else "液体"
	lines.append("倒了 %.0f 升「%s」进「%s」" % [moved, content_name, str(to_ep.get("label", "容器"))])
	return {"ok": true, "kind": "liquid", "content": content, "amount": moved}


# ─── 离散 item transfer ───────────────────────────────────────────────
# 支持 背包↔node。ground 离散走 pick_up/drop 工具，这里不重复。

static func _do_item(character: Character, tr: Dictionary, lines: Array) -> Dictionary:
	var item_id := str(tr.get("itemId", "")).strip_edges()
	var qty := int(tr.get("amount", 0))
	if item_id.is_empty() or qty <= 0:
		return {}
	var from_where := str((tr.get("from", {}) as Dictionary).get("where", ""))
	var to_where := str((tr.get("to", {}) as Dictionary).get("where", ""))
	var item_name := character.localize_item_name(item_id)
	if from_where == "node" and to_where == "backpack":
		return _take_from_node(character, str((tr["from"] as Dictionary).get("containerId", "")), item_id, qty, item_name, lines)
	if from_where == "backpack" and to_where == "node":
		var to_d := tr["to"] as Dictionary
		return _put_to_node(character, str(to_d.get("containerId", "")), item_id, qty, item_name, bool(to_d.get("isShelf", false)), int(to_d.get("priceCenti", -1)), lines)
	lines.append("不支持的搬运：%s→%s" % [from_where, to_where])
	return {}


static func _take_from_node(character: Character, cid: String, item_id: String, qty: int, item_name: String, lines: Array) -> Dictionary:
	var node := _near_node(character, cid)
	if node == null:
		lines.append("「%s」不在手边" % cid)
		return {}
	var unit_centi := CharacterInventory.currency_item_centi(item_id)
	var res := Containers.system_withdraw(cid, item_id, qty)
	if not bool(res.get("ok", false)):
		lines.append("「%s」里没有「%s」" % [node.effective_display_name(), item_name])
		return {}
	var stacks := _as_dict_array(res.get("stacks", []))
	var moved := _sum_qty(stacks)
	if moved <= 0:
		lines.append("「%s」里没有「%s」" % [node.effective_display_name(), item_name])
		return {}
	if unit_centi > 0:
		character.wallet_add(moved * unit_centi)
	else:
		var recv := character.inventory_ops().receive_stacks(stacks)
		if not bool(recv.get("ok", false)):
			Containers.adapter_place(node, stacks)
			lines.append("背包装不下「%s」" % item_name)
			return {}
	lines.append("取出 %d 份「%s」" % [moved, item_name])
	return {"ok": true, "kind": "item", "itemId": item_id, "amount": moved}


static func _put_to_node(character: Character, cid: String, item_id: String, qty: int, item_name: String, is_shelf: bool, price_centi: int, lines: Array) -> Dictionary:
	var node := _near_node(character, cid)
	if node == null:
		lines.append("「%s」不在手边" % cid)
		return {}
	var unit_centi := CharacterInventory.currency_item_centi(item_id)
	var moved := 0
	if unit_centi > 0:
		var centi := qty * unit_centi
		var pay := character.inventory_ops().pay_centi(centi)
		if not bool(pay.get("ok", false)):
			lines.append(str(pay.get("message", "钱不够")))
			return {}
		var dep := Containers.system_deposit(cid, item_id, qty)
		if not bool(dep.get("ok", false)):
			character.inventory_ops().refund_centi(centi)
			lines.append("「%s」装不下" % node.effective_display_name())
			return {}
		moved = qty
	else:
		var available := character.inventory_ops().count_item(item_id)
		var take := mini(qty, available)
		if take <= 0:
			lines.append("你身上没有「%s」" % item_name)
			return {}
		var ext := character.inventory_ops().extract_item_id_across_stacks(item_id, take)
		if not bool(ext.get("ok", false)):
			lines.append("你身上没有足够的「%s」" % item_name)
			return {}
		var stacks := _as_dict_array(ext.get("stacks", []))
		var placed := Containers.adapter_place(node, stacks)
		moved = int(placed.get("placed_qty", 0))
		var leftover := _as_dict_array(placed.get("leftover", []))
		if not leftover.is_empty():
			character.inventory_ops().restore_extracted_stacks(leftover)
		if moved <= 0:
			lines.append("「%s」装不下「%s」" % [node.effective_display_name(), item_name])
			return {}
	if is_shelf and price_centi >= 0:
		Containers.set_price_for_item(node, item_id, price_centi)
	lines.append("存入 %d 份「%s」" % [moved, item_name])
	return {"ok": true, "kind": "item", "itemId": item_id, "amount": moved}


# ─── Endpoint 解析 ────────────────────────────────────────────────────

# 液体 endpoint → {ok, slot:Dictionary(ref), commit:Callable, label}
static func _resolve_liquid_endpoint(character: Character, ep_v: Variant) -> Dictionary:
	if typeof(ep_v) != TYPE_DICTIONARY:
		return {"ok": false, "message": "endpoint 缺失"}
	var ep := ep_v as Dictionary
	var where := str(ep.get("where", ""))
	match where:
		"backpack":
			var idx := int(ep.get("slotIndex", -1))
			if idx < 0 or idx >= character.inventory.size():
				return {"ok": false, "message": "背包槽无效"}
			var slot: Dictionary = character.inventory[idx]
			var label := InventorySlotData.of(slot).display_name()
			var commit := func() -> void:
				character.inventory[idx] = slot
				character.inventory = character.inventory
				character.inventory_ops().persist_slot(idx)
			return {"ok": true, "slot": slot, "commit": commit, "label": label}
		"node":
			var cid := str(ep.get("containerId", ""))
			var node := _near_node(character, cid)
			if node == null:
				return {"ok": false, "message": "容器不在手边"}
			var nidx := int(ep.get("slotIndex", -1))
			if nidx < 0 or nidx >= node.contents.size():
				return {"ok": false, "message": "容器槽无效"}
			var nslot: Dictionary = node.contents[nidx]
			var ncommit := func() -> void:
				node.contents[nidx] = nslot
				node.contents = node.contents
				Db.save_container_slot(cid, nidx, nslot)
			return {"ok": true, "slot": nslot, "commit": ncommit, "label": node.effective_display_name()}
		"ground":
			var gid := str(ep.get("groundItemId", ""))
			var gi := _find_ground_item(character, gid)
			if gi == null:
				return {"ok": false, "message": "地上没有这个容器"}
			var gslot: Dictionary = gi.slot_data
			var gcommit := func() -> void:
				gi.slot_data = gslot
				Db.save_ground_item(gi.db_id, gi.item_id, gi.global_position, gslot)
			return {"ok": true, "slot": gslot, "commit": gcommit, "label": gi.display_name()}
	return {"ok": false, "message": "未知 endpoint: %s" % where}


static func _resolve_well(character: Character, ep: Dictionary) -> Dictionary:
	var cid := str(ep.get("containerId", "well"))
	var node := _near_node(character, cid)
	if node == null or not node.is_infinite_source():
		return {"ok": false, "message": "水井不在手边"}
	return {"ok": true, "content": node.infinite_content, "quality": float(node.infinite_quality)}


static func _near_node(character: Character, cid: String) -> ContainerNode:
	var node := Containers.find_container_node(cid)
	if node == null or not is_instance_valid(node):
		return null
	if character.global_position.distance_squared_to(node.global_position) > _NEAR_SQ:
		return null
	if not node.is_unlocked_by(character):
		return null
	return node


static func _find_ground_item(character: Character, db_id: String) -> GroundItem:
	if db_id.is_empty():
		return null
	for n in character.get_tree().get_nodes_in_group("ground_items"):
		var gi := n as GroundItem
		if gi != null and gi.db_id == db_id:
			if character.global_position.distance_squared_to(gi.global_position) <= _NEAR_SQ:
				return gi
	return null


static func _sum_qty(stacks: Array) -> int:
	var total := 0
	for s_v in stacks:
		if typeof(s_v) == TYPE_DICTIONARY:
			total += int((s_v as Dictionary).get("quantity", 0))
	return total


static func _as_dict_array(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(value) == TYPE_ARRAY:
		out.assign(value as Array)
	return out
