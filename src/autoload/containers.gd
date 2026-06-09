extends Node

const INTERACTION_RADIUS := 3.0
const _CONTAINERS_JSON_REL := "backend/data/town/containers.json"

var _containers_by_id: Dictionary = {}      # container_id -> Array[ContainerNode]（多锚点：6 口井共享 "well"）
# 内容真值在 ContainerNode.contents（节点属性，server 内存权威 + 同步给 client）。
# 这里不再缓存内容；所有读写都走 node.contents，DB 仅写穿持久化。
var _config_cache: Dictionary = {}          # container_id -> {starting_inventory: [...]}; lazy-loaded
var _config_loaded: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	if not RunMode.is_runtime():
		set_process(false)
		return
	call_deferred("_prune_orphan_storage")


# 被动转换（晾晒/发酵的品质爬升与定格）不在这里——由 PassiveSimulator 全局定时器单一
# 写者推进（见 src/autoload/passive_simulator.gd）。容器读路径直接读 slot 当前值。


# ─── Registration ────────────────────────────────────────────────────

func register_container(node: ContainerNode) -> void:
	if node == null:
		return
	var cid := node.effective_container_id()
	if cid.is_empty():
		push_warning("[Containers] skipped container with empty id: %s" % node.name)
		return
	var nodes: Array = _containers_by_id.get(cid, [])
	if nodes.has(node):
		return
	# 同一 id 多个物理节点只对无限源（水井多锚点：6 口共享 "well"）合法——内容不按节点存，
	# 任一口出的水相同。储物容器（有槽）撞 id = 真错误（内容归属不明），fail-loud，见
	# [[feedback_fail_loud_no_silent_fallback]]。
	if not nodes.is_empty() and not node.is_infinite_source():
		push_error("[Containers] 储物容器 id '%s' 重复注册（内容归属不明）：%s" % [cid, node.get_path()])
	nodes.append(node)
	_containers_by_id[cid] = nodes
	# 内容从 DB 灌进 node.contents 只在 runtime 做；client 上 node.contents 由
	# MultiplayerSynchronizer 填（Db 在 client 不开）。
	if RunMode.is_runtime():
		_hydrate_contents(node)
		_hydrate_wallet(node)
		_apply_starting_inventory_if_first_boot(node)


func unregister_container(node: ContainerNode) -> void:
	if node == null:
		return
	var cid := node.effective_container_id()
	if cid.is_empty():
		return
	var nodes: Array = _containers_by_id.get(cid, [])
	nodes.erase(node)
	if nodes.is_empty():
		_containers_by_id.erase(cid)
	else:
		_containers_by_id[cid] = nodes


# 某 id 当前所有有效物理节点（顺带剔除已 free 的，回写）。
func _valid_nodes(cid: String) -> Array:
	var nodes: Array = _containers_by_id.get(cid, [])
	var out: Array = []
	for v in nodes:
		if v is ContainerNode and is_instance_valid(v):
			out.append(v)
	if out.size() != nodes.size():
		if out.is_empty():
			_containers_by_id.erase(cid)
		else:
			_containers_by_id[cid] = out
	return out


# 全部容器节点（扁平展开多锚点）。snapshot / 按名查找等遍历用。
func _all_nodes() -> Array:
	var out: Array = []
	for cid in _containers_by_id.keys():
		out.append_array(_valid_nodes(cid))
	return out


# 内容 / 系统操作用：返回该 id 任一有效节点（水井内容无差，取第一个即可）。
# 距离校验请改用 find_container_node_near。
func find_container_node(container_id: String) -> ContainerNode:
	var wanted := container_id.strip_edges()
	if wanted.is_empty():
		return null
	var nodes := _valid_nodes(wanted)
	return nodes[0] if not nodes.is_empty() else null


# 多锚点距离校验用：同 id 多节点（水井 6 口）返回离 from 最近的；单节点容器即返回它本身。
# proximity 必须走这个——按单一注册节点算距离会让其余水井全部判"太远"。
func find_container_node_near(container_id: String, from: Vector3) -> ContainerNode:
	var wanted := container_id.strip_edges()
	if wanted.is_empty():
		return null
	var best: ContainerNode = null
	var best_sq := INF
	for c in _valid_nodes(wanted):
		var d: float = from.distance_squared_to((c as ContainerNode).global_position)
		if d < best_sq:
			best_sq = d
			best = c as ContainerNode
	return best


