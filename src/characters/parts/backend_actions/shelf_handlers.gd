class_name ShelfHandlers
extends RefCounted

const Money = preload("res://src/sim/characters/money.gd")

# Shelf 两个 verb 走 data/mechanics/shelf.lua（Step 6.3）。GDScript 端解析 args、
# resolve 节点、access check（卖家/买家都要在 3m 内）、调 wrapper。
# Listings 写路径仍由 Shelves.update_shelf / buy_from_shelf 实现，lua 通过
# affect.shelf_op 同步调用 —— 详见 shelf.lua 头注释。


static func run_update(character: Character, action_request: Dictionary) -> Dictionary:
	return _run_shelf_verb(character, action_request, "update")


static func run_buy(character: Character, action_request: Dictionary) -> Dictionary:
	return _run_shelf_verb(character, action_request, "buy")


static func _run_shelf_verb(character: Character, action_request: Dictionary, op: String) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "%s target must be object" % op}
	var t: Dictionary = target as Dictionary
	var shelf_id_input := str(t.get("shelfId", "")).strip_edges()
	if shelf_id_input.is_empty():
		return {"ok": false, "message": "%s 缺少 shelfId" % op}
	var shelf := Shelves.find_shelf_node(shelf_id_input)
	if shelf == null:
		return {"ok": false, "message": "未知货架:%s" % shelf_id_input}

	# Access：3m 内（buy 跟 update 同样要求）—— 用 approach marker 当 anchor，
	# 跟 Shelves._is_character_near_shelf / workstation / container 同一规则。
	var anchor := shelf.get_approach_node().global_position
	var dist_sq := character.global_position.distance_squared_to(anchor)
	var radius := shelf.interaction_radius if shelf.interaction_radius > 0.0 else 3.0
	var access_ok := dist_sq <= radius * radius
	var access_reason := "" if access_ok else "你不在货架附近（需要 %.0f 米内）" % radius

	var ctx: Dictionary = {
		"actor": character,
		"actor_id": character.backend_character_id(),
		"shelf": shelf,
		"shelf_id": shelf.effective_shelf_id(),
		"location_id": shelf.effective_location_id(),
		"access_ok": access_ok,
		"access_reason": access_reason,
	}
	var hook := ""
	if op == "update":
		hook = "on_update"
		# Wire contract: ops = [{type, itemId, quantity?, priceSilver?}]. Tool 入参 priceSilver 是 silver
		# 小数（1 silver = 100 centi），这里 ×100 round 到 centi int 给 lua / GDScript 用。
		var ops_v: Variant = t.get("ops", [])
		if typeof(ops_v) != TYPE_ARRAY:
			return {"ok": false, "message": "update_shelf.ops must be array"}
		var ops: Array = []
		for op_v in (ops_v as Array):
			if typeof(op_v) != TYPE_DICTIONARY:
				continue
			var src: Dictionary = op_v as Dictionary
			var entry: Dictionary = {
				"type": str(src.get("type", "")),
				"item": str(src.get("itemId", "")),
			}
			if src.has("quantity"):
				entry["quantity"] = src["quantity"]
			if src.has("priceSilver"):
				entry["price_centi"] = Money.silver_to_centi(float(src["priceSilver"]))
			elif src.has("priceCenti"):
				entry["price_centi"] = int(src["priceCenti"])
			ops.append(entry)
		ctx["ops"] = ops
	elif op == "buy":
		hook = "on_buy"
		ctx["listing_id"] = str(t.get("listingId", "")).strip_edges()
		ctx["quantity"] = int(t.get("quantity", 1))
	return MechanicVerb.resolve("shelf", ctx, hook)
