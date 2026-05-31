extends Node

const INTERACTION_RADIUS := 3.0
const _CONTAINERS_JSON_REL := "backend/data/town/containers.json"

var _containers_by_id: Dictionary = {}      # container_id -> ContainerNode
var _contents: Dictionary = {}              # container_id -> Array[Dictionary] (slot dicts, length = slot_count)
var _config_cache: Dictionary = {}          # container_id -> {starting_inventory: [...]}; lazy-loaded
var _config_loaded: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	if not RunMode.is_runtime():
		set_process(false)
		return
	GameClock.slow_tick.connect(_on_slow_tick)
	call_deferred("_prune_orphan_storage")


# 每 game-hour 推进一次容器内的被动转换。
# 按 passive_tags 分发：tag → 调对应的 tick_<tag>。未来加 "fermenting" / "smoking" 等
# 在这里追加 dispatch 即可，不改 ContainerNode schema。
func _on_slow_tick(_total_game_hour: int) -> void:
	tick_drying()


# 扫所有 passive_tags 含 "drying" 的容器，给含 item.dries_into 的槽位推进 drying_age_hours，
# 到 item.drying_hours 阈值后由 lua swap 成 dries_into 模板（quantity * drying_yield_qty）。
# GDScript 端只做"找槽 + 预查 swap 模板 + 调 lua"，转换规则全在 data/mechanics/drying.lua。
# Item 模板缺失 / dries_into 不存在 → 跳过该槽，不报错（设计意图：允许 fruit 暂不可晾干）。
func tick_drying() -> void:
	for cid_v in _containers_by_id.keys():
		var node: ContainerNode = _containers_by_id[cid_v] as ContainerNode
		if node == null or not is_instance_valid(node):
			continue
		if not node.has_passive_tag("drying"):
			continue
		var cid := str(cid_v)
		var slots_v: Variant = _contents.get(cid, null)
		if slots_v == null:
			continue
		var slots: Array[Dictionary] = slots_v
		for i in slots.size():
			var slot: Dictionary = slots[i]
			if int(slot.get("quantity", 0)) <= 0:
				continue
			var iid := str(slot.get("item_id", ""))
			if iid.is_empty():
				continue
			var tmpl: Item = Items.by_id(iid)
			if tmpl == null:
				continue
			var dries_into := tmpl.dries_into.strip_edges()
			if dries_into.is_empty() or tmpl.drying_hours <= 0.0:
				continue
			var target: Item = Items.by_id(dries_into)
			if target == null:
				continue
			MechanicHost.invoke("drying", "on_dry", {
				"holder": node,
				"slot_index": i,
				"slot": slot,
				"hours": 1.0,
				"drying_hours": tmpl.drying_hours,
				"swap_to": {
					"item_id": dries_into,
					"materials": target.materials.duplicate(true),
					"shape_type": target.shape_type,
					"tags": Array(target.tags),
				},
				"yield_qty": max(1, tmpl.drying_yield_qty),
			})


# ─── Registration ────────────────────────────────────────────────────

func register_container(node: ContainerNode) -> void:
	if node == null:
		return
	var cid := node.effective_container_id()
	if cid.is_empty():
		push_warning("[Containers] skipped container with empty id: %s" % node.name)
		return
	if _containers_by_id.has(cid) and _containers_by_id[cid] != node:
		push_warning("[Containers] duplicate id '%s', replacing previous node" % cid)
	_containers_by_id[cid] = node
	_hydrate_contents(cid, node.slot_count)
	_apply_starting_inventory_if_first_boot(node)


func unregister_container(node: ContainerNode) -> void:
	if node == null:
		return
	var cid := node.effective_container_id()
	if cid.is_empty():
		return
	if _containers_by_id.get(cid) == node:
		_containers_by_id.erase(cid)


func find_container_node(container_id: String) -> ContainerNode:
	var wanted := container_id.strip_edges()
	if wanted.is_empty():
		return null
	var node: Variant = _containers_by_id.get(wanted)
	if node is ContainerNode and is_instance_valid(node):
		return node as ContainerNode
	_containers_by_id.erase(wanted)
	return null


