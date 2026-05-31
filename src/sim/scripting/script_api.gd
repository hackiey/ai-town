class_name ScriptApi

# 注入 affect.* / world.* API table 到 lua state。
# affect.* 调用不立即生效——append 到 collected 数组，executor 跑完后由 Effects.apply 统一应用。
# 设计：lua 永远不直接 mutate 游戏状态，只声明意图。

static func inject(lua: LuaState, _ctx: Dictionary, collected: Array) -> void:
	# === affect.* 写：声明对游戏状态的修改意图 ===

	var affect_tbl := lua.create_table()

	affect_tbl["stamina"] = func(target, amount):
		collected.append({
			"type": "modify_stamina",
			"target": target,
			"amount": float(amount),
		})

	affect_tbl["hunger"] = func(target, amount):
		collected.append({
			"type": "modify_hunger",
			"target": target,
			"amount": float(amount),
		})

	affect_tbl["rest"] = func(target, amount):
		collected.append({
			"type": "modify_rest",
			"target": target,
			"amount": float(amount),
		})

	affect_tbl["hp"] = func(target, amount):
		collected.append({
			"type": "modify_hp",
			"target": target,
			"amount": float(amount),
		})

	# 解除某个 condition（按 type 移除所有匹配条目）。
	affect_tbl["remove_condition"] = func(target, condition_id):
		collected.append({
			"type": "remove_condition",
			"target": target,
			"condition_id": str(condition_id),
		})

	# Lua 只声明 alive 翻转；GDScript 在 Character.alive setter 里做物理善后
	# (NavMesh / RPC / 动画)。详见 docs/architecture/lua-mechanic-migration-plan.md §3.1 Q2。
	affect_tbl["set_alive"] = func(target, alive):
		collected.append({
			"type": "set_alive",
			"target": target,
			"alive": bool(alive),
		})

	# 说话广播：RPC 气泡 + backend world_event 上行。payload 是 LuaTable。
	affect_tbl["broadcast_speech"] = func(payload):
		var p := LuaConv.to_dict(payload)
		collected.append({
			"type": "broadcast_speech",
			"speaker": p.get("speaker"),
			"text": str(p.get("text", "")),
			"volume": str(p.get("volume", "near")),
			"target_id": str(p.get("target_id", "")),
			"affected_ids": LuaConv.to_array(p.get("affected_ids")),
		})

	# Crop / Farm bulk state set——payload.fields 是任意 key→value 的 dict，
	# Effects.apply 端按 key 分别 set。lua 端是 LuaTable，需要转 Dictionary。
	affect_tbl["crop_state"] = func(crop, fields):
		collected.append({
			"type": "crop_state",
			"crop": crop,
			"fields": LuaConv.to_dict(fields),
		})

	affect_tbl["farm_state"] = func(farm, fields):
		collected.append({
			"type": "farm_state",
			"farm": farm,
			"fields": LuaConv.to_dict(fields),
		})

	affect_tbl["crop_destroy"] = func(crop):
		collected.append({
			"type": "crop_destroy",
			"crop": crop,
		})

	# 给 receiver 的背包加 item。quantity / quality 都是 int。
	affect_tbl["give_item"] = func(receiver, item_id, quantity, quality):
		collected.append({
			"type": "give_item",
			"receiver": receiver,
			"item_id": str(item_id),
			"quantity": int(quantity),
			"quality": int(quality),
		})

	# ─── Inventory affect 套件 (§4.1)─────────────────────────────────
	# 这些是 **synchronous** affects —— 在 lua 执行期间立即应用，返回真实 qty 给 lua。
	# 与其他 affect (modify_hunger / give_item / broadcast_speech) 不同 —— 那些是
	# declarative async（lua 走完 GDScript 才 apply）。原因：transfer_item 的语义
	# 需要 lua 立刻知道 moved_qty 才能格式化错误消息。
	#
	# query 是 dict：{ item_id?, slot_index?, container_content?, min_quality? }
	# holder/from/to 接受 Character / ContainerNode / ShelfNode（shelf 写不支持）。

	affect_tbl["take_item"] = func(holder, query, qty):
		var adapter := InventoryAdapter.for_holder(holder)
		if adapter == null:
			return 0
		var result := adapter.take(LuaConv.to_dict(query), int(qty))
		# stacks 被丢弃 —— take 即"销毁"语义；想保留用 transfer_item
		return int(result.get("taken_qty", 0))

	affect_tbl["transfer_item"] = func(from_holder, to_holder, query, qty):
		var from_adapter := InventoryAdapter.for_holder(from_holder)
		var to_adapter := InventoryAdapter.for_holder(to_holder)
		if from_adapter == null or to_adapter == null:
			return 0
		var taken := from_adapter.take(LuaConv.to_dict(query), int(qty))
		var stacks: Array = taken.get("stacks", [])
		if stacks.is_empty():
			return 0
		var placed := to_adapter.place(stacks)
		var leftover: Array = placed.get("leftover", [])
		var leftover_qty := 0
		for s_v in leftover:
			if typeof(s_v) == TYPE_DICTIONARY:
				leftover_qty += int((s_v as Dictionary).get("quantity", 0))
		if leftover_qty > 0:
			# 装不下的部分塞回 from（best-effort rollback）
			from_adapter.place(leftover)
		return int(taken.get("taken_qty", 0)) - leftover_qty

	# 凭空 spawn item 到 holder（不指定来源 —— mint / NPC drop / debug 等用）。
	# 返回真实 placed_qty。给 receiver 的 Character 路径优先用 give_item（async），
	# spawn_item 是通用 holder 路径（vault / shelf / 任何 ContainerNode）。
	affect_tbl["spawn_item"] = func(holder, item_id, quantity, quality):
		var adapter := InventoryAdapter.for_holder(holder)
		if adapter == null:
			return 0
		var qty := int(quantity)
		var iid := str(item_id)
		if qty <= 0 or iid.is_empty():
			return 0
		var stack := InventorySlotData.from_template(iid, int(quality))
		stack["quantity"] = qty
		var placed := adapter.place([stack])
		return int(placed.get("placed_qty", 0))

	# Bulk-set 单 slot 字段（quality / item_id / materials 等任意）。同步，返回 bool。
	affect_tbl["set_slot_state"] = func(holder, slot_index, fields):
		var adapter := InventoryAdapter.for_holder(holder)
		if adapter == null:
			return false
		return adapter.set_slot(int(slot_index), LuaConv.to_dict(fields))

	# Trade 业务封装入口（Step 6.6）。撮合 / DB 写在 Character.trade_runner()；
	# lua 通过 affect.trade_op 同步调用。world_event 不在此发，让 lua 通过 return
	# 数据走 MechanicVerb 自动发。
	affect_tbl["trade_op"] = func(actor, op, args):
		if not (actor is Character):
			return LuaConv.to_lua(lua, { "ok": false, "message": "trade_op: actor is not Character" })
		var ch: Character = actor as Character
		var trade: TradeRunner = ch.trade_runner()
		if trade == null:
			return LuaConv.to_lua(lua, { "ok": false, "message": "trade_op: trade_runner unavailable" })
		var args_d: Dictionary = LuaConv.to_dict(args)
		var op_str := str(op)
		var result: Dictionary
		match op_str:
			"create":
				var off_v: Variant = args_d.get("offer", [])
				var req_v: Variant = args_d.get("request", [])
				var off_arr: Array = off_v if off_v is Array else []
				var req_arr: Array = req_v if req_v is Array else []
				result = trade.trade_create(str(args_d.get("seller_id", "")), off_arr, req_arr)
			"respond":
				result = trade.trade_respond(
					str(args_d.get("trade_id", "")),
					str(args_d.get("response", "")),
				)
			_:
				result = { "ok": false, "message": "trade_op: unknown op '%s'" % op_str }
		return LuaConv.to_lua(lua, result)

	# Shelf 业务封装入口（Step 6.3）。Listings 写路径形状跟普通 slot 不同（有 price
	# 元数据 + DB 持久），不能塞进 InventoryAdapter；这里 wrap 现有 Shelves API
	# 让 lua 调度。返回 GDScript dict（含 ok/message/result/changes 等），转 lua table。
	affect_tbl["shelf_op"] = func(actor, shelf, op, args):
		if not (shelf is ShelfNode):
			return LuaConv.to_lua(lua, { "ok": false, "message": "shelf_op: shelf is not ShelfNode" })
		if not (actor is Character):
			return LuaConv.to_lua(lua, { "ok": false, "message": "shelf_op: actor is not Character" })
		var args_d: Dictionary = LuaConv.to_dict(args)
		var shelf_id := (shelf as ShelfNode).effective_shelf_id()
		var op_str := str(op)
		var result: Dictionary
		match op_str:
			"update":
				var ops_v: Variant = args_d.get("ops", [])
				var ops_arr: Array = ops_v if ops_v is Array else []
				result = Shelves.update_shelf(actor as Character, shelf_id, ops_arr)
			"buy":
				result = Shelves.buy_from_shelf(
					actor as Character, shelf_id,
					str(args_d.get("listing_id", "")),
					int(args_d.get("quantity", 1)),
					int(args_d.get("total_price_centi", -1)),
				)
			_:
				result = { "ok": false, "message": "shelf_op: unknown op '%s'" % op_str }
		return LuaConv.to_lua(lua, result)

	# 给角色挂 condition（buff/debuff）。expires_total_hours 用 GameClock.total_game_hours()
	# 体系——0 表示永久。source 是个标签，方便后续按来源批量清。
	affect_tbl["add_condition"] = func(target, condition_id, expires_total_hours, source):
		collected.append({
			"type": "add_condition",
			"target": target,
			"condition_id": str(condition_id),
			"expires_total_hours": int(expires_total_hours),
			"source": str(source),
		})

	# 让 lua 直接往 backend 发 world_event（除 say_to 之外的事件，比如 spell_cast / pickup）。
	# data 是 LuaTable，转成 Dict 透传给 BackendRuntimeClient.send_world_event。
	affect_tbl["world_event"] = func(event_type, text, data):
		collected.append({
			"type": "world_event",
			"event_type": str(event_type),
			"text": str(text),
			"data": LuaConv.to_dict(data),
		})

	lua.globals["affect"] = affect_tbl

	# === world.* 读：免费的世界查询 ===

	var world_tbl := lua.create_table()
	world_tbl["now"] = func() -> float:
		return Time.get_ticks_msec() / 1000.0

	# 物质数据快照——给 crafting transforms / alloys / freshness 用。
	# 必须返回 lua table（不是 GDScript Dict）才能让 lua 端用 .field 访问。
	world_tbl["material"] = func(id):
		var m: Substance = Materials.by_id(str(id))
		if m == null:
			return null
		var t := lua.create_table()
		t["id"] = m.id
		t["category"] = m.category
		t["hardness"] = m.hardness
		t["density"] = m.density
		t["shelf_life_hours"] = m.shelf_life_hours
		t["rotten_into"] = m.rotten_into
		# nested dict / array：再 create_table 一层
		var transforms := lua.create_table()
		for k in m.transforms.keys():
			transforms[str(k)] = m.transforms[k]
		t["transforms"] = transforms
		var alloys := lua.create_table()
		for k in m.alloys.keys():
			alloys[str(k)] = m.alloys[k]
		t["alloys"] = alloys
		var tags := lua.create_table()
		for i in m.tags.size():
			tags.rawset(i + 1, str(m.tags[i]))
		t["tags"] = tags
		return t

	# 按 (shape_type, body_material) 查 item template id
	world_tbl["find_item_template"] = func(shape_type, body_material):
		return Items.find_template(str(shape_type), str(body_material))

	# 查 holder 里所有匹配 query 的 slot。返回 lua array of dict，每条 =
	# {slot_index, item_id, qty, quality, container_content}。query 同 inventory 套件 schema。
	# 注：Shelf holder 投影 slot 时会在槽上挂 view-only 字段 _listing_price_centi /
	# _listing_id / _listing_owner_character_id（参见 Shelves.adapter_listing_slots），
	# 但 world.find_items 不把它们暴露到 lua —— 6.3 buy_listing 走 affect.shelf_op 直接
	# 用 listing_id，不依赖 lua 端反查 slot.properties。
	world_tbl["find_items"] = func(holder, query):
		var adapter := InventoryAdapter.for_holder(holder)
		if adapter == null:
			return lua.create_table()
		var query_dict: Dictionary = LuaConv.to_dict(query)
		var matches: Array = adapter.find(query_dict)
		var arr := lua.create_table()
		for i in matches.size():
			var match: Dictionary = matches[i] as Dictionary
			var entry := lua.create_table()
			entry["slot_index"] = int(match.get("slot_index", -1))
			entry["item_id"] = str(match.get("item_id", ""))
			entry["qty"] = int(match.get("qty", 0))
			entry["quality"] = int(match.get("quality", 100))
			entry["container_content"] = str(match.get("container_content", ""))
			arr.rawset(i + 1, entry)  # lua 1-indexed
		return arr

	lua.globals["world"] = world_tbl