# 容许 LLM 用 id（"treasury_vault"）或 i18n 名（"领主国库"）找到容器。
func find_container_by_name(name_or_id: String) -> ContainerNode:
	var node := find_container_node(name_or_id)
	if node != null:
		return node
	var normalized := name_or_id.strip_edges().to_lower()
	if normalized.is_empty():
		return null
	for c in _all_nodes():
		var cn := c as ContainerNode
		if cn.effective_display_name().to_lower() == normalized:
			return cn
		if cn.container_name.strip_edges().to_lower() == normalized:
			return cn
	return null


# ─── Snapshots ───────────────────────────────────────────────────────

func nearby_snapshots_for(character: Character, max_distance: float = INTERACTION_RADIUS) -> Array[Dictionary]:
	if character == null:
		return []
	var out: Array[Dictionary] = []
	var max_sq := max_distance * max_distance
	for node in _all_nodes():
		# 可见性 = 物理距离；access 不再过滤掉条目。
		# _snapshot_for 已包含 can_be_used 字段表达 group 权限。
		# 水井多锚点：6 口各自按距离判断，离得近的那口才进 snapshot。
		if character.global_position.distance_squared_to((node as ContainerNode).global_position) > max_sq:
			continue
		out.append(_snapshot_for(node, character))
	return out


func unlockable_snapshots_for(character: Character) -> Array[Dictionary]:
	if character == null:
		return []
	var out: Array[Dictionary] = []
	for node in _all_nodes():
		if not (node as ContainerNode).can_be_opened_by(character):
			continue
		out.append(_snapshot_for(node, character))
	return out


# ─── Operations ──────────────────────────────────────────────────────
# Actor-facing 存取走 ContainerHandlers.run_put_take（GDScript，含货币钱包↔coin 物品转换）。
# 这里的 system_* 路径供 Mints / Mines / Wages 等 autoload 跳过 access check 使用。

# 系统级 deposit — 跳过靠近 / 钥匙检查。Mines / Mints / Wages 等 autoload 用。
func system_deposit(container_id: String, item_id: String, qty: int, quality: int = 100) -> Dictionary:
	if qty <= 0 or item_id.is_empty():
		return {"ok": false, "message": _msg("error.container.system_deposit_invalid")}
	var node := find_container_node(container_id)
	if node == null:
		return {"ok": false, "message": _fmt("error.container.not_found_format", [container_id])}
	if not Items.has_id(item_id):
		return {"ok": false, "message": _fmt("error.item.unknown_format", [item_id])}
	var coin_centi := CharacterInventory.currency_item_centi(item_id)
	if coin_centi > 0:
		wallet_add_centi(container_id, qty * coin_centi)
		return {"ok": true, "placed_qty": qty}
	var stack := InventorySlotData.from_template(item_id, quality)
	stack["quantity"] = qty
	return _place_stacks_into_container(node, [stack])


# 系统级 withdraw — 跳过靠近 / 钥匙检查。返回 stacks 让 caller 自行使用。
func system_withdraw(container_id: String, item_id: String, qty: int) -> Dictionary:
	if qty <= 0 or item_id.is_empty():
		return {"ok": false, "message": _msg("error.container.system_withdraw_invalid")}
	var node := find_container_node(container_id)
	if node == null:
		return {"ok": false, "message": _fmt("error.container.not_found_format", [container_id])}
	var coin_centi := CharacterInventory.currency_item_centi(item_id)
	if coin_centi > 0:
		var centi := qty * coin_centi
		if not wallet_spend_centi(container_id, centi):
			return {"ok": false, "message": _msg("error.container.wallet_not_enough")}
		var stack := InventorySlotData.from_template(item_id, 100)
		stack["quantity"] = qty
		return {"ok": true, "stacks": [stack]}
	return _extract_from_container(node, item_id, qty)


# 系统级查询：直接拿到容器的内容快照（{item_id: total_qty}），不做权限校验。
# Mints / Wages 用来盘点 vault。
func system_inventory_summary(container_id: String) -> Dictionary:
	var node := find_container_node(container_id)
	if node == null:
		return {}
	var totals: Dictionary = {}
	var wallet := wallet_balance_centi(container_id)
	if wallet > 0:
		totals["silver_coin"] = wallet / 100.0
	for slot_v in node.contents:
		var slot: Dictionary = slot_v as Dictionary
		if InventorySlotData.of(slot).is_empty():
			continue
		var iid := str(slot.get("item_id", ""))
		if iid.is_empty():
			continue
		totals[iid] = int(totals.get(iid, 0)) + int(slot.get("quantity", 0))
	return totals


