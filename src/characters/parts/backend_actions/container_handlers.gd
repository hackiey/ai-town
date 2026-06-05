class_name ContainerHandlers
extends RefCounted

# 容器/货架统一存取（put_take）：一次调用同时存入(put)和取出(take)。
# 货架 = 无锁容器。买卖走这里——投币换货：put 银币 + take 面包 = 一次成交，钱直接以
# 物品形式留在货架上（货架主之后自己 take 收钱）。
#
# 货币（silver_coin/gold_coin）特殊：角色身上存在钱包(centi)，不是背包物品；容器/货架里存为
# item 实体（金库就是这么存的）。所以在「角色 ↔ 容器」边界做转换：
#   put 货币 → 从钱包扣 centi，往容器塞等额 coin 物品
#   take 货币 → 从容器取 coin 物品，按等额加进钱包
# 非货币物品走背包 ↔ 容器槽位的常规搬运（保留 quality/aspect）。
#
# 标价（仅货架，price_silver）仍由 put 项携带：put 成功后给该物品所有槽位盖 listing_price_centi。
# 标价只是展示参考，不强制扣钱——付不付钱由买家用 put 银币体现。


# target: { containerId, put:[{itemId, quantity, actorSlotIndex?, priceCenti?}], take:[{itemId, quantity, containerSlotIndex?}] }
static func run_put_take(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "put_take target must be object"}
	var t: Dictionary = target as Dictionary
	var container_input := str(t.get("containerId", "")).strip_edges()
	if container_input.is_empty():
		return {"ok": false, "message": "put_take 缺少 containerId"}
	if Containers == null:
		return {"ok": false, "message": "Containers autoload is unavailable"}
	var resolution := Containers.resolve_for_actor(character, container_input)
	var node: ContainerNode = resolution.get("node") as ContainerNode
	if node == null:
		return {"ok": false, "message": str(resolution.get("message", "找不到容器"))}
	if not bool(resolution.get("ok", false)):
		# 距离 / 钥匙不过（group 已不再闸门）。
		return {"ok": false, "message": str(resolution.get("message", "无法操作该容器"))}

	var cid := str(resolution.get("container_id", ""))
	var cname := str(resolution.get("container_name", container_input))
	var is_shelf := node is ShelfNode
	var raw_put: Array = t.get("put", []) if typeof(t.get("put", [])) == TYPE_ARRAY else []
	var raw_take: Array = t.get("take", []) if typeof(t.get("take", [])) == TYPE_ARRAY else []
	if raw_put.is_empty() and raw_take.is_empty():
		return {"ok": false, "message": "没有指定要存入或取出的物品"}

	var put_moves: Array = []
	var take_moves: Array = []
	var lines: Array = []

	# 先取后存：腾出空间再放。
	for entry_v in raw_take:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var moved := _do_take(character, node, cid, cname, entry_v as Dictionary, lines)
		if moved.get("itemId", "") != "" and int(moved.get("quantity", 0)) > 0:
			take_moves.append(moved)

	for entry_v in raw_put:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var moved := _do_put(character, node, cid, cname, is_shelf, entry_v as Dictionary, lines)
		if moved.get("itemId", "") != "" and int(moved.get("quantity", 0)) > 0:
			put_moves.append(moved)

	if put_moves.is_empty() and take_moves.is_empty():
		return {"ok": false, "message": "；".join(lines) if not lines.is_empty() else "没有可存取的内容"}

	# 单条 world_event：附近的人感知"谁往这个货架/容器存取了什么"。
	character.emit_world_event("container_put_take", {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"containerId": cid,
		"puts": put_moves,
		"takes": take_moves,
	})

	var msg_lines: Array = ["在「%s」：" % cname]
	for l in lines:
		msg_lines.append("  " + str(l))
	return {
		"ok": true,
		"message": "\n".join(msg_lines),
		"result": {"containerId": cid, "put": put_moves, "taken": take_moves},
	}


# 从容器/货架取出一项 → 加进角色（货币入钱包，其他入背包）。返回 {itemId, quantity} 实际取出量。
static func _do_take(character: Character, node: ContainerNode, cid: String, cname: String, entry: Dictionary, lines: Array) -> Dictionary:
	var item_id := str(entry.get("itemId", "")).strip_edges()
	var qty := int(entry.get("quantity", 0))
	if item_id.is_empty() or qty <= 0:
		return {}
	var item_name := character.localize_item_name(item_id)
	var unit_centi := CharacterInventory.currency_item_centi(item_id)
	var res := Containers.system_withdraw(cid, item_id, qty)
	if not bool(res.get("ok", false)):
		lines.append("「%s」里没有「%s」" % [cname, item_name])
		return {}
	var stacks := _as_dict_array(res.get("stacks", []))
	var moved := _sum_qty(stacks)
	if moved <= 0:
		lines.append("「%s」里没有「%s」" % [cname, item_name])
		return {}
	if unit_centi > 0:
		# 货币：取出的 coin 物品折算进钱包，不进背包。
		character.wallet_add(moved * unit_centi)
	else:
		var recv := character.inventory_ops().receive_stacks(stacks)
		if not bool(recv.get("ok", false)):
			# 背包装不下 → 原样放回容器。
			Containers.adapter_place(node, stacks)
			lines.append("背包装不下「%s」" % item_name)
			return {}
	var tail := "（只剩这些）" if moved < qty else ""
	lines.append("取出 %d 份「%s」%s" % [moved, item_name, tail])
	return {"itemId": item_id, "quantity": moved}


# 把角色的物品存进容器/货架（货币从钱包出 → 容器塞 coin 物品；其他从背包出）。返回 {itemId, quantity}。
static func _do_put(character: Character, node: ContainerNode, cid: String, cname: String, is_shelf: bool, entry: Dictionary, lines: Array) -> Dictionary:
	var item_id := str(entry.get("itemId", "")).strip_edges()
	var qty := int(entry.get("quantity", 0))
	if item_id.is_empty() or qty <= 0:
		return {}
	var item_name := character.localize_item_name(item_id)
	var unit_centi := CharacterInventory.currency_item_centi(item_id)
	var moved := 0
	if unit_centi > 0:
		# 货币：从钱包扣等额 centi，往容器塞 coin 物品（全有或全无）。
		var centi := qty * unit_centi
		var pay := character.inventory_ops().pay_centi(centi)
		if not bool(pay.get("ok", false)):
			lines.append(str(pay.get("message", "钱不够")))
			return {}
		var dep := Containers.system_deposit(cid, item_id, qty)
		if not bool(dep.get("ok", false)):
			# 容器塞不下 → 退钱。
			character.inventory_ops().refund_centi(centi)
			lines.append("「%s」装不下「%s」" % [cname, item_name])
			return {}
		moved = qty
	else:
		# 非货币：从背包按 item_id 提取（最多 available），放进容器；放不下的退回背包。
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
			lines.append("「%s」装不下「%s」" % [cname, item_name])
			return {}
	# 标价（仅货架）：put 成功后给该物品所有槽位盖 listing_price_centi。
	if is_shelf and entry.has("priceCenti"):
		Containers.set_price_for_item(node, item_id, int(entry.get("priceCenti", 0)))
	var tail := "（你只有这些）" if moved < qty else ""
	lines.append("存入 %d 份「%s」%s" % [moved, item_name, tail])
	return {"itemId": item_id, "quantity": moved}


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
