class_name CharacterInventory
extends RefCounted

const Money = preload("res://src/sim/characters/money.gd")

# Character 的固定槽背包操作收口。设计：
# - **数据 (`inventory: Array[Dictionary]`) 仍住在 Character 上**：Player 的
#   MultiplayerSynchronizer 监听这个属性，移走会断 owner 同步。helper 直接操作
#   `character.inventory[i]`，写完 `character.inventory = character.inventory`
#   触发 synchronizer 这套约定不变。
# - 本类只搬走"行为"——add/remove/count/spoilage/remerge/get/snapshot。
# - 常量 `INVENTORY_SLOT_COUNT / INVENTORY_STACK_MAX / ITEM_DEFAULT_QUALITY` 仍留
#   Character（Player.gd / WorkstationActionRunner 等用 `Character.ITEM_DEFAULT_QUALITY`）。

var character: Character

# 1 silver_coin = 100 centi（wallet 内部精度）
# 1 gold_coin = 10 silver = 1000 centi
const SILVER_COIN_CENTI := 100
const GOLD_COIN_CENTI := 1000
const GOLD_COIN_SILVER_VALUE := 10  # 留作 legacy 名（minting / display 还引用）


func _init(owner: Character) -> void:
	character = owner


# silver_coin / gold_coin 不在 inventory，直接进 wallet。返回该 item 每件等价 centi；
# 非货币 item 返回 0。caller 用这个判断是否走 wallet 路径。
static func currency_item_centi(item_id: String) -> int:
	if item_id == "silver_coin":
		return SILVER_COIN_CENTI
	if item_id == "gold_coin":
		return GOLD_COIN_CENTI
	return 0


# 初始化 INVENTORY_SLOT_COUNT 个空 slot。Character._ready 时调一次。
func init_slots() -> void:
	character.inventory.clear()
	for i in Character.INVENTORY_SLOT_COUNT:
		character.inventory.append(InventorySlotData.empty())


# Server-only：从 Db cache 灌已持久化的 inventory slot。返回是否拿到任何行。
# 首次开服的起始背包由 Db seed 写入 item_instances；运行时这里只负责 hydrate。
# 即使全空（已经被吃光）也不重新发起始包。
func hydrate_from_db() -> bool:
	if not RunMode.is_runtime():
		return false
	var cid := character.backend_character_id()
	if cid.is_empty():
		return false
	var slots: Dictionary = Db.take_inventory(cid)
	if slots.is_empty():
		return false
	var inv: Array[Dictionary] = character.inventory
	for k in slots.keys():
		var idx := int(k)
		if idx < 0 or idx >= inv.size():
			continue
		inv[idx] = InventorySlotData.normalize(slots[k] as Dictionary)
	character.inventory = inv  # 触发 synchronizer
	return true


# 把指定 slot 写回 Db；空 slot → DELETE 行。给 add/remove 操作完后调。
# Public 形式供外部直写 inventory 的路径（player.swap_slots / workstation pour /
# well_draw 等）显式调用——它们绕过 add_item / remove_item，需要自己触发持久化。
func persist_slot(slot_index: int) -> void:
	if not RunMode.is_runtime():
		return
	var cid := character.backend_character_id()
	if cid.is_empty():
		return
	if slot_index < 0 or slot_index >= character.inventory.size():
		return
	Db.save_inventory_slot(cid, slot_index, character.inventory[slot_index])


# 内部使用别名，让 add_instance / remove_item 等内部方法保留 _persist_slot 名称
func _persist_slot(slot_index: int) -> void:
	persist_slot(slot_index)


# 便捷入口：按 item_id + quality 加。从 template 派生 shape_type/materials/tags，
# 再走 add_instance 统一逻辑。Crop harvest / 起始包 / /give 都走这里。
func add_item(item_id: String, quantity: int, quality: int = Character.ITEM_DEFAULT_QUALITY) -> int:
	if item_id.is_empty() or quantity <= 0:
		return quantity
	# 货币 item 直接进 wallet，不占 inventory slot
	var coin_centi := currency_item_centi(item_id)
	if coin_centi > 0:
		character.wallet_add(coin_centi * quantity)
		return 0
	var q := clampi(quality, 1, 100)
	var inst := InventorySlotData.from_template(item_id, q)
	return add_instance(inst, quantity)