# 容许 LLM 用 id（"treasury_vault"）或 i18n 名（"领主国库"）找到容器。
func find_container_by_name(name_or_id: String) -> ContainerNode:
	var node := find_container_node(name_or_id)
	if node != null:
		return node
	var normalized := name_or_id.strip_edges().to_lower()
	if normalized.is_empty():
		return null
	for v in _containers_by_id.values():
		var c := v as ContainerNode
		if c == null or not is_instance_valid(c):
			continue
		if c.effective_display_name().to_lower() == normalized:
			return c
		if c.container_name.strip_edges().to_lower() == normalized:
			return c
	return null


# ─── Snapshots ───────────────────────────────────────────────────────

func nearby_snapshots_for(character: Character, max_distance: float = INTERACTION_RADIUS) -> Array[Dictionary]:
	if character == null:
		return []
	var out: Array[Dictionary] = []
	var max_sq := max_distance * max_distance
	for node_v in _containers_by_id.values():
		var node := node_v as ContainerNode
		if node == null or not is_instance_valid(node):
			continue
		# 可见性 = 物理距离；access 不再过滤掉条目。
		# _snapshot_for 已包含 can_be_used 字段表达 group 权限。
		if character.global_position.distance_squared_to(node.global_position) > max_sq:
			continue
		out.append(_snapshot_for(node, character))
	return out


func unlockable_snapshots_for(character: Character) -> Array[Dictionary]:
	if character == null:
		return []
	var out: Array[Dictionary] = []
	for node_v in _containers_by_id.values():
		var node := node_v as ContainerNode
		if node == null or not is_instance_valid(node):
			continue
		if not node.can_be_opened_by(character):
			continue
		out.append(_snapshot_for(node, character))
	return out


# ─── Operations ──────────────────────────────────────────────────────
# Actor-facing deposit/withdraw/inspect 已迁到 data/mechanics/container.lua（Step 6.1）。
# 这里只剩 system_* 路径供 Mints / Mines / Wages 等 autoload 跳过 access check 使用。

# 系统级 deposit — 跳过靠近 / 钥匙检查。Mines / Mints / Wages 等 autoload 用。
func system_deposit(container_id: String, item_id: String, qty: int, quality: int = 100) -> Dictionary:
	if qty <= 0 or item_id.is_empty():
		return {"ok": false, "message": "system_deposit 参数错误"}
	var node := find_container_node(container_id)
	if node == null:
		return {"ok": false, "message": "找不到容器：%s" % container_id}
	if not Items.has_id(item_id):
		return {"ok": false, "message": "未知物品：%s" % item_id}
	var stack := InventorySlotData.from_template(item_id, quality)
	stack["quantity"] = qty
	return _place_stacks_into_container(node, [stack])


# 系统级 withdraw — 跳过靠近 / 钥匙检查。返回 stacks 让 caller 自行使用。
func system_withdraw(container_id: String, item_id: String, qty: int) -> Dictionary:
	if qty <= 0 or item_id.is_empty():
		return {"ok": false, "message": "system_withdraw 参数错误"}
	var node := find_container_node(container_id)
	if node == null:
		return {"ok": false, "message": "找不到容器：%s" % container_id}
	return _extract_from_container(node, item_id, qty)


# 系统级查询：直接拿到容器的内容快照（{item_id: total_qty}），不做权限校验。
# Mints / Wages 用来盘点 vault。
func system_inventory_summary(container_id: String) -> Dictionary:
	var node := find_container_node(container_id)
	if node == null:
		return {}
	var slots_v: Variant = _contents.get(container_id, null)
	if slots_v == null:
		return {}
	var totals: Dictionary = {}
	for slot_v in slots_v:
		var slot: Dictionary = slot_v as Dictionary
		if InventorySlotData.of(slot).is_empty():
			continue
		var iid := str(slot.get("item_id", ""))
		if iid.is_empty():
			continue
		totals[iid] = int(totals.get(iid, 0)) + int(slot.get("quantity", 0))
	return totals


# ─── Internal: access / hydration / contents ─────────────────────────

# 解析 container_id 或 i18n 名 + 校验 actor 访问权限。lua mechanic 调用前的预备工作；
# 把 GDScript 端的 distance / 钥匙逻辑收口到一处，container.lua 只读 access_ok / access_reason。
# 返回: { ok: bool, node: ContainerNode?, message: String, container_id: String, container_name: String }
func resolve_for_actor(actor: Character, name_or_id: String) -> Dictionary:
	if actor == null:
		return { "ok": false, "node": null, "message": "缺少操作角色", "container_id": "", "container_name": name_or_id }
	var node := find_container_by_name(name_or_id)
	if node == null:
		return { "ok": false, "node": null, "message": "找不到容器：%s" % name_or_id, "container_id": "", "container_name": name_or_id }
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

