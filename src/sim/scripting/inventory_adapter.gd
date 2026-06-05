class_name InventoryAdapter
extends RefCounted

# 三种 inventory 后端的统一适配层。lua 端通过 affect.take_item / transfer_item /
# set_slot_state / world.find_items 操作的"holder"实际可能是：
#   Character        → 自身 inventory: Array[Dictionary] 字段
#   ContainerNode    → 自身 contents: Array[Dictionary] 节点属性（Containers autoload 维护）
#   ShelfNode        → 自身 listings: Array[Dictionary] 节点属性（**read-only**，写走 6.3）
#
# 共享 slot schema（Phase 1 平铺）：{ item_id, quantity, quality, shape_type, materials, tags,
#                     physics_props, container_amount, container_content,
#                     freshness_tier, freshness_age_hours, durability,
#                     base_effects, displayed_effects }
#
# Query schema（dict，所有字段全 AND）:
#   { item_id?, slot_index?, container_content?, min_quality? }
#   container_content 字段名对齐 slot.container_content 平铺列（原 content_id 已废弃）
#
# Adapter 是 RefCounted 临时对象 —— 每次 affect 调用 new 一份，用完即弃。
# 持久状态全在底层（Character.inventory / ContainerNode.contents / ShelfNode.listings / Db）。


# ─── 抽象方法（子类必须 override）─────────────────────────────────────

# 当前 slots 数组（read-only 视图；mutate 走 take/place/set_slot）
func slots() -> Array:
	push_error("InventoryAdapter.slots not implemented")
	return []


# 扣 qty 个匹配项，返回 { taken_qty, stacks: Array[Dictionary] }
# stacks 是已经从原 holder 抽出来的独立 dict（caller 可以 place 到别处）
func take(_query: Dictionary, _qty: int) -> Dictionary:
	push_error("InventoryAdapter.take not implemented")
	return { "taken_qty": 0, "stacks": [] }


# 把 stacks 塞进来，返回 { placed_qty, leftover: Array[Dictionary] }
# leftover 是塞不下的部分（caller 自己处理 rollback）
func place(_stacks: Array) -> Dictionary:
	push_error("InventoryAdapter.place not implemented")
	return { "placed_qty": 0, "leftover": [] }


# 改单 slot 字段（bulk dict，命名同 crop_state / farm_state 风格）
func set_slot(_slot_index: int, _fields: Dictionary) -> bool:
	push_error("InventoryAdapter.set_slot not implemented")
	return false


# 显示名（用于 effect summary / 报错）
func display_name() -> String:
	return "?"


# Holder 类型标签（adapter 用作 routing；lua 端读不到）
func kind() -> String:
	return "?"


# ─── Public helpers（不需 override）────────────────────────────────

# Query 匹配单 slot。empty slot 永远不匹配。
static func matches(slot: Dictionary, query: Dictionary) -> bool:
	if InventorySlotData.of(slot).is_empty():
		return false
	var item_id_q := str(query.get("item_id", ""))
	if not item_id_q.is_empty() and str(slot.get("item_id", "")) != item_id_q:
		return false
	# Aspect 平铺：直接读 slot.container_content（null 转空串后比较）。
	# query 字段统一用 container_content；transitional content_id 已删除（Phase 2）。
	var content_q := str(query.get("container_content", ""))
	if not content_q.is_empty():
		var actual_v: Variant = slot.get("container_content", null)
		var actual := "" if actual_v == null else str(actual_v)
		if actual != content_q:
			return false
	if query.has("min_quality"):
		if int(slot.get("quality", 0)) < int(query.get("min_quality", 0)):
			return false
	return true


# 按 query 找所有匹配 slot 的 [{slot_index, item_id, qty, quality, container_content}, ...]
# slot_index 在 query 里时只检查那一个槽。
func find(query: Dictionary) -> Array:
	var out: Array = []
	var ss: Array = slots()
	if query.has("slot_index"):
		var idx := int(query.get("slot_index", -1))
		if idx >= 0 and idx < ss.size() and matches(ss[idx], query):
			out.append(_summarize_slot(idx, ss[idx]))
		return out
	for i in ss.size():
		if matches(ss[i], query):
			out.append(_summarize_slot(i, ss[i]))
	return out