# 加一个完整 instance（dispatcher 给的 crafted item 走这里）。
# stack 等价规则：item_id + quality + shape_type + materials + tags + properties 全等。
# 返回未放下的数量。
func add_instance(instance: Dictionary, quantity: int) -> int:
	assert(RunMode.is_runtime(), "add_instance must be called on the runtime server")
	if instance.get("item_id", "") == "" or quantity <= 0:
		return quantity
	# 货币 item 直接进 wallet，不占 inventory slot
	var coin_centi := currency_item_centi(String(instance.get("item_id", "")))
	if coin_centi > 0:
		character.wallet_add(coin_centi * quantity)
		return 0
	# lua 端送来的 instance 可能 properties/materials 是空 Array（LuaConv 默认）；
	# 归一一次保证后续 equals_stackable_with / 写入都用 schema 类型。
	InventorySlotData.normalize(instance)
	# Reaction generate 在 lua 端不算 base_effects（crafting.lua 输出 dict 不带）；
	# 这里从 template 兜底（食物类 .tres 上配 base_effects），然后算 displayed_effects。
	# 已显式带 base_effects 的 instance（debug / 未来动态食物）不覆盖。
	if instance.get("base_effects", null) == null:
		var tmpl: Item = Items.by_id(String(instance.get("item_id", "")))
		if tmpl != null and not tmpl.base_effects.is_empty():
			instance["base_effects"] = tmpl.base_effects.duplicate()
	ItemEffects.recompute_slot(instance)
	var inv: Array[Dictionary] = character.inventory
	var remaining := quantity
	var touched: Array[int] = []
	# 1. 先填可 stack 的现有槽
	for i in inv.size():
		if remaining <= 0:
			break
		var slot: Dictionary = inv[i]
		if not InventorySlotData.of(slot).equals_stackable_with(InventorySlotData.of(instance)):
			continue
		var room := Character.INVENTORY_STACK_MAX - int(slot["quantity"])
		if room <= 0:
			continue
		var put := mini(room, remaining)
		slot["quantity"] = int(slot["quantity"]) + put
		inv[i] = slot
		remaining -= put
		touched.append(i)
	# 2. 找空槽建新 stack
	for i in inv.size():
		if remaining <= 0:
			break
		var slot: Dictionary = inv[i]
		if String(slot.get("item_id", "")) != "":
			continue
		var put := mini(Character.INVENTORY_STACK_MAX, remaining)
		# 合并到 InventorySlotData.empty() 模板，保证所有 schema 字段齐全（即使 caller 只填了 item_id）
		var new_slot := InventorySlotData.empty()
		for k in instance.keys():
			new_slot[k] = instance[k]
		new_slot["quantity"] = put
		inv[i] = new_slot
		remaining -= put
		touched.append(i)
	# Array[Dictionary] 是按引用持有；slot 修改完别忘 reassign，触发 synchronizer changed
	character.inventory = inv
	for idx in touched:
		_persist_slot(idx)
	return remaining


# 从指定槽减 quantity；减完归空槽。返回实际移除数（< quantity 表示槽里不够）。
func remove_item(slot_index: int, quantity: int) -> int:
	assert(RunMode.is_runtime(), "remove_item must be called on the runtime server")
	var inv: Array[Dictionary] = character.inventory
	if slot_index < 0 or slot_index >= inv.size() or quantity <= 0:
		return 0
	var slot: Dictionary = inv[slot_index]
	var have := int(slot.get("quantity", 0))
	if have <= 0:
		return 0
	var taken := mini(have, quantity)
	var left := have - taken
	if left <= 0:
		inv[slot_index] = InventorySlotData.empty()
	else:
		slot["quantity"] = left
		inv[slot_index] = slot
	character.inventory = inv
	_persist_slot(slot_index)
	return taken