func adapter_slots(node: ContainerNode) -> Array:
	if node == null:
		return []
	var cid := node.effective_container_id()
	var slots_v: Variant = _contents.get(cid, null)
	if slots_v == null:
		_hydrate_contents(cid, node.slot_count)
		slots_v = _contents.get(cid, [])
	return slots_v as Array


# 按 query 扣 qty。query 同 InventoryAdapter schema {item_id?, slot_index?, content_id?, min_quality?}。
# 内部直改 _contents + Db.save_container_slot 持久。返回 { taken_qty, stacks }。
func adapter_take(node: ContainerNode, query: Dictionary, qty: int) -> Dictionary:
	var stacks: Array = []
	if node == null or qty <= 0:
		return { "taken_qty": 0, "stacks": stacks }
	var cid := node.effective_container_id()
	var slots_v: Variant = _contents.get(cid, null)
	if slots_v == null:
		_hydrate_contents(cid, node.slot_count)
		slots_v = _contents.get(cid, null)
	var slots: Array[Dictionary] = slots_v
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
	_contents[cid] = slots
	return { "taken_qty": qty - remaining, "stacks": stacks }


func adapter_place(node: ContainerNode, stacks: Array) -> Dictionary:
	if node == null or stacks.is_empty():
		return { "placed_qty": 0, "leftover": [] }
	var before_qty := 0
	for s_v in stacks:
		if typeof(s_v) == TYPE_DICTIONARY:
			before_qty += int((s_v as Dictionary).get("quantity", 0))
	var result := _place_stacks_into_container(node, stacks)
	if bool(result.get("ok", false)):
		return { "placed_qty": before_qty, "leftover": [] }
	# 失败：result 里没暴露具体 leftover，保守按"全部 leftover"返回；caller rollback 即可
	return { "placed_qty": 0, "leftover": stacks }


func adapter_set_slot(node: ContainerNode, slot_index: int, fields: Dictionary) -> bool:
	if node == null:
		return false
	var cid := node.effective_container_id()
	var slots_v: Variant = _contents.get(cid, null)
	if slots_v == null:
		return false
	var slots: Array[Dictionary] = slots_v
	if slot_index < 0 or slot_index >= slots.size():
		return false
	var slot: Dictionary = slots[slot_index].duplicate(true)
	for k in fields.keys():
		slot[str(k)] = fields[k]
	# lua-fields 可能塞错型；落 _contents 前归一。
	InventorySlotData.normalize(slot)
	# 同 Character adapter：fields 可能改了影响效果的字段，写库前 recompute displayed_effects。
	ItemEffects.recompute_slot(slot)
	slots[slot_index] = slot
	_contents[cid] = slots
	Db.save_container_slot(cid, slot_index, slot)
	return true


func _check_access(character: Character, node: ContainerNode) -> Dictionary:
	if not node.can_be_used_by(character):
		return {"ok": false, "message": "「%s」不归你管，无权打开" % node.effective_display_name()}
	if not _is_character_near(character, node):
		return {"ok": false, "message": "离「%s」太远，先走过去再操作" % node.effective_display_name()}
	if not node.is_unlocked_by(character):
		var key_id := node.lock_item_id.strip_edges()
		var key_label := tr("item.%s.name" % key_id)
		if key_label == "item.%s.name" % key_id:
			key_label = key_id
		return {"ok": false, "message": "「%s」需要钥匙「%s」才能打开" % [node.effective_display_name(), key_label]}
	return {"ok": true}


func _is_character_near(character: Character, node: ContainerNode) -> bool:
	if character == null or node == null:
		return false
	return character.global_position.distance_squared_to(node.global_position) <= INTERACTION_RADIUS * INTERACTION_RADIUS