func wallet_balance_centi(container_id: String) -> int:
	var node := find_container_node(container_id)
	if node == null:
		return 0
	return maxi(0, int(node.wallet_centi))


func wallet_add_centi(container_id: String, centi: int) -> void:
	if centi == 0:
		return
	var node := find_container_node(container_id)
	if node == null:
		return
	node.wallet_centi = maxi(0, int(node.wallet_centi) + centi)
	Db.save_container_wallet(container_id, node.wallet_centi)


func wallet_spend_centi(container_id: String, centi: int) -> bool:
	if centi <= 0:
		return true
	var node := find_container_node(container_id)
	if node == null:
		return false
	if int(node.wallet_centi) < centi:
		return false
	node.wallet_centi = int(node.wallet_centi) - centi
	Db.save_container_wallet(container_id, node.wallet_centi)
	return true


# ─── Internal: access / hydration / contents ─────────────────────────

# 解析 container_id 或 i18n 名 + 校验 actor 访问权限。lua mechanic 调用前的预备工作；
# 把 GDScript 端的 distance / 钥匙逻辑收口到一处，container.lua 只读 access_ok / access_reason。
# 返回: { ok: bool, node: ContainerNode?, message: String, container_id: String, container_name: String }
func resolve_for_actor(actor: Character, name_or_id: String) -> Dictionary:
	if actor == null:
		return { "ok": false, "node": null, "message": _msg("error.container.actor_missing"), "container_id": "", "container_name": name_or_id }
	var node := find_container_by_name(name_or_id)
	if node == null:
		return { "ok": false, "node": null, "message": _fmt("error.container.not_found_format", [name_or_id]), "container_id": "", "container_name": name_or_id }
	# 多锚点（水井）：按名查到的是首个，换成离 actor 最近的同 id 节点，否则 _check_access 距离判误杀。
	node = find_container_node_near(node.effective_container_id(), actor.global_position)
	var access := _check_access(actor, node)
	return {
		"ok": bool(access.get("ok", false)),
		"node": node,
		"message": str(access.get("message", "")),
		"container_id": node.effective_container_id(),
		"container_name": node.effective_display_name(),
	}


# ─── InventoryAdapter API（lua affect 套件用，跳过 access 检查）─────────
# 这些方法不做距离 / 钥匙校验 —— 那是 lua mechanic 调用方该在 ctx 里准备好的事。
# Adapter 把 ContainerNode 包成 InventoryAdapter，由 effects 端调。

# runtime 上确保 node.contents 已按 slot_count 灌好（register 时已做，这里兜底乱序）。
# client 不做（Db 不开；contents 由同步填）。
func _ensure_hydrated(node: ContainerNode) -> void:
	if not RunMode.is_runtime():
		return
	if node.contents.size() != node.slot_count:
		_hydrate_contents(node)


# 写 node.contents（运行时内存权威）。所有改 contents 的路径都经这里。
# 不再做同步快照——client 显示走 Player.view_slots（分页，见 player.gd）。
func _set_contents(node: ContainerNode, slots: Array[Dictionary]) -> void:
	node.contents = slots


# server-only reader（lua adapter + Player._recompute_view 分页用）。client 不调
# （面板读 Player.view_slots）。
func adapter_slots(node: ContainerNode) -> Array:
	if node == null:
		return []
	_ensure_hydrated(node)
	return node.contents