static func _summarize_slot(slot_index: int, slot: Dictionary) -> Dictionary:
	var content_v: Variant = slot.get("container_content", null)
	# 字段名 container_content 对齐 slot 平铺列；transitional content_id 已删（Phase 2）。
	return {
		"slot_index": slot_index,
		"item_id": str(slot.get("item_id", "")),
		"qty": int(slot.get("quantity", 0)),
		"quality": int(slot.get("quality", 100)),
		"container_content": "" if content_v == null else str(content_v),
	}


# ─── Factory ───────────────────────────────────────────────────────

# Holder 可以是任何 Object；不支持的类型返回 null。
static func for_holder(holder: Object) -> InventoryAdapter:
	if holder == null:
		return null
	if holder is Character:
		return _CharacterAdapter.new(holder as Character)
	# 货架（ShelfNode）是 ContainerNode 子类，走容器 adapter（slot 库存 + take/place/set_slot）。
	if holder is ContainerNode:
		return _ContainerAdapter.new(holder as ContainerNode)
	return null


# ─── Character adapter ────────────────────────────────────────────

class _CharacterAdapter extends InventoryAdapter:
	var _ch: Character

	func _init(ch: Character) -> void:
		_ch = ch

	func slots() -> Array:
		return _ch.inventory

	func display_name() -> String:
		return str(_ch.name)

	func kind() -> String:
		return "character"

	func take(query: Dictionary, qty: int) -> Dictionary:
		var remaining := maxi(qty, 0)
		var stacks: Array = []
		if remaining <= 0:
			return { "taken_qty": 0, "stacks": stacks }
		# 重复 find / extract 直到拿够。extract_stack 会从 slot 扣量并返回独立 dict。
		while remaining > 0:
			var matches_list := find(query)
			if matches_list.is_empty():
				break
			var first := matches_list[0] as Dictionary
			var idx := int(first.get("slot_index", -1))
			var have := int(first.get("qty", 0))
			if idx < 0 or have <= 0:
				break
			var take_n := mini(have, remaining)
			var stack := _ch.inventory_ops().extract_stack(idx, take_n)
			if stack.is_empty():
				break
			stacks.append(stack)
			remaining -= int(stack.get("quantity", 0))
		return { "taken_qty": qty - remaining, "stacks": stacks }

	func place(stacks: Array) -> Dictionary:
		var typed: Array[Dictionary] = []
		for s_v in stacks:
			if typeof(s_v) == TYPE_DICTIONARY:
				typed.append(s_v as Dictionary)
		var receipt := _ch.inventory_ops().receive_stacks(typed)
		if bool(receipt.get("ok", false)):
			var placed_qty := 0
			for s in typed:
				placed_qty += int(s.get("quantity", 0))
			return { "placed_qty": placed_qty, "leftover": [] }
		# 装不下：receive_inventory_stacks 已自己 rollback；leftover = 全部
		return { "placed_qty": 0, "leftover": typed }

	func set_slot(slot_index: int, fields: Dictionary) -> bool:
		if slot_index < 0 or slot_index >= _ch.inventory.size():
			return false
		var inv: Array[Dictionary] = _ch.inventory
		var slot: Dictionary = inv[slot_index].duplicate(true)
		for k in fields.keys():
			slot[str(k)] = fields[k]
		# lua-fields 经 LuaConv 可能把空 dict 字段塞成 Array；归一后再落 inventory。
		InventorySlotData.normalize(slot)
		# fields 可能改了 quality / freshness_tier / base_effects / materials —— 任何一项
		# 都可能让 displayed_effects 与现状漂移。在 persist 之前 recompute 一次保证一致。
		ItemEffects.recompute_slot(slot)
		inv[slot_index] = slot
		_ch.inventory = inv
		_ch.inventory_ops().persist_slot(slot_index)
		return true


# ─── Container adapter ────────────────────────────────────────────

class _ContainerAdapter extends InventoryAdapter:
	var _node: ContainerNode

	func _init(node: ContainerNode) -> void:
		_node = node

	func slots() -> Array:
		return Containers.adapter_slots(_node)

	func display_name() -> String:
		return _node.effective_display_name()

	func kind() -> String:
		return "container"

	func take(query: Dictionary, qty: int) -> Dictionary:
		return Containers.adapter_take(_node, query, qty)

	func place(stacks: Array) -> Dictionary:
		return Containers.adapter_place(_node, stacks)

	func set_slot(slot_index: int, fields: Dictionary) -> bool:
		return Containers.adapter_set_slot(_node, slot_index, fields)