# Count 默认跨所有 quality 加总。需要按品质过滤可显式传 quality 参数。
func count_item(item_id: String, quality: int = -1) -> int:
	if item_id.is_empty():
		return 0
	# 货币 item 不占 slot，从 wallet 推算"等值整币数"（向下取整）
	var coin_centi := currency_item_centi(item_id)
	if coin_centi > 0:
		return character.wallet_centi / coin_centi
	var total := 0
	for slot in character.inventory:
		if slot["item_id"] != item_id:
			continue
		if quality >= 0 and int(slot.get("quality", 0)) != quality:
			continue
		total += int(slot["quantity"])
	return total


# 工具用一次掉一点耐久。template.properties.max_durability 决定上限；
# slot.durability（平铺列）是当前剩余（null = 全新工具，回退到 max）。
# 减到 0 整把工具报废，slot 清空。返回 {broke, remaining, max, item_id}；
# max=0 表示该 item 不计耐久，本次不动数据。
func decrement_tool_durability(slot_index: int, amount: int = 1) -> Dictionary:
	assert(RunMode.is_runtime(), "decrement_tool_durability must run on server")
	var inv: Array[Dictionary] = character.inventory
	if slot_index < 0 or slot_index >= inv.size():
		return {"broke": false, "remaining": 0, "max": 0, "item_id": ""}
	var slot: Dictionary = inv[slot_index]
	if int(slot.get("quantity", 0)) <= 0:
		return {"broke": false, "remaining": 0, "max": 0, "item_id": ""}
	var item_id := String(slot.get("item_id", ""))
	var view := InventorySlotData.of(slot)
	var dura := view.as_durability()
	if dura == null:
		return {"broke": false, "remaining": 0, "max": 0, "item_id": item_id}
	var max_dur := dura.max_value()
	var new_dur := dura.with_decremented(maxi(0, amount))
	if new_dur <= 0:
		inv[slot_index] = InventorySlotData.empty()
		character.inventory = inv
		_persist_slot(slot_index)
		return {"broke": true, "remaining": 0, "max": max_dur, "item_id": item_id}
	slot["durability"] = new_dur
	# durability 当前不影响 displayed_effects 计算（公式只用 quality + freshness），
	# 但留接口给未来"破损工具效果衰减"那类 lua compute_effects 用——保证字段链一致。
	ItemEffects.recompute_slot(slot)
	inv[slot_index] = slot
	character.inventory = inv
	_persist_slot(slot_index)
	return {"broke": false, "remaining": new_dur, "max": max_dur, "item_id": item_id}


# 按 item_id 找第一把该工具扣 1 点耐久。给不知道 slot_index 的 caller 用（如农事铲除）。
func decrement_tool_durability_by_id(item_id: String, amount: int = 1) -> Dictionary:
	if item_id.is_empty():
		return {"broke": false, "remaining": 0, "max": 0, "item_id": item_id}
	var inv: Array[Dictionary] = character.inventory
	for i in inv.size():
		if String(inv[i].get("item_id", "")) == item_id and int(inv[i].get("quantity", 0)) > 0:
			return decrement_tool_durability(i, amount)
	return {"broke": false, "remaining": 0, "max": 0, "item_id": item_id}


# 找到第一个装有 item_id 且非空的 stack 扣 1。返回是否扣成功。
# 给消耗品（草木灰、种子等）用：调用方先用 count_item 校验存在再调这个。
func consume_one(item_id: String) -> bool:
	var inv: Array[Dictionary] = character.inventory
	for i in inv.size():
		var s: Dictionary = inv[i]
		if s["item_id"] == item_id and int(s["quantity"]) > 0:
			remove_item(i, 1)
			return true
	return false