# 按 query 扣 qty。query 同 InventoryAdapter schema {item_id?, slot_index?, content_id?, min_quality?}。
# 内部直改 node.contents + Db.save_container_slot 持久，末尾重写 node.contents 触发同步。
func adapter_take(node: ContainerNode, query: Dictionary, qty: int) -> Dictionary:
	var stacks: Array = []
	if node == null or qty <= 0:
		return { "taken_qty": 0, "stacks": stacks }
	var query_item := str(query.get("item_id", ""))
	var coin_centi := CharacterInventory.currency_item_centi(query_item)
	if coin_centi > 0:
		var centi := qty * coin_centi
		if not wallet_spend_centi(node.effective_container_id(), centi):
			return { "taken_qty": 0, "stacks": stacks }
		var stack := InventorySlotData.from_template(query_item, 100)
		stack["quantity"] = qty
		stacks.append(stack)
		return { "taken_qty": qty, "stacks": stacks }
	var cid := node.effective_container_id()
	_ensure_hydrated(node)
	var slots: Array[Dictionary] = node.contents
	var remaining := qty
	# 找匹配（slot_index in query 时只看那一个）
	var indices: Array[int] = []
	if query.has("slot_index"):
		var idx := int(query.get("slot_index", -1))
		if idx >= 0 and idx < slots.size() and InventoryAdapter.matches(slots[idx], query):
			indices.append(idx)
	else:
		for i in slots.size():
			if InventoryAdapter.matches(slots[i], query):
				indices.append(i)
	for idx in indices:
		if remaining <= 0:
			break
		var slot := slots[idx]
		var have := int(slot.get("quantity", 0))
		var take := mini(have, remaining)
		if take <= 0:
			continue
		var pulled := slot.duplicate(true)
		pulled["quantity"] = take
		stacks.append(pulled)
		var left := have - take
		if left <= 0:
			slots[idx] = InventorySlotData.empty()
		else:
			slot["quantity"] = left
			slots[idx] = slot
		Db.save_container_slot(cid, idx, slots[idx])
		remaining -= take
	_set_contents(node, slots)
	return { "taken_qty": qty - remaining, "stacks": stacks }


func adapter_place(node: ContainerNode, stacks: Array) -> Dictionary:
	if node == null or stacks.is_empty():
		return { "placed_qty": 0, "leftover": [] }
	var before_qty := 0
	var currency_qty := 0
	var non_currency: Array = []
	for s_v in stacks:
		if typeof(s_v) == TYPE_DICTIONARY:
			var stack := s_v as Dictionary
			var qty := int(stack.get("quantity", 0))
			before_qty += qty
			var item_id := str(stack.get("item_id", ""))
			var coin_centi := CharacterInventory.currency_item_centi(item_id)
			if coin_centi > 0:
				wallet_add_centi(node.effective_container_id(), qty * coin_centi)
				currency_qty += qty
			else:
				non_currency.append(stack)
	if non_currency.is_empty():
		return { "placed_qty": currency_qty, "leftover": [] }
	var result := _place_stacks_into_container(node, non_currency)
	if bool(result.get("ok", false)):
		return { "placed_qty": before_qty, "leftover": [] }
	# 失败：result 里没暴露具体 leftover，保守按"全部 leftover"返回；caller rollback 即可
	return { "placed_qty": currency_qty, "leftover": non_currency }


func adapter_set_slot(node: ContainerNode, slot_index: int, fields: Dictionary) -> bool:
	if node == null:
		return false
	var cid := node.effective_container_id()
	_ensure_hydrated(node)
	var slots: Array[Dictionary] = node.contents
	if slot_index < 0 or slot_index >= slots.size():
		return false
	var slot: Dictionary = slots[slot_index].duplicate(true)
	for k in fields.keys():
		slot[str(k)] = fields[k]
	# lua-fields 可能塞错型；落 node.contents 前归一。
	InventorySlotData.normalize(slot)
	# 同 Character adapter：fields 可能改了影响效果的字段，写库前 recompute displayed_effects。
	ItemEffects.recompute_slot(slot)
	slots[slot_index] = slot
	_set_contents(node, slots)
	Db.save_container_slot(cid, slot_index, slot)
	return true


# 给容器内某物品的所有槽位盖上货架标价（centi 银）。price_centi <= 0 → 清除标价。
# put_take 存货到货架时调用：按物品统一定价，避免 merge 后槽位 index 漂移。仅货架有意义，
# 普通容器调用也无害（标价只是展示）。
func set_price_for_item(node: ContainerNode, item_id: String, price_centi: int) -> void:
	if node == null:
		return
	var needle := item_id.strip_edges()
	if needle.is_empty():
		return
	_ensure_hydrated(node)
	var slots: Array[Dictionary] = node.contents
	var price_val: Variant = price_centi if price_centi > 0 else null
	var cid := node.effective_container_id()
	for i in slots.size():
		var slot := slots[i]
		if InventorySlotData.of(slot).is_empty():
			continue
		if str(slot.get("item_id", "")) != needle:
			continue
		slot["listing_price_centi"] = price_val
		slots[i] = slot
		Db.save_container_slot(cid, i, slot)
	_set_contents(node, slots)


