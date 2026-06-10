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

# 靠近判定半径 = 目标对象自己 SiteMarker 的可交互距离（逐对象，玩家/NPC 同路径）。


static func run_put_take(character: Character, action_request: Dictionary, completion: Callable = Callable()) -> Dictionary:
	var draw_amount: Dictionary = character.water_draw_actions().amount_liters_for_action(action_request)
	if not bool(draw_amount.get("ok", false)):
		return draw_amount
	if float(draw_amount.get("amount_liters", 0.0)) > 0.0:
		return character.water_draw_actions().start_from_put_take(action_request, completion)
	return run_put_take_now(character, action_request)


static func run_put_take_now(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": _msg("error.put_take.invalid_target")}
	var transfers_v: Variant = (target as Dictionary).get("transfers", [])
	if typeof(transfers_v) != TYPE_ARRAY or (transfers_v as Array).is_empty():
		return {"ok": false, "message": _msg("error.put_take.empty_transfers")}
	if Containers == null:
		return {"ok": false, "message": "Containers autoload is unavailable"}
	var prepared := _prepare_shelf_payments(character, transfers_v as Array)
	if not bool(prepared.get("ok", false)):
		return {"ok": false, "message": str(prepared.get("message", _msg("error.shelf.payment_not_enough")))}
	var transfers: Array = prepared.get("transfers", [])
	var change_centi := int(prepared.get("change_centi", 0))

	var lines: Array = []
	var moves: Array = []
	for tr_v in transfers:
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
		else:
			var failed_message := _msg("tool.tool_result.separator").join(lines) if not lines.is_empty() else _msg("error.put_take.no_moves")
			return {"ok": false, "message": failed_message, "result": {"moves": moves}}

	if moves.is_empty():
		return {"ok": false, "message": _msg("tool.tool_result.separator").join(lines) if not lines.is_empty() else _msg("error.put_take.no_moves")}
	if change_centi > 0:
		lines.append(_fmt("tool.tool_result.put_take.change_format", [Money.format_silver_from_centi(change_centi)]))

	character.emit_world_event("container_put_take", {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"moves": moves,
	})

	var msg_lines: Array = []
	for l in lines:
		msg_lines.append(str(l))
	return {"ok": true, "message": "\n".join(msg_lines), "result": {"moves": moves}}


static func run_view_container(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		_emit_view_event(character, "", false, "failure", [], "view_container target must be object")
		return {"ok": false, "message": "view_container target must be object"}
	var t: Dictionary = target as Dictionary
	var cid := str(t.get("containerId", ""))
	var is_shelf := bool(t.get("isShelf", false))
	if cid.is_empty():
		var err_missing := _msg("error.view_container.missing_container_id")
		_emit_view_event(character, cid, is_shelf, "failure", [], err_missing)
		return {"ok": false, "message": err_missing}
	var node := _near_node(character, cid)
	if node == null:
		var err_unavailable := _msg("error.view_container.unavailable")
		_emit_view_event(character, cid, is_shelf, "failure", [], err_unavailable)
		return {"ok": false, "message": err_unavailable}
	var items := _view_container_items(character, node, is_shelf)
	var label := node.effective_display_name()
	var lines: Array[String] = []
	for item_v in items:
		var item: Dictionary = item_v as Dictionary
		lines.append(str(item.get("line", "")))
	var body := _msg("tool.tool_result.separator").join(lines) if not lines.is_empty() else _msg("tool.tool_result.view_container.empty")
	var message := _fmt("tool.tool_result.view_container.message_format", [label, body])
	_emit_view_event(character, cid, is_shelf, "success", items, "")
	return {
		"ok": true,
		"message": message,
		"result": {"containerId": cid, "label": label, "items": items, "message": message},
	}


static func _emit_view_event(character: Character, cid: String, is_shelf: bool, outcome: String, items: Array, error: String) -> void:
	var data := {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"containerId": cid,
		"kind": "shelf" if is_shelf else "container",
		"outcome": outcome,
		"items": items,
	}
	var node: ContainerNode = null
	if not cid.is_empty():
		node = _near_node(character, cid)
	if node != null:
		data["label"] = node.effective_display_name()
	if not error.is_empty():
		data["error"] = error
	character.emit_world_event("view_container", data)


static func _view_container_items(character: Character, node: ContainerNode, is_shelf: bool) -> Array:
	var out: Array = []
	if node == null:
		return out
	if node.is_infinite_source():
		out.append({
			"itemId": str(node.infinite_content),
			"quantity": 1,
			"content": str(node.infinite_content),
			"amount": -1,
			"line": _fmt("tool.tool_result.view_container.infinite_format", [str(node.infinite_content)]),
		})
		return out
	var index := 1
	if int(node.wallet_centi) > 0 and (not is_shelf or _can_access_node_owner_group(character, node)):
		var wallet_amount := float(node.wallet_centi) / 100.0
		var wallet_line := "[%d] %s x%s" % [index, character.localize_item_name("silver_coin"), _format_amount(wallet_amount)]
		out.append({
			"itemId": "silver_coin",
			"quantity": wallet_amount,
			"index": index,
			"line": wallet_line,
		})
		index += 1
	for slot_v in node.contents:
		if typeof(slot_v) != TYPE_DICTIONARY:
			continue
		var slot: Dictionary = slot_v as Dictionary
		var view := InventorySlotData.of(slot)
		if view.is_empty():
			continue
		var item_id := str(slot.get("item_id", ""))
		var quantity := int(slot.get("quantity", 0))
		var line := "[%d] %s x%d" % [index, view.display_name(), quantity]
		var row := {"itemId": item_id, "quantity": quantity, "index": index, "line": line}
		var container := view.as_container()
		if container != null and container.amount() > 0.0:
			row["content"] = container.content_id()
			row["amount"] = container.amount()
			line += "（%s %.2fL）" % [container.content_id(), container.amount()]
		if is_shelf and slot.get("listing_price_centi", null) != null:
			var centi := int(slot.get("listing_price_centi", 0))
			if centi > 0:
				row["priceSilver"] = float(centi) / 100.0
				line += _fmt("tool.tool_result.view_container.price_silver_format", [float(centi) / 100.0])
		row["line"] = line
		out.append(row)
		index += 1
	return out


# 货架购买预检：从货架取带标价商品时，必须同次把足额银币付进同一货架钱包。
# 多付不进入货架钱包，执行前把付款 transfer 裁到应付额，差额作为找零提示。
static func _prepare_shelf_payments(character: Character, raw_transfers: Array) -> Dictionary:
	var transfers: Array = []
	for tr_v in raw_transfers:
		if typeof(tr_v) == TYPE_DICTIONARY:
			transfers.append((tr_v as Dictionary).duplicate(true))
		else:
			transfers.append(tr_v)
	var required_by_cid := {}
	var paid_by_cid := {}
	for tr_v in transfers:
		if typeof(tr_v) != TYPE_DICTIONARY:
			continue
		var tr_req := tr_v as Dictionary
		if str(tr_req.get("kind", "item")) != "item":
			continue
		var item_id_req := str(tr_req.get("itemId", ""))
		var coin_centi_req := CharacterInventory.currency_item_centi(item_id_req)
		var from_req: Dictionary = tr_req.get("from", {}) if typeof(tr_req.get("from", {})) == TYPE_DICTIONARY else {}
		var to_req: Dictionary = tr_req.get("to", {}) if typeof(tr_req.get("to", {})) == TYPE_DICTIONARY else {}
		if str(from_req.get("where", "")) == "node" and str(to_req.get("where", "")) == "backpack" and bool(from_req.get("isShelf", false)) and coin_centi_req <= 0:
			var cid_req := str(from_req.get("containerId", ""))
			var node_req := _near_node(character, cid_req)
			if node_req == null:
				return {"ok": false, "message": _fmt("error.container.not_nearby_format", [cid_req])}
			var qty_req := int(round(float(tr_req.get("amount", 0.0))))
			if qty_req <= 0:
				continue
			var slot_index_req := int(from_req.get("slotIndex", -1))
			if slot_index_req < 0 or slot_index_req >= node_req.contents.size():
				return {"ok": false, "message": _msg("error.shelf.invalid_slot")}
			var slot_req: Dictionary = node_req.contents[slot_index_req]
			if str(slot_req.get("item_id", "")) != item_id_req or int(slot_req.get("quantity", 0)) < qty_req:
				return {"ok": false, "message": _fmt("error.container.not_enough_item_format", [node_req.effective_display_name(), character.localize_item_name(item_id_req)])}
			var price_centi_req := int(slot_req.get("listing_price_centi", 0)) if slot_req.get("listing_price_centi", null) != null else 0
			if price_centi_req > 0:
				required_by_cid[cid_req] = int(required_by_cid.get(cid_req, 0)) + price_centi_req * qty_req
		elif str(from_req.get("where", "")) == "backpack" and str(to_req.get("where", "")) == "node" and bool(to_req.get("isShelf", false)) and coin_centi_req > 0:
			var pay_cid_req := str(to_req.get("containerId", ""))
			paid_by_cid[pay_cid_req] = int(paid_by_cid.get(pay_cid_req, 0)) + _currency_transfer_centi(item_id_req, float(tr_req.get("amount", 0.0)))

	for cid_check in required_by_cid.keys():
		if int(paid_by_cid.get(cid_check, 0)) < int(required_by_cid[cid_check]):
			return {"ok": false, "message": _msg("error.shelf.payment_not_enough")}
	var total_required := 0
	for cid_total in required_by_cid.keys():
		total_required += int(required_by_cid[cid_total])
	if total_required > character.wallet_balance_centi():
		return {"ok": false, "message": _msg("error.shelf.payment_not_enough")}

	var kept_by_cid := {}
	var change_centi := 0
	for tr_v in transfers:
		if typeof(tr_v) != TYPE_DICTIONARY:
			continue
		var tr_pay := tr_v as Dictionary
		if str(tr_pay.get("kind", "item")) != "item":
			continue
		var item_id_pay := str(tr_pay.get("itemId", ""))
		var coin_centi_pay := CharacterInventory.currency_item_centi(item_id_pay)
		if coin_centi_pay <= 0:
			continue
		var from_pay: Dictionary = tr_pay.get("from", {}) if typeof(tr_pay.get("from", {})) == TYPE_DICTIONARY else {}
		var to_pay: Dictionary = tr_pay.get("to", {}) if typeof(tr_pay.get("to", {})) == TYPE_DICTIONARY else {}
		if not (str(from_pay.get("where", "")) == "backpack" and str(to_pay.get("where", "")) == "node" and bool(to_pay.get("isShelf", false))):
			continue
		var cid_pay := str(to_pay.get("containerId", ""))
		var due_pay := int(required_by_cid.get(cid_pay, 0))
		if due_pay <= 0:
			continue
		var original_pay := _currency_transfer_centi(item_id_pay, float(tr_pay.get("amount", 0.0)))
		var keep_pay := mini(original_pay, maxi(0, due_pay - int(kept_by_cid.get(cid_pay, 0))))
		kept_by_cid[cid_pay] = int(kept_by_cid.get(cid_pay, 0)) + keep_pay
		change_centi += original_pay - keep_pay
		tr_pay["amount"] = float(keep_pay) / float(coin_centi_pay)

	if not required_by_cid.is_empty():
		var total_outgoing_centi := 0
		for tr_v in transfers:
			if typeof(tr_v) != TYPE_DICTIONARY:
				continue
			var tr_out := tr_v as Dictionary
			if str(tr_out.get("kind", "item")) != "item":
				continue
			var item_id_out := str(tr_out.get("itemId", ""))
			if CharacterInventory.currency_item_centi(item_id_out) <= 0:
				continue
			var from_out: Dictionary = tr_out.get("from", {}) if typeof(tr_out.get("from", {})) == TYPE_DICTIONARY else {}
			if str(from_out.get("where", "")) == "backpack":
				total_outgoing_centi += _currency_transfer_centi(item_id_out, float(tr_out.get("amount", 0.0)))
		if total_outgoing_centi > character.wallet_balance_centi():
			return {"ok": false, "message": _msg("error.shelf.payment_not_enough")}

		var normal_transfers: Array = []
		var purchase_payments: Array = []
		for tr_v in transfers:
			if typeof(tr_v) != TYPE_DICTIONARY:
				normal_transfers.append(tr_v)
				continue
			var tr_sort := tr_v as Dictionary
			var item_id_sort := str(tr_sort.get("itemId", ""))
			var from_sort: Dictionary = tr_sort.get("from", {}) if typeof(tr_sort.get("from", {})) == TYPE_DICTIONARY else {}
			var to_sort: Dictionary = tr_sort.get("to", {}) if typeof(tr_sort.get("to", {})) == TYPE_DICTIONARY else {}
			var is_purchase_payment := str(tr_sort.get("kind", "item")) == "item"
			if is_purchase_payment:
				is_purchase_payment = CharacterInventory.currency_item_centi(item_id_sort) > 0
			if is_purchase_payment:
				is_purchase_payment = str(from_sort.get("where", "")) == "backpack"
			if is_purchase_payment:
				is_purchase_payment = str(to_sort.get("where", "")) == "node"
			if is_purchase_payment:
				is_purchase_payment = bool(to_sort.get("isShelf", false))
			if is_purchase_payment:
				is_purchase_payment = int(required_by_cid.get(str(to_sort.get("containerId", "")), 0)) > 0
			if is_purchase_payment:
				purchase_payments.append(tr_sort)
			else:
				normal_transfers.append(tr_sort)
		transfers = normal_transfers + purchase_payments

	return {"ok": true, "transfers": transfers, "change_centi": change_centi}


static func _currency_transfer_centi(item_id: String, amount: float) -> int:
	var unit_centi := CharacterInventory.currency_item_centi(item_id)
	if unit_centi <= 0 or amount <= 0.0:
		return 0
	return maxi(0, int(round(amount * float(unit_centi))))


# ─── 液体 transfer ────────────────────────────────────────────────────

static func _do_liquid(character: Character, tr: Dictionary, lines: Array) -> Dictionary:
	var amount := float(tr.get("amount", 0.0))
	if amount <= 0.0:
		amount = 1.0
	var to_raw: Dictionary = tr.get("to", {}) if typeof(tr.get("to", {})) == TYPE_DICTIONARY else {}
	if _is_liquid_to_item_target(to_raw):
		return _do_liquid_to_item(character, tr, amount, to_raw, lines)
	var to_ep := _resolve_liquid_endpoint(character, to_raw)
	if not bool(to_ep.get("ok", false)):
		lines.append(str(to_ep.get("message", _msg("error.container.invalid_target"))))
		return {}
	var from_raw: Dictionary = tr.get("from", {}) if typeof(tr.get("from", {})) == TYPE_DICTIONARY else {}
	var dst_slot: Dictionary = to_ep["slot"]

	var result: Dictionary
	if str(from_raw.get("where", "")) == "well":
		var well := _resolve_well(character, from_raw)
		if not bool(well.get("ok", false)):
			lines.append(str(well.get("message", _msg("error.well.invalid"))))
			return {}
		result = character.water_draw_actions().draw_into_slot_now(dst_slot, well["node"], amount)
		if bool(result.get("ok", false)):
			(to_ep["commit"] as Callable).call()
	else:
		var from_ep := _resolve_liquid_endpoint(character, from_raw)
		if not bool(from_ep.get("ok", false)):
			lines.append(str(from_ep.get("message", _msg("error.container.invalid_source"))))
			return {}
		var src_slot: Dictionary = from_ep["slot"]
		result = LiquidOps.transfer_between_slots(src_slot, dst_slot, amount)
		if bool(result.get("ok", false)):
			(from_ep["commit"] as Callable).call()
			(to_ep["commit"] as Callable).call()

	if not bool(result.get("ok", false)):
		lines.append(str(result.get("message", _msg("error.liquid.transfer_failed"))))
		return {}
	var moved := float(result.get("moved", 0.0))
	var content := str(dst_slot.get("container_content", ""))
	var content_name := character.localize_item_name(content) if content != "" else _msg("tool.tool_result.liquid_fallback")
	lines.append(_fmt("tool.tool_result.put_take.poured_format", [moved, content_name, str(to_ep.get("label", _msg("tool.tool_result.container_fallback")))]))
	return {"ok": true, "kind": "liquid", "content": content, "amount": moved}


static func _is_liquid_to_item_target(to_raw: Dictionary) -> bool:
	var where := str(to_raw.get("where", ""))
	if where != "backpack" and where != "node":
		return false
	return not to_raw.has("slotIndex")


static func _do_liquid_to_item(character: Character, tr: Dictionary, amount: float, to_raw: Dictionary, lines: Array) -> Dictionary:
	var from_raw: Dictionary = tr.get("from", {}) if typeof(tr.get("from", {})) == TYPE_DICTIONARY else {}
	if str(from_raw.get("where", "")) == "well":
		lines.append(_msg("error.liquid.cannot_take_from_well"))
		return {}
	var from_ep := _resolve_liquid_endpoint(character, from_raw)
	if not bool(from_ep.get("ok", false)):
		lines.append(str(from_ep.get("message", _msg("error.container.invalid_source"))))
		return {}
	var src_slot: Dictionary = from_ep["slot"]
	if src_slot.get("ferment_ceiling", null) != null or src_slot.get("transform_age", null) != null:
		lines.append(_msg("error.liquid.fermenting"))
		return {}
	var src := InventorySlotData.of(src_slot).as_container()
	if src == null or src.is_empty():
		lines.append(_msg("error.liquid.source_empty"))
		return {}
	var content := src.content_id()
	var serving_item_id := _serving_item_for_liquid(content)
	if serving_item_id.is_empty():
		lines.append(_fmt("error.liquid.no_serving_item_format", [character.localize_item_name(content)]))
		return {}
	var serving_item: Item = Items.by_id(serving_item_id)
	var serving_liters := float(serving_item.properties.get("serving_liters", 0.0))
	if serving_liters <= 0.0:
		lines.append(_fmt("error.liquid.no_serving_liters_format", [character.localize_item_name(serving_item_id)]))
		return {}
	var available := minf(amount, src.amount())
	var servings := int(floor(available / serving_liters + 0.0001))
	if servings <= 0:
		lines.append(_fmt("error.liquid.insufficient_serving_format", [serving_liters, character.localize_item_name(serving_item_id)]))
		return {}
	var liters := float(servings) * serving_liters
	var quality := int(round(src.quality()))
	var stack := InventorySlotData.from_template(serving_item_id, quality)
	stack["quantity"] = servings

	var placed_ok := false
	var where := str(to_raw.get("where", ""))
	if where == "backpack":
		var recv := character.inventory_ops().receive_stacks([stack])
		if not bool(recv.get("ok", false)):
			lines.append(str(recv.get("message", _msg("error.inventory.full"))))
			return {}
		placed_ok = true
	elif where == "node":
		var cid := str(to_raw.get("containerId", ""))
		var node := _near_node(character, cid)
		if node == null:
			lines.append(_fmt("error.container.not_nearby_format", [cid]))
			return {}
		if not _node_can_place_stack(node, stack, servings):
			lines.append(_fmt("error.container.cannot_fit_item_format", [node.effective_display_name(), character.localize_item_name(serving_item_id)]))
			return {}
		var placed := Containers.adapter_place(node, [stack])
		if not bool(placed.get("ok", false)):
			lines.append(str(placed.get("message", _msg("error.container.full"))))
			return {}
		if bool(to_raw.get("isShelf", false)) and int(to_raw.get("priceCenti", -1)) >= 0:
			Containers.set_price_for_item(node, serving_item_id, int(to_raw.get("priceCenti", -1)))
		placed_ok = true
	if not placed_ok:
		lines.append(_msg("error.liquid.unsupported_destination"))
		return {}

	_consume_liquid_from_slot(src_slot, liters)
	(from_ep["commit"] as Callable).call()
	lines.append(_fmt("tool.tool_result.put_take.servings_taken_format", [servings, character.localize_item_name(serving_item_id), liters]))
	return {"ok": true, "kind": "item", "itemId": serving_item_id, "amount": servings}


static func _serving_item_for_liquid(content_id: String) -> String:
	var item := Items.by_id(content_id)
	if item == null:
		return ""
	if float(item.properties.get("serving_liters", 0.0)) <= 0.0:
		return ""
	return content_id


static func _consume_liquid_from_slot(slot: Dictionary, amount: float) -> void:
	var container := InventorySlotData.of(slot).as_container()
	if container == null:
		return
	var fields := container.with_consumed(amount)
	slot["container_amount"] = fields["container_amount"]
	slot["container_content"] = fields["container_content"]
	if float(fields["container_amount"]) <= 0.0:
		slot["transform_age"] = null
		slot["transform_settle_hour"] = null
		slot["ferment_ceiling"] = null


static func _node_can_place_stack(node: ContainerNode, stack: Dictionary, quantity: int) -> bool:
	if node == null or quantity <= 0:
		return false
	var remaining := quantity
	var stack_max := _stack_max_for_stack(stack)
	for slot_v in node.contents:
		if remaining <= 0:
			return true
		var slot: Dictionary = slot_v as Dictionary
		if InventorySlotData.of(slot).is_empty():
			remaining -= stack_max
			continue
		if not InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(stack)):
			continue
		remaining -= maxi(0, stack_max - int(slot.get("quantity", 0)))
	return remaining <= 0


static func _stack_max_for_stack(stack: Dictionary) -> int:
	var tmpl: Item = Items.by_id(str(stack.get("item_id", "")))
	if tmpl == null:
		return Character.INVENTORY_STACK_MAX
	if not tmpl.stackable:
		return 1
	if tmpl.max_stack > 0:
		return tmpl.max_stack
	return Character.INVENTORY_STACK_MAX


# ─── 离散 item transfer ───────────────────────────────────────────────
# 支持 背包↔node。ground 离散走 pick_up/drop 工具，这里不重复。

static func _do_item(character: Character, tr: Dictionary, lines: Array) -> Dictionary:
	var item_id := str(tr.get("itemId", "")).strip_edges()
	var amount := float(tr.get("amount", 0.0))
	if item_id.is_empty() or amount <= 0.0:
		return {}
	var from_where := str((tr.get("from", {}) as Dictionary).get("where", ""))
	var to_where := str((tr.get("to", {}) as Dictionary).get("where", ""))
	var item_name := character.localize_item_name(item_id)
	if from_where == "node" and to_where == "backpack":
		var from_d := tr["from"] as Dictionary
		return _take_from_node(character, str(from_d.get("containerId", "")), item_id, amount, item_name, int(from_d.get("slotIndex", -1)), bool(from_d.get("isShelf", false)), lines)
	if from_where == "backpack" and to_where == "node":
		var to_d := tr["to"] as Dictionary
		return _put_to_node(character, str(to_d.get("containerId", "")), item_id, amount, item_name, bool(to_d.get("isShelf", false)), int(to_d.get("priceCenti", -1)), lines)
	lines.append(_fmt("error.put_take.unsupported_transfer_format", [from_where, to_where]))
	return {}


static func _take_from_node(character: Character, cid: String, item_id: String, amount: float, item_name: String, slot_index: int, is_shelf: bool, lines: Array) -> Dictionary:
	var node := _near_node(character, cid)
	if node == null:
		lines.append(_fmt("error.container.not_nearby_format", [cid]))
		return {}
	var unit_centi := CharacterInventory.currency_item_centi(item_id)
	if unit_centi > 0:
		if is_shelf and not _can_access_node_owner_group(character, node):
			lines.append(_fmt("error.container.access_denied_format", [node.effective_display_name()]))
			return {}
		var centi := _currency_transfer_centi(item_id, amount)
		if centi <= 0:
			return {}
		if not Containers.wallet_spend_centi(cid, centi):
			lines.append(_fmt("error.container.wallet_not_enough_format", [node.effective_display_name(), item_name]))
			return {}
		character.wallet_add(centi)
		var moved_amount := float(centi) / float(unit_centi)
		lines.append(_fmt("tool.tool_result.put_take.take_amount_format", [_format_amount(moved_amount), item_name]))
		return {"ok": true, "kind": "item", "itemId": item_id, "amount": moved_amount}
	var qty := int(round(amount))
	if qty <= 0:
		return {}
	var res: Dictionary
	if slot_index >= 0:
		if slot_index >= node.contents.size():
			lines.append(_msg("error.container.invalid_slot"))
			return {}
		var slot: Dictionary = node.contents[slot_index]
		if str(slot.get("item_id", "")) != item_id or int(slot.get("quantity", 0)) < qty:
			lines.append(_fmt("error.container.not_enough_item_format", [node.effective_display_name(), item_name]))
			return {}
		res = Containers.adapter_take(node, {"slot_index": slot_index, "item_id": item_id}, qty)
		res["ok"] = int(res.get("taken_qty", 0)) == qty
	else:
		res = Containers.system_withdraw(cid, item_id, qty)
	if not bool(res.get("ok", false)):
		lines.append(_fmt("error.container.missing_item_format", [node.effective_display_name(), item_name]))
		return {}
	var stacks := _as_dict_array(res.get("stacks", []))
	var moved := _sum_qty(stacks)
	if moved <= 0:
		lines.append(_fmt("error.container.missing_item_format", [node.effective_display_name(), item_name]))
		return {}
	var rollback_stacks: Array[Dictionary] = []
	if is_shelf:
		for stack in stacks:
			rollback_stacks.append(stack.duplicate(true))
			stack["listing_price_centi"] = null
	else:
		rollback_stacks = stacks
	var recv := character.inventory_ops().receive_stacks(stacks)
	if not bool(recv.get("ok", false)):
		Containers.adapter_place(node, rollback_stacks)
		lines.append(_fmt("error.inventory.cannot_fit_item_format", [item_name]))
		return {}
	lines.append(_fmt("tool.tool_result.put_take.take_count_format", [moved, item_name]))
	return {"ok": true, "kind": "item", "itemId": item_id, "amount": moved}


static func _put_to_node(character: Character, cid: String, item_id: String, amount: float, item_name: String, is_shelf: bool, price_centi: int, lines: Array) -> Dictionary:
	var node := _near_node(character, cid)
	if node == null:
		lines.append(_fmt("error.container.not_nearby_format", [cid]))
		return {}
	var unit_centi := CharacterInventory.currency_item_centi(item_id)
	if unit_centi > 0:
		var centi := _currency_transfer_centi(item_id, amount)
		if centi <= 0:
			return {}
		var pay := character.inventory_ops().pay_centi(centi)
		if not bool(pay.get("ok", false)):
			lines.append(str(pay.get("message", _msg("error.money.not_enough"))))
			return {}
		Containers.wallet_add_centi(cid, centi)
		var moved_amount := float(centi) / float(unit_centi)
		lines.append(_fmt("tool.tool_result.put_take.put_amount_format", [_format_amount(moved_amount), item_name]))
		return {"ok": true, "kind": "item", "itemId": item_id, "amount": moved_amount}
	var qty := int(round(amount))
	if qty <= 0:
		return {}
	var moved := 0
	var available := character.inventory_ops().count_item(item_id)
	var take := mini(qty, available)
	if take <= 0:
		lines.append(_fmt("error.inventory.missing_item_format", [item_name]))
		return {}
	var ext := character.inventory_ops().extract_item_id_across_stacks(item_id, take)
	if not bool(ext.get("ok", false)):
		lines.append(_fmt("error.inventory.not_enough_item_format", [item_name]))
		return {}
	var stacks := _as_dict_array(ext.get("stacks", []))
	var placed := Containers.adapter_place(node, stacks)
	moved = int(placed.get("placed_qty", 0))
	var leftover := _as_dict_array(placed.get("leftover", []))
	if not leftover.is_empty():
		character.inventory_ops().restore_extracted_stacks(leftover)
	if moved <= 0:
		lines.append(_fmt("error.container.cannot_fit_item_format", [node.effective_display_name(), item_name]))
		return {}
	if is_shelf and price_centi >= 0:
		Containers.set_price_for_item(node, item_id, price_centi)
	lines.append(_fmt("tool.tool_result.put_take.put_count_format", [moved, item_name]))
	return {"ok": true, "kind": "item", "itemId": item_id, "amount": moved}


# ─── Endpoint 解析 ────────────────────────────────────────────────────

# 液体 endpoint → {ok, slot:Dictionary(ref), commit:Callable, label}
static func _resolve_liquid_endpoint(character: Character, ep_v: Variant) -> Dictionary:
	if typeof(ep_v) != TYPE_DICTIONARY:
		return {"ok": false, "message": _msg("error.endpoint.missing")}
	var ep := ep_v as Dictionary
	var where := str(ep.get("where", ""))
	match where:
		"backpack":
			var idx := int(ep.get("slotIndex", -1))
			if idx < 0 or idx >= character.inventory.size():
				return {"ok": false, "message": _msg("error.inventory.invalid_slot")}
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
				return {"ok": false, "message": _msg("error.container.not_nearby")}
			var nidx := int(ep.get("slotIndex", -1))
			if nidx < 0 or nidx >= node.contents.size():
				return {"ok": false, "message": _msg("error.container.invalid_slot")}
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
				return {"ok": false, "message": _msg("error.container.ground_missing")}
			var gslot: Dictionary = gi.slot_data
			var gcommit := func() -> void:
				gi.slot_data = gslot
				Db.save_ground_item(gi.db_id, gi.item_id, gi.global_position, gslot)
			return {"ok": true, "slot": gslot, "commit": gcommit, "label": gi.display_name()}
	return {"ok": false, "message": _fmt("error.endpoint.unknown_format", [where])}


static func _resolve_well(character: Character, ep: Dictionary) -> Dictionary:
	var cid := str(ep.get("containerId", "well"))
	var node := _near_node(character, cid)
	if node == null or not node.is_infinite_source():
		return {"ok": false, "message": _msg("error.well.not_nearby")}
	return {"ok": true, "node": node, "content": node.infinite_content, "quality": float(node.infinite_quality)}


static func _near_node(character: Character, cid: String) -> ContainerNode:
	# 多锚点（水井 6 口共享 "well"）：取离 character 最近的那个节点再判距离，
	# 否则只有最后注册的那口能用，其余 5 口判"不在手边"。
	var node := Containers.find_container_node_near(cid, character.global_position)
	if node == null or not is_instance_valid(node):
		return null
	var r := SiteMarker.interaction_radius_of(node)
	if character.global_position.distance_squared_to(node.global_position) > r * r:
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
			var r := SiteMarker.interaction_radius_of(gi)
			if character.global_position.distance_squared_to(gi.global_position) <= r * r:
				return gi
	return null


static func _sum_qty(stacks: Array) -> int:
	var total := 0
	for s_v in stacks:
		if typeof(s_v) == TYPE_DICTIONARY:
			total += int((s_v as Dictionary).get("quantity", 0))
	return total


static func _format_amount(value: float) -> String:
	if absf(value - roundf(value)) < 0.0001:
		return "%d" % int(roundf(value))
	return "%.2f" % value


static func _can_access_node_owner_group(character: Character, node: ContainerNode) -> bool:
	var owner_group := _owner_group_for_node(node)
	return Access.can_be_used_by(character, owner_group)


static func _owner_group_for_node(node: ContainerNode) -> String:
	if node == null:
		return ""
	var tree := node.get_tree()
	if tree != null:
		var world := tree.get_first_node_in_group("town_world")
		if world != null and world.has_method("owner_group_for"):
			return str(world.owner_group_for(node.effective_container_id()))
	var identity := node.world_object_identity()
	return identity.owner_group.strip_edges() if identity != null else ""


static func _as_dict_array(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(value) == TYPE_ARRAY:
		out.assign(value as Array)
	return out


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


static func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