# 从背包里的水容器扣指定水量。bucket 不消耗（quantity 不动），只动 properties.amount/content。
# 默认扣 1 点；整片浇水会一次扣 20 点。支持跨多个水桶拼够总量。
# 返回 { ok, message, reason }；reason 取值: no_container | empty | other_liquid | insufficient。
func consume_water_amount(amount: float = 1.0, consume: bool = true) -> Dictionary:
	var required := maxf(0.0, amount)
	if required <= 0.0:
		return {"ok": true, "consumed": 0.0}
	var inv: Array[Dictionary] = character.inventory
	var saw_container := false
	var saw_other := false
	var total_water := 0.0
	var water_slots: Array[Dictionary] = []
	for i in inv.size():
		var slot: Dictionary = inv[i]
		var view := InventorySlotData.of(slot)
		if view.is_empty():
			continue
		var tmpl := view.template()
		var has_liquid_tag := view.has_tag("liquid_container") \
			or (tmpl != null and "liquid_container" in tmpl.tags)
		if not has_liquid_tag:
			continue
		var container := view.as_container()
		if container == null:
			continue
		saw_container = true
		if container.is_empty():
			continue
		if container.content_id() != "water":
			saw_other = true
			continue
		var amount_available := container.amount()
		if amount_available <= 0.0:
			continue
		total_water += amount_available
		water_slots.append({
			"slot_index": i,
			"slot": slot,
			"amount": amount_available,
		})
	if not saw_container:
		return {"ok": false, "reason": "no_container", "message": "背包里没有水桶"}
	if total_water >= required:
		if not consume:
			return {"ok": true, "consumed": required}
		var remaining := required
		var touched: Array[int] = []
		for entry_v in water_slots:
			var entry: Dictionary = entry_v
			var slot_index := int(entry.get("slot_index", -1))
			if slot_index < 0 or slot_index >= inv.size():
				continue
			var slot: Dictionary = inv[slot_index]
			var container := InventorySlotData.of(slot).as_container()
			if container == null or container.content_id() != "water":
				continue
			var take := minf(container.amount(), remaining)
			if take <= 0.0:
				continue
			var fields := container.with_consumed(take)
			slot["container_amount"] = fields["container_amount"]
			slot["container_content"] = fields["container_content"]
			inv[slot_index] = slot
			remaining -= take
			touched.append(slot_index)
			if remaining <= 0.0001:
				break
		character.inventory = inv  # 触发 synchronizer
		for idx in touched:
			_persist_slot(idx)
		return {"ok": true, "consumed": required}
	if saw_other:
		return {"ok": false, "reason": "other_liquid", "message": "水桶里装的不是水"}
	if total_water > 0.0:
		return {
			"ok": false,
			"reason": "insufficient",
			"message": "水不够（需要 %d 点，当前只有 %d 点）" % [
				int(round(required)),
				int(round(total_water)),
			],
		}
	return {"ok": false, "reason": "empty", "message": "水桶是空的，先去打水"}


func consume_water_unit() -> Dictionary:
	return consume_water_amount(1.0)


# 每 game-hour 给所有 perishable slot 走一次 tier 衰减。
# 规则（tier 步长 / age 累积 / tier=0 swap rotten）在 data/mechanics/perishable.lua。
# GDScript 这里只做"找 perishable slot + 预查 rotten template + 调 lua + remerge"。
func tick_spoilage() -> void:
	if not RunMode.is_runtime():
		return
	var inv: Array[Dictionary] = character.inventory
	var changed := false
	for i in inv.size():
		var slot: Dictionary = inv[i]
		if int(slot.get("quantity", 0)) <= 0:
			continue
		var perishable := PerishableAspect.of(slot)
		if perishable == null or perishable.is_rotten() or perishable.tier() <= 0:
			continue
		var body_id := str((slot.get("materials", {}) as Dictionary).get("body", ""))
		var mat: Substance = Materials.by_id(body_id)
		if mat == null or mat.shelf_life_hours <= 0.0:
			continue
		# 预查 rotten 目标（lua 不能查 Items registry）
		var rotten_swap: Variant = null
		var rotten_id := str(mat.rotten_into)
		if rotten_id.is_empty():
			rotten_id = "rotten_food"
		var rotten_template_id := Items.find_template("lump", rotten_id)
		if rotten_template_id.is_empty():
			rotten_template_id = "rotten_food"
		var rotten_tmpl: Item = Items.by_id(rotten_template_id)
		if rotten_tmpl != null:
			rotten_swap = {
				"item_id": rotten_template_id,
				"materials": { "body": rotten_id },
				"shape_type": rotten_tmpl.shape_type,
				"tags": Array(rotten_tmpl.tags),
			}
		MechanicHost.invoke("perishable", "on_age", {
			"holder": character,
			"slot_index": i,
			"slot": slot,
			"shelf_life_hours": mat.shelf_life_hours,
			"rotten_swap": rotten_swap,
			"hours": 1.0,
		})
		changed = true
	if changed:
		# spoilage 改完后可能 stack 重复（tier 一致 / 多份 rotten_food）→ remerge + persist
		var inv_after: Array[Dictionary] = character.inventory
		_remerge(inv_after)
		character.inventory = inv_after
		for i in inv_after.size():
			_persist_slot(i)