func _check_access(character: Character, node: ContainerNode) -> Dictionary:
	if not node.can_be_used_by(character):
		return {"ok": false, "message": _fmt("error.container.access_denied_format", [node.effective_display_name()])}
	if not _is_character_near(character, node):
		return {"ok": false, "message": _fmt("error.container.too_far_format", [node.effective_display_name()])}
	if not node.is_unlocked_by(character):
		var key_id := node.world_object_lock_item_id()
		var key_label := tr("item.%s.name" % key_id)
		if key_label == "item.%s.name" % key_id:
			key_label = key_id
		return {"ok": false, "message": _fmt("error.container.key_required_format", [node.effective_display_name(), key_label])}
	return {"ok": true}


func _is_character_near(character: Character, node: ContainerNode) -> bool:
	if character == null or node == null:
		return false
	# 可交互距离 = 容器自己 SiteMarker 的半径（逐对象，玩家/NPC 统一）。
	var r := SiteMarker.interaction_radius_of(node)
	return character.global_position.distance_squared_to(node.global_position) <= r * r


func _hydrate_contents(node: ContainerNode) -> void:
	var container_id := node.effective_container_id()
	var slot_count := node.slot_count
	var slots: Array[Dictionary] = []
	for i in slot_count:
		slots.append(InventorySlotData.empty())
	var persisted: Dictionary = Db.take_container_inventory(container_id)
	for k in persisted.keys():
		var idx := int(k)
		if idx < 0 or idx >= slot_count:
			continue
			slots[idx] = InventorySlotData.normalize(persisted[k] as Dictionary)
	_set_contents(node, slots)


func _hydrate_wallet(node: ContainerNode) -> void:
	if node == null:
		return
	var container_id := node.effective_container_id()
	node.wallet_centi = Db.get_container_wallet_centi(container_id)


func _snapshot_for(node: ContainerNode, viewer: Character) -> Dictionary:
	var cid := node.effective_container_id()
	var can_see := node.can_be_used_by(viewer)
	var unlocked := node.is_unlocked_by(viewer)
	var can_open := can_see and unlocked
	var snap := {
		"container_id": cid,
		"name": node.effective_display_name(),
		"lock_item_id": node.lock_item_id,
		"locked": node.is_locked(),
		"unlocked": unlocked,
		"can_be_used": can_see,
		"capacity": node.slot_count,
		"can_open": can_open,
		"items": [],
	}
	if can_open:
		snap["items"] = _list_items(node)
	return snap


# 富槽位列表（含 slot_index + 液体/发酵字段），给 backend 寻址容器内的 item 与液体。
func detailed_items_for(node: ContainerNode) -> Array:
	var out: Array = []
	var slots: Array[Dictionary] = node.contents
	for i in slots.size():
		var slot: Dictionary = slots[i]
		if InventorySlotData.of(slot).is_empty():
			continue
		out.append({
			"slot_index": i,
			"item_id": str(slot.get("item_id", "")),
			"quantity": int(slot.get("quantity", 0)),
			"quality": int(slot.get("quality", 100)),
			"container_amount": slot.get("container_amount", null),
			"container_content": slot.get("container_content", null),
			"transform_age": slot.get("transform_age", null),
			"ferment_ceiling": slot.get("ferment_ceiling", null),
			"listing_price_centi": slot.get("listing_price_centi", null),
		})
	return out


func _list_items(node: ContainerNode) -> Array:
	var out: Array = []
	for slot_v in node.contents:
		var slot: Dictionary = slot_v as Dictionary
		if InventorySlotData.of(slot).is_empty():
			continue
		out.append({
			"item_id": str(slot.get("item_id", "")),
			"quantity": int(slot.get("quantity", 0)),
			"quality": int(slot.get("quality", 100)),
			"container_amount": slot.get("container_amount", null),
			"container_content": slot.get("container_content", null),
			"transform_age": slot.get("transform_age", null),
			"ferment_ceiling": slot.get("ferment_ceiling", null),
			"listing_price_centi": slot.get("listing_price_centi", null),
		})
	return out