func _hydrate_contents(container_id: String, slot_count: int) -> void:
	var slots: Array[Dictionary] = []
	for i in slot_count:
		slots.append(InventorySlotData.empty())
	var persisted: Dictionary = Db.take_container_inventory(container_id)
	for k in persisted.keys():
		var idx := int(k)
		if idx < 0 or idx >= slot_count:
			continue
		slots[idx] = InventorySlotData.normalize(persisted[k] as Dictionary)
	_contents[container_id] = slots


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
		snap["items"] = _list_items(cid)
	return snap


func _list_items(container_id: String) -> Array:
	var slots_v: Variant = _contents.get(container_id, null)
	if slots_v == null:
		return []
	var out: Array = []
	for slot_v in slots_v:
		var slot: Dictionary = slot_v as Dictionary
		if InventorySlotData.of(slot).is_empty():
			continue
		out.append({
			"item_id": str(slot.get("item_id", "")),
			"quantity": int(slot.get("quantity", 0)),
			"quality": int(slot.get("quality", 100)),
		})
	return out


func _extract_from_container(node: ContainerNode, item_name: String, quantity: int) -> Dictionary:
	var cid := node.effective_container_id()
	var slots_v: Variant = _contents.get(cid, null)
	if slots_v == null:
		return {"ok": false, "message": "「%s」是空的" % node.effective_display_name()}
	var slots: Array[Dictionary] = slots_v
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
			var put_idx := _find_stackable_slot(slots, stack)
			if put_idx < 0:
				put_idx = _find_empty_slot(slots)
			if put_idx >= 0:
				if InventorySlotData.of(slots[put_idx]).is_empty():
					slots[put_idx] = stack.duplicate(true)
				else:
					slots[put_idx]["quantity"] = int(slots[put_idx].get("quantity", 0)) + qty
				Db.save_container_slot(cid, put_idx, slots[put_idx])
		return {"ok": false, "message": "「%s」里没有足够的「%s」" % [node.effective_display_name(), item_name]}
	_contents[cid] = slots
	return {"ok": true, "stacks": extracted}


func _place_stacks_into_container(node: ContainerNode, stacks: Array) -> Dictionary:
	var cid := node.effective_container_id()
	var slots_v: Variant = _contents.get(cid, null)
	if slots_v == null:
		_hydrate_contents(cid, node.slot_count)
		slots_v = _contents.get(cid, null)
	var slots: Array[Dictionary] = slots_v
	for stack_v in stacks:
		if typeof(stack_v) != TYPE_DICTIONARY:
			continue
		var stack: Dictionary = (stack_v as Dictionary).duplicate(true)
		# stacks 来源可能是 lua-built（spawn_item / craft outputs）；落 _contents 前归一。
		InventorySlotData.normalize(stack)
		# 同 character_inventory.add_instance：lua-built stack 没 base_effects 时从
		# template 兜底；然后 recompute displayed_effects。
		if stack.get("base_effects", null) == null:
			var tmpl: Item = Items.by_id(String(stack.get("item_id", "")))
			if tmpl != null and not tmpl.base_effects.is_empty():
				stack["base_effects"] = tmpl.base_effects.duplicate()
		ItemEffects.recompute_slot(stack)
		var remaining := int(stack.get("quantity", 0))
		if remaining <= 0:
			continue
		# 1) 先填可堆叠的现有槽
		for i in slots.size():
			if remaining <= 0:
				break
			var slot := slots[i]
			if InventorySlotData.of(slot).is_empty():
				continue
			if not InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(stack)):
				continue
			var room := Character.INVENTORY_STACK_MAX - int(slot.get("quantity", 0))
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
				_contents[cid] = slots
				return {"ok": false, "message": "「%s」装不下了" % node.effective_display_name()}
			var chunk := mini(remaining, Character.INVENTORY_STACK_MAX)
			var placed := stack.duplicate(true)
			placed["quantity"] = chunk
			slots[idx] = placed
			Db.save_container_slot(cid, idx, placed)
			remaining -= chunk
	_contents[cid] = slots
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


func _find_stackable_slot(slots: Array[Dictionary], stack: Dictionary) -> int:
	for i in slots.size():
		var slot := slots[i]
		if InventorySlotData.of(slot).is_empty():
			continue
		if InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(stack)):
			if int(slot.get("quantity", 0)) < Character.INVENTORY_STACK_MAX:
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
		var quality := int(entry.get("quality", 100))
		var stack := InventorySlotData.from_template(item_id, quality)
		stack["quantity"] = qty
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