# tier 降级或 swap 后，原本不同 tier 的 stack 可能变得"同 tier 同 key" → 合并到前面。
# 同时把 swap 后的多份 rotten_food 也合并到一起。
func _remerge(inv: Array[Dictionary]) -> void:
	for i in inv.size():
		var src: Dictionary = inv[i]
		if int(src.get("quantity", 0)) <= 0:
			continue
		for j in range(i):
			var dst: Dictionary = inv[j]
			if int(dst.get("quantity", 0)) <= 0:
				continue
			if not InventorySlotData.of(dst).equals_stackable_with(InventorySlotData.of(src)):
				continue
			var room := Character.INVENTORY_STACK_MAX - int(dst["quantity"])
			if room <= 0:
				continue
			var move := mini(room, int(src["quantity"]))
			dst["quantity"] = int(dst["quantity"]) + move
			src["quantity"] = int(src["quantity"]) - move
			inv[j] = dst
			if int(src["quantity"]) <= 0:
				inv[i] = InventorySlotData.empty()
				break
			else:
				inv[i] = src


func get_slot(slot_index: int) -> Dictionary:
	if slot_index < 0 or slot_index >= character.inventory.size():
		return InventorySlotData.empty()
	return (character.inventory[slot_index] as Dictionary).duplicate(true)


func find_matching_slot_indices(item_name: String) -> PackedInt32Array:
	var wanted := _normalize_item_query(item_name)
	var out := PackedInt32Array()
	if wanted.is_empty():
		return out
	for i in character.inventory.size():
		var slot: Dictionary = character.inventory[i]
		var view := InventorySlotData.of(slot)
		if view.is_empty():
			continue
		var candidates := [
			view.id(),
			view.display_name(),
			tr("item.%s.name" % view.id()),
		]
		for candidate_v in candidates:
			var candidate := _normalize_item_query(str(candidate_v))
			if candidate.is_empty():
				continue
			if candidate == wanted:
				out.append(i)
				break
	return out


func extract_stack(slot_index: int, quantity: int) -> Dictionary:
	if slot_index < 0 or slot_index >= character.inventory.size() or quantity <= 0:
		return {}
	var slot: Dictionary = character.inventory[slot_index]
	var have := int(slot.get("quantity", 0))
	if have <= 0:
		return {}
	var take := mini(have, quantity)
	var extracted := slot.duplicate(true)
	extracted["quantity"] = take
	var removed := remove_item(slot_index, take)
	if removed != take:
		return {}
	return extracted


func extract_named_item_from_single_stack(item_name: String, quantity: int) -> Dictionary:
	var indices := find_matching_slot_indices(item_name)
	for slot_index in indices:
		var slot := get_slot(slot_index)
		if int(slot.get("quantity", 0)) < quantity:
			continue
		var extracted := extract_stack(slot_index, quantity)
		if extracted.is_empty():
			continue
		return {
			"ok": true,
			"slot_index": slot_index,
			"stack": extracted,
		}
	return {
		"ok": false,
		"message": "背包里没有足够的 %s" % item_name,
	}