func _extract_from_container(node: ContainerNode, item_name: String, quantity: int) -> Dictionary:
	var cid := node.effective_container_id()
	_ensure_hydrated(node)
	var slots: Array[Dictionary] = node.contents
	if slots.is_empty():
		return {"ok": false, "message": _fmt("error.container.empty_format", [node.effective_display_name()])}
	var remaining := maxi(quantity, 0)
	var extracted: Array = []
	if remaining <= 0:
		return {"ok": true, "stacks": extracted}
	var indices := _matching_slot_indices(slots, item_name)
	for idx in indices:
		if remaining <= 0:
			break
		var slot := slots[idx]
		var have := int(slot.get("quantity", 0))
		var take := mini(have, remaining)
		if take <= 0:
			continue
		var pulled := slot.duplicate(true)
		pulled["quantity"] = take
		extracted.append(pulled)
		var left := have - take
		if left <= 0:
			slots[idx] = InventorySlotData.empty()
		else:
			slot["quantity"] = left
			slots[idx] = slot
		Db.save_container_slot(cid, idx, slots[idx])
		remaining -= take
	if remaining > 0:
		# 回滚（不持久化中间态——直接复原 slots）
		for stack_v in extracted:
			var stack: Dictionary = stack_v
			var iid := str(stack.get("item_id", ""))
			var qty := int(stack.get("quantity", 0))
			# 找原槽塞回
			var put_idx := _find_stackable_slot(slots, stack, _stack_max_for(stack))
			if put_idx < 0:
				put_idx = _find_empty_slot(slots)
			if put_idx >= 0:
				if InventorySlotData.of(slots[put_idx]).is_empty():
					slots[put_idx] = stack.duplicate(true)
				else:
					slots[put_idx]["quantity"] = int(slots[put_idx].get("quantity", 0)) + qty
				Db.save_container_slot(cid, put_idx, slots[put_idx])
		return {"ok": false, "message": _fmt("error.container.not_enough_item_format", [node.effective_display_name(), item_name])}
	_set_contents(node, slots)
	return {"ok": true, "stacks": extracted}


func _place_stacks_into_container(node: ContainerNode, stacks: Array) -> Dictionary:
	var cid := node.effective_container_id()
	_ensure_hydrated(node)
	var slots: Array[Dictionary] = node.contents
	for stack_v in stacks:
		if typeof(stack_v) != TYPE_DICTIONARY:
			continue
		var stack: Dictionary = (stack_v as Dictionary).duplicate(true)
		# stacks 来源可能是 lua-built（spawn_item / craft outputs）；落 node.contents 前归一。
		InventorySlotData.normalize(stack)
		# 同 character_inventory.add_instance：lua-built stack 没 base_effects 时从
		# template 兜底；然后 recompute displayed_effects。
		if stack.get("base_effects", null) == null:
			var tmpl: Item = Items.by_id(String(stack.get("item_id", "")))
			if tmpl != null and not tmpl.base_effects.is_empty():
				stack["base_effects"] = tmpl.base_effects.duplicate()
		ItemEffects.recompute_slot(stack)
		var stack_max := _stack_max_for(stack)
		var remaining := int(stack.get("quantity", 0))
		if remaining <= 0:
			continue
		# 1) 先填可堆叠的现有槽（不可堆叠物 stack_max=1，永不并槽）
		for i in slots.size():
			if remaining <= 0:
				break
			var slot := slots[i]
			if InventorySlotData.of(slot).is_empty():
				continue
			if not InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(stack)):
				continue
			var room := stack_max - int(slot.get("quantity", 0))
			if room <= 0:
				continue
			var put := mini(room, remaining)
			slot["quantity"] = int(slot.get("quantity", 0)) + put
			slots[i] = slot
			Db.save_container_slot(cid, i, slot)
			remaining -= put
		# 2) 找空槽建新堆
		while remaining > 0:
			var idx := _find_empty_slot(slots)
			if idx < 0:
				stack["quantity"] = remaining
				_set_contents(node, slots)
				return {"ok": false, "message": _fmt("error.container.full_format", [node.effective_display_name()])}
			var chunk := mini(remaining, stack_max)
			var placed := stack.duplicate(true)
			placed["quantity"] = chunk
			slots[idx] = placed
			Db.save_container_slot(cid, idx, placed)
			remaining -= chunk
	_set_contents(node, slots)
	return {"ok": true}


func _matching_slot_indices(slots: Array[Dictionary], item_name: String) -> Array[int]:
	var out: Array[int] = []
	var needle := item_name.strip_edges().to_lower()
	if needle.is_empty():
		return out
	for i in slots.size():
		var slot := slots[i]
		if InventorySlotData.of(slot).is_empty():
			continue
		var iid := str(slot.get("item_id", "")).to_lower()
		if iid == needle:
			out.append(i)
			continue
		# 容许通过 i18n 名匹配
		var localized := tr("item.%s.name" % iid).to_lower()
		if localized != ("item.%s.name" % iid) and localized == needle:
			out.append(i)
	return out


func _find_empty_slot(slots: Array[Dictionary]) -> int:
	for i in slots.size():
		if InventorySlotData.of(slots[i]).is_empty():
			return i
	return -1


# 物品的单槽堆叠上限：不可堆叠=1；否则 template.max_stack（兜底全局常量）。
func _stack_max_for(stack: Dictionary) -> int:
	var tmpl: Item = Items.by_id(String(stack.get("item_id", "")))
	if tmpl == null:
		return Character.INVENTORY_STACK_MAX
	if not tmpl.stackable:
		return 1
	if tmpl.max_stack > 0:
		return tmpl.max_stack
	return Character.INVENTORY_STACK_MAX


func _find_stackable_slot(slots: Array[Dictionary], stack: Dictionary, stack_max: int) -> int:
	for i in slots.size():
		var slot := slots[i]
		if InventorySlotData.of(slot).is_empty():
			continue
		if InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(stack)):
			if int(slot.get("quantity", 0)) < stack_max:
				return i
	return -1


func _prune_orphan_storage() -> void:
	var valid: Array[String] = []
	for cid in _containers_by_id.keys():
		valid.append(str(cid))
	Db.prune_orphan_container_storage(valid)


# 第一次 boot 时把 backend/data/town/containers.json 里的 starting_inventory 灌进去。
# 已 seed 过的容器（即便被清空）不再补——只一次。
func _apply_starting_inventory_if_first_boot(node: ContainerNode) -> void:
	var cid := node.effective_container_id()
	if Db.has_seeded_container(cid):
		return
	var conf := _get_container_config(cid)
	var starting_wallet := Money.silver_to_centi(float(conf.get("starting_wallet_silver", 0.0)))
	if starting_wallet > 0:
		wallet_add_centi(cid, starting_wallet)
	var inv: Variant = conf.get("starting_inventory", [])
	if not (inv is Array):
		Db.mark_container_seeded(cid)
		return
	var seed_stacks: Array = []
	for entry_v in inv:
		if not (entry_v is Dictionary):
			continue
		var entry: Dictionary = entry_v as Dictionary
		var item_id := str(entry.get("item_id", ""))
		var qty := int(entry.get("quantity", 0))
		if item_id.is_empty() or qty <= 0:
			continue
		if not Items.has_id(item_id):
			push_warning("[Containers] %s starting_inventory unknown item '%s'" % [cid, item_id])
			continue
		var coin_centi := CharacterInventory.currency_item_centi(item_id)
		if coin_centi > 0:
			wallet_add_centi(cid, qty * coin_centi)
			continue
		var quality := int(entry.get("quality", 100))
		var stack := InventorySlotData.from_template(item_id, quality)
		stack["quantity"] = qty
		# 货架陈列标价。containers.json 的 starting_inventory entry 可带 price_silver。
		if entry.has("price_silver"):
			stack["listing_price_centi"] = Money.silver_to_centi(float(entry.get("price_silver", 0.0)))
		# 液体容器物（木桶/酿酒桶）可预灌内容：container_amount(升) + container_content(液体 id)。
		# quality 复用上面的 quality 当液体品质（见液体模型）。
		if entry.has("container_amount"):
			stack["container_amount"] = float(entry.get("container_amount", 0.0))
		if entry.has("container_content"):
			stack["container_content"] = str(entry.get("container_content", ""))
		seed_stacks.append(stack)
	if seed_stacks.is_empty():
		Db.mark_container_seeded(cid)
		return
	var placed := _place_stacks_into_container(node, seed_stacks)
	if not bool(placed.get("ok", false)):
		push_warning("[Containers] %s seed 部分未放下: %s" % [cid, placed.get("message", "?")])
	Db.mark_container_seeded(cid)


func _get_container_config(container_id: String) -> Dictionary:
	if not _config_loaded:
		_load_containers_config()
	var entry: Variant = _config_cache.get(container_id, {})
	return entry if entry is Dictionary else {}


func _load_containers_config() -> void:
	_config_loaded = true
	var project_root := ProjectSettings.globalize_path("res://")
	var path := project_root.path_join(_CONTAINERS_JSON_REL)
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary:
		_config_cache = parsed


func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