func extract_item_id_across_stacks(item_id: String, quantity: int) -> Dictionary:
	if item_id.is_empty() or quantity <= 0:
		return {"ok": false, "message": "无效的物品提取请求"}
	var remaining := quantity
	var extracted: Array[Dictionary] = []
	for i in character.inventory.size():
		if remaining <= 0:
			break
		var slot := get_slot(i)
		if String(slot.get("item_id", "")) != item_id:
			continue
		var take := mini(int(slot.get("quantity", 0)), remaining)
		if take <= 0:
			continue
		var stack := extract_stack(i, take)
		if stack.is_empty():
			continue
		extracted.append(stack)
		remaining -= take
	if remaining <= 0:
		return {"ok": true, "stacks": extracted}
	restore_extracted_stacks(extracted)
	return {
		"ok": false,
		"message": "背包里没有足够的 %s" % item_id,
	}


func pay_centi(centi: int) -> Dictionary:
	if centi < 0:
		return {"ok": false, "message": "货币金额不能为负数"}
	if centi == 0:
		return {"ok": true, "centi": 0}
	if not character.wallet_spend(centi):
		return {
			"ok": false,
			"message": "钱包余额不足（需要 %s，有 %s）" % [
				Money.format_silver_from_centi(centi),
				Money.format_silver_from_centi(character.wallet_centi),
			],
		}
	return {"ok": true, "centi": centi}


func refund_centi(centi: int) -> void:
	if centi <= 0:
		return
	character.wallet_add(centi)


func remove_matching_instance(instance: Dictionary, quantity: int) -> int:
	if quantity <= 0:
		return 0
	var wanted := InventorySlotData.of(instance)
	var remaining := quantity
	var removed := 0
	for i in character.inventory.size():
		if remaining <= 0:
			break
		var slot: Dictionary = character.inventory[i]
		var view := InventorySlotData.of(slot)
		if view.is_empty() or not view.equals_stackable_with(wanted):
			continue
		var take := mini(view.quantity(), remaining)
		if take <= 0:
			continue
		removed += remove_item(i, take)
		remaining -= take
	return removed


func receive_stacks(stacks: Array[Dictionary]) -> Dictionary:
	var added: Array[Dictionary] = []
	for stack in stacks:
		var qty := int(stack.get("quantity", 0))
		if qty <= 0:
			continue
		var inst := stack.duplicate(true)
		inst["quantity"] = qty
		var leftover := add_instance(inst, qty)
		if leftover > 0:
			rollback_received_stacks(added)
			return {
				"ok": false,
				"message": "背包装不下 %s x%d" % [
					InventorySlotData.of(inst).display_name(),
					qty,
				],
			}
		added.append(inst)
	return {
		"ok": true,
		"stacks": added,
	}


func rollback_received_stacks(stacks: Array[Dictionary]) -> void:
	for index in range(stacks.size() - 1, -1, -1):
		var stack := stacks[index]
		var qty := int(stack.get("quantity", 0))
		if qty <= 0:
			continue
		remove_matching_instance(stack, qty)


func restore_extracted_stacks(stacks: Array[Dictionary]) -> void:
	for stack in stacks:
		var qty := int(stack.get("quantity", 0))
		if qty <= 0:
			continue
		var inst := stack.duplicate(true)
		inst["quantity"] = qty
		var leftover := add_instance(inst, qty)
		if leftover > 0:
			push_warning("[CharacterInventory] rollback restore overflow: %s x%d leftover=%d" % [
				InventorySlotData.of(inst).display_name(),
				qty,
				leftover,
			])


func _normalize_item_query(value: String) -> String:
	var out := value.strip_edges().to_lower()
	if out.is_empty():
		return out
	var detail_index := out.find("（")
	if detail_index > 0:
		out = out.substr(0, detail_index).strip_edges()
	detail_index = out.find("(")
	if detail_index > 0:
		out = out.substr(0, detail_index).strip_edges()
	var quantity_index := out.rfind(" x")
	if quantity_index > 0:
		out = out.substr(0, quantity_index).strip_edges()
	return out


# Context snapshot helper：上报 backend 用，过滤空槽。
# 每个 slot 通过 InventorySlotData.to_backend_dict() 渲染（含 displayName / kind /
# qualityTier / descriptionParts），单一来源，UI tooltip 和 agent context 看到同一份口径。
func backpack_items() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for slot in character.inventory:
		var view := InventorySlotData.of(slot)
		if view.is_empty():
			continue
		items.append(view.to_backend_dict())
	return items
