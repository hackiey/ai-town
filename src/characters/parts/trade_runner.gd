class_name TradeRunner
extends RefCounted

# 交易撮合状态机。Character 级 service —— 由 character.trade_runner() 懒加载暴露。
# 不持有 BackendActionRunner 反向引用；pending 状态通过 completion: Callable 跟 dispatcher 解耦。
#
# 入口：
# - run_offer / run_respond 是 backend action handler 调入口（取 completion 回 runner.finish）
# - trade_create / trade_respond 是 lua affect.trade_op 调入口（无 completion，pure RPC）
# - cancel_incoming_offers_as_seller 由 character 走路时调（也是 lua / move handler 入口）
#
# 跨角色：seller.trade_runner() 撮合完调 buyer.trade_runner().resolve_pending(...)。

var _character: Character
var _pending: Dictionary = {}


func _init(owner: Character) -> void:
	_character = owner


func has_pending() -> bool:
	return not _pending.is_empty()


# offer 统一了"单向赠送"和"议价交易"两种语义：request:[] 时走 _run_give 同步立即返回；
# request 非空时走原 trade.lua on_offer 创建 trade_offers 行，阻塞等对方 respond(kind:"trade")。
# completion 仅 deferred 路径用：resolve_pending 时 fire 回 runner.finish。
func run_offer(action_request: Dictionary, completion: Callable) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "offer target must be object"}
	var t: Dictionary = target as Dictionary
	var recipient_id := str(t.get("characterId", "")).strip_edges()
	var offer := _trade_lines_from_value(t.get("offer", []))
	if not bool(offer.get("ok", false)):
		return {"ok": false, "message": str(offer.get("message", "offer 解析失败"))}
	var request := _trade_lines_from_value(t.get("request", []))
	if not bool(request.get("ok", false)):
		return {"ok": false, "message": str(request.get("message", "request 解析失败"))}
	var offer_lines: Array = offer.get("lines", []) as Array
	var request_lines: Array = request.get("lines", []) as Array
	# request:[] 短路到 _run_give —— 单向赠送不写 trade_offers / 不阻塞 / 不需要对方 respond。
	if request_lines.is_empty():
		return _run_give(recipient_id, offer_lines)
	var mech := MechanicVerb.resolve("trade", {
		"actor": _character,
		"buyer_id": _character.backend_character_id(),
		"seller_id": recipient_id,
		"offer": offer_lines,
		"request": request_lines,
	}, "on_offer")
	if not bool(mech.get("ok", false)):
		return mech
	var result_v: Variant = mech.get("result", null)
	var result_d: Dictionary = result_v as Dictionary if typeof(result_v) == TYPE_DICTIONARY else {}
	var trade_id := str(result_d.get("trade_id", ""))
	if trade_id.is_empty():
		return {"ok": false, "message": "trade_create 未返回 trade_id"}
	# Pending：买家 action 保持 active 等卖家 respond。resolve_pending 撮合后 fire completion → runner.finish。
	_pending = {"trade_id": trade_id, "completion": completion}
	return {"ok": true, "pending": true}


# respond 按 kind dispatch。目前只支持 kind="trade"（回应 offer 议价）；未来扩 kind 时
# 加 match case + 对应的新 lua mechanic 文件，tool name 不再变。respond 是即时操作，
# 不阻塞 caller，所以不需 completion。
func run_respond(action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "respond target must be object"}
	var t: Dictionary = target as Dictionary
	var kind := str(t.get("kind", "")).strip_edges()
	if kind.is_empty():
		return {"ok": false, "message": "respond 缺少 kind 字段"}
	match kind:
		"trade":
			return _run_respond_trade(t)
		_:
			return {"ok": false, "message": "respond 不支持 kind '%s'，当前仅支持 'trade'" % kind}


# Lua affect.trade_op 调入口。create = 仅创 Db row + refresh contexts；
# respond = 完整撮合（accept/reject）含转账 / 货架消费 / status 更新。
# 不发 world_event —— 那由 lua return 走 MechanicVerb 自动发。
func trade_create(seller_id: String, offer: Array, request: Array) -> Dictionary:
	var buyer_id := _character.backend_character_id()
	if seller_id.is_empty():
		return {"ok": false, "message": "缺少交易对象"}
	if seller_id == buyer_id:
		return {"ok": false, "message": "不能和自己交易"}
	var seller_node := _character.find_other_character(seller_id)
	if seller_node == null:
		return {"ok": false, "message": "找不到交易对象 %s" % seller_id}
	# 状态门槛：睡觉时不接受交易请求。在 Godot 层拒绝，event 根本不会发出去。
	if seller_node.sleep_controller().is_sleeping():
		return {"ok": false, "message": "%s 正在睡觉，无法发起交易" % seller_id}
	# 距离门槛：面对面交易，复用 CharacterPerception 的 "near" 阈值。
	var radius := CharacterPerception.CHARACTER_NEAR_RADIUS
	var dist_sq := _character.global_position.distance_squared_to(seller_node.global_position)
	if dist_sq > radius * radius:
		return {
			"ok": false,
			"message": "距离不够，需要走到 %s 旁边（%.0f 米内）才能发起交易" % [seller_id, radius],
		}
	var existing := Db.find_pending_trade_for_pair(buyer_id, seller_id)
	if not existing.is_empty():
		return {"ok": false, "message": "已经有一笔待回应的交易，请等对方处理"}
	var offer_lines := _normalize_trade_lines(offer)
	var request_lines := _normalize_trade_lines(request)
	var trade := Db.create_trade_offer(buyer_id, seller_id, offer_lines, request_lines)
	if trade.is_empty():
		return {"ok": false, "message": "创建交易报价失败"}
	_refresh_trade_contexts(trade)
	# 选择性打断：若卖家正在 move_to_location，让对方腿停下来正面交易请求；其他身体动作
	# （农事/工作台/睡觉/idle）不动，由对方 LLM 自决。
	_interrupt_seller_walk_for_offer(seller_id, buyer_id)
	return {
		"ok": true,
		"trade_id": str(trade.get("trade_id", "")),
		"buyer_id": buyer_id,
		"seller_id": seller_id,
		"offer": offer_lines,
		"request": request_lines,
		"trade": trade,
	}


func trade_respond(trade_id: String, response: String) -> Dictionary:
	if trade_id.is_empty():
		return {"ok": false, "message": "缺少 trade_id"}
	if response != "accept" and response != "reject":
		return {"ok": false, "message": "response must be accept/reject"}
	var trade := Db.find_trade_offer(trade_id)
	if trade.is_empty():
		return {"ok": false, "message": "未知交易：%s" % trade_id}
	if str(trade.get("status", "")) != "pending":
		return {"ok": false, "message": "该交易已经不是 pending 状态了"}
	var seller_id := str(trade.get("to_character_id", ""))
	var buyer_id := str(trade.get("from_character_id", ""))
	if _character.backend_character_id() != seller_id:
		return {"ok": false, "message": "只有收到了报价的一方才能回应这笔交易"}
	if response == "reject":
		Db.update_trade_offer_status(trade_id, "rejected")
		var rejected := Db.find_trade_offer(trade_id)
		var rejected_trade: Dictionary = rejected if not rejected.is_empty() else trade
		_refresh_trade_contexts(rejected_trade)
		var reject_result := {
			"ok": true,
			"trade_id": trade_id,
			"buyer_id": buyer_id,
			"seller_id": seller_id,
			"response": "reject",
			"trade": rejected_trade,
		}
		_resolve_pending_offer(trade_id, "reject", reject_result)
		return reject_result

	var buyer := _character.find_other_character(buyer_id)
	if buyer == null:
		return {"ok": false, "message": "买家当前不在场景中"}
	var offer_lines := _normalize_trade_lines(trade.get("offer", []))
	var request_lines := _normalize_trade_lines(trade.get("request", []))
	# 买家(发起方)的 offer 货：先背包后自家附近货架——货架主可以主动把货架上的货 offer 出去。
	# delivery=对方实际收到的（含货架 sold_stack）；inventory=只从背包扣出的部分，回滚时只还这部分，
	# 货架靠"成交才 commit"实现回滚（reserve 阶段不动 DB）。
	var offered_extract := _extract_trade_lines_with_shelf(buyer, offer_lines)
	if not bool(offered_extract.get("ok", false)):
		return offered_extract
	var offered_delivery_stacks := _as_dict_array(offered_extract.get("stacks", []))
	var offered_inventory_stacks := _as_dict_array(offered_extract.get("inventory_stacks", []))
	var offered_shelf_entries: Array = offered_extract.get("shelf_entries", [])
	var buyer_centi_taken := int(offered_extract.get("centi_taken", 0))
	# 卖家(应答方)的 request 货：同样先背包后自家附近货架。
	var requested_extract := _extract_trade_lines_with_shelf(_character, request_lines)
	if not bool(requested_extract.get("ok", false)):
		buyer.inventory_ops().restore_extracted_stacks(offered_inventory_stacks)
		buyer.inventory_ops().refund_centi(buyer_centi_taken)
		return requested_extract
	var delivery_stacks := _as_dict_array(requested_extract.get("stacks", []))
	var extracted_seller_stacks := _as_dict_array(requested_extract.get("inventory_stacks", []))
	var requested_shelf_entries: Array = requested_extract.get("shelf_entries", [])
	var seller_centi_taken := int(requested_extract.get("centi_taken", 0))
	if offered_delivery_stacks.is_empty() and delivery_stacks.is_empty() and buyer_centi_taken == 0 and seller_centi_taken == 0:
		return {"ok": false, "message": "这笔交易没有可转移的内容"}
	var seller_receive := _character.inventory_ops().receive_stacks(offered_delivery_stacks)
	if not bool(seller_receive.get("ok", false)):
		if not extracted_seller_stacks.is_empty():
			_character.inventory_ops().restore_extracted_stacks(extracted_seller_stacks)
		buyer.inventory_ops().restore_extracted_stacks(offered_inventory_stacks)
		buyer.inventory_ops().refund_centi(buyer_centi_taken)
		_character.inventory_ops().refund_centi(seller_centi_taken)
		return {
			"ok": false,
			"message": str(seller_receive.get("message", "你现在收不下对方给的东西")),
		}
	var buyer_receive := buyer.inventory_ops().receive_stacks(delivery_stacks)
	if not bool(buyer_receive.get("ok", false)):
		_character.inventory_ops().rollback_received_stacks(offered_delivery_stacks)
		if not extracted_seller_stacks.is_empty():
			_character.inventory_ops().restore_extracted_stacks(extracted_seller_stacks)
		buyer.inventory_ops().restore_extracted_stacks(offered_inventory_stacks)
		buyer.inventory_ops().refund_centi(buyer_centi_taken)
		_character.inventory_ops().refund_centi(seller_centi_taken)
		return {
			"ok": false,
			"message": str(buyer_receive.get("message", "对方现在装不下这些东西")),
		}
	# wallet 转账（已从 owner 扣完 → 这里只补给 receiver；金额 0 是 no-op）
	_character.wallet_add(buyer_centi_taken)
	buyer.wallet_add(seller_centi_taken)
	# 双方货架扣减统一在成交后 commit（买家自家货架 + 卖家自家货架各一份）。
	var shelf_entries: Array = []
	shelf_entries.append_array(offered_shelf_entries)
	shelf_entries.append_array(requested_shelf_entries)
	if not shelf_entries.is_empty():
		_commit_trade_shelf_entries(shelf_entries)
	Db.update_trade_offer_status(trade_id, "accepted")
	var accepted := Db.find_trade_offer(trade_id)
	var accepted_trade: Dictionary = accepted if not accepted.is_empty() else trade
	_refresh_trade_contexts(accepted_trade, shelf_entries)
	var accept_result := {
		"ok": true,
		"trade_id": trade_id,
		"buyer_id": buyer_id,
		"seller_id": seller_id,
		"response": "accept",
		"trade": accepted_trade,
	}
	_resolve_pending_offer(trade_id, "accept", accept_result)
	return accept_result


# 卖家发起 move_to_location 时调：所有指向自己的 pending offer 标 cancelled，
# 让买家阻塞的 offer 工具用 response="cancelled" 解锁。
func cancel_incoming_offers_as_seller(reason: String) -> void:
	var seller_id := _character.backend_character_id()
	if seller_id.is_empty():
		return
	var pending := Db.list_pending_trades_as_seller(seller_id)
	for trade_v in pending:
		var trade: Dictionary = trade_v as Dictionary
		var trade_id := str(trade.get("trade_id", ""))
		var buyer_id := str(trade.get("from_character_id", ""))
		if trade_id.is_empty() or buyer_id.is_empty():
			continue
		Db.update_trade_offer_status(trade_id, "cancelled")
		var refreshed := Db.find_trade_offer(trade_id)
		var refreshed_trade: Dictionary = refreshed if not refreshed.is_empty() else trade
		_refresh_trade_contexts(refreshed_trade)
		_resolve_pending_offer(trade_id, "cancelled", {
			"buyer_id": buyer_id,
			"seller_id": seller_id,
			"trade": refreshed_trade,
			"reason": reason,
		})


# cancel/preempt：买家在等卖家 respond 时切到别的 action。把 pending trade 标 rejected
# （避免 DB 行卡死 buyer→seller 下一次报价），清自己的 _pending。runner 负责 lifecycle，不 fire completion。
# 卖家若已经在打 respond，撮合那条会先拿到 'pending' 写完 → 这里再 reject 是 no-op；
# 竞态由 trade_respond 内部 status check 兜底。
func cancel_pending(reason: String) -> void:
	if _pending.is_empty():
		return
	var trade_id := str(_pending.get("trade_id", ""))
	_pending = {}
	if trade_id.is_empty():
		return
	var trade := Db.find_trade_offer(trade_id)
	if not trade.is_empty() and str(trade.get("status", "")) == "pending":
		Db.update_trade_offer_status(trade_id, "rejected")
		_refresh_trade_contexts(trade)


func preempt() -> void:
	cancel_pending("preempted by new action_request")


# 撮合成功 / cancelled 后由 trade_respond / cancel_incoming_offers_as_seller 调，
# 找到买家 TradeRunner，调 resolve_pending 把买家阻塞的 offer 解锁。
func _resolve_pending_offer(trade_id: String, response: String, result: Dictionary) -> void:
	var buyer_id := str(result.get("buyer_id", ""))
	if buyer_id.is_empty():
		return
	var buyer := _character.find_other_character(buyer_id)
	if buyer == null:
		push_warning("[trade] 买家 %s 不在场景中，无法回填 offer 结果" % buyer_id)
		return
	var buyer_trade: TradeRunner = buyer.trade_runner()
	if buyer_trade == null:
		return
	var payload := {
		"trade_id": trade_id,
		"response": response,
		"trade": result.get("trade", {}),
	}
	buyer_trade.resolve_pending(trade_id, payload)


# 由 _resolve_pending_offer 远程调（卖家撮合完后回填买家 pending offer 结果）。
# 校验 trade_id 一致 → 清 _pending → fire completion 解锁买家阻塞中的 offer 工具。
func resolve_pending(trade_id: String, payload: Dictionary) -> void:
	if _pending.is_empty() or str(_pending.get("trade_id", "")) != trade_id:
		return
	var completion: Callable = _pending.get("completion", Callable())
	_pending = {}
	if completion.is_valid():
		completion.call(true, "", payload)


# ─── 内部辅助 ──────────────────────────────────────────


func _run_respond_trade(t: Dictionary) -> Dictionary:
	var response := str(t.get("response", "")).strip_edges()
	if response != "accept" and response != "reject":
		return {"ok": false, "message": "response 必须为 accept 或 reject"}
	var buyer_id := str(t.get("buyerCharacterId", "")).strip_edges()
	if buyer_id.is_empty():
		return {"ok": false, "message": "respond(kind=trade) 缺少 buyerCharacterId"}
	var seller_id := _character.backend_character_id()
	var pending := Db.list_pending_trades_for_pair(buyer_id, seller_id)
	if pending.is_empty():
		return {"ok": false, "message": "找不到来自 %s 的待回应交易" % buyer_id}
	if pending.size() > 1:
		push_warning("[trade] pair %s→%s 存在 %d 条 pending，按最新一条处理" % [buyer_id, seller_id, pending.size()])
	var trade_id := str((pending[0] as Dictionary).get("trade_id", ""))
	if trade_id.is_empty():
		return {"ok": false, "message": "pending 交易缺少 trade_id"}
	return MechanicVerb.resolve("trade", {
		"actor": _character,
		"actor_id": seller_id,
		"trade_id": trade_id,
		"response": response,
	}, "on_respond")


# _run_give：offer(request:[]) 单向赠送同步路径。
# 与 trade 不同：不写 trade_offers 行、不需要对方 respond、立即返回 transferred 结果。
# 物品转移 + world_event "give" 都进 DB；收件人 LLM 通过 sensory event 看到"X 给了我 Y"。
# offer_lines 由 _trade_lines_from_value 已归一为 [{item: itemId, count, slot_index?}, ...]。
func _run_give(recipient_id: String, offer_lines: Array) -> Dictionary:
	if recipient_id.is_empty():
		return {"ok": false, "message": "offer 缺少接收角色"}
	var giver_id := _character.backend_character_id()
	if recipient_id == giver_id:
		return {"ok": false, "message": "不能把东西递给自己"}
	var recipient: Character = _character.find_other_character(recipient_id)
	if recipient == null:
		return {"ok": false, "message": "找不到 %s" % recipient_id}
	if recipient.sleep_controller().is_sleeping():
		return {"ok": false, "message": "%s 正在睡觉，没法接你递的东西" % _character_display_name(recipient_id)}
	var radius := CharacterPerception.CHARACTER_NEAR_RADIUS
	var dist_sq := _character.global_position.distance_squared_to(recipient.global_position)
	if dist_sq > radius * radius:
		return {
			"ok": false,
			"message": "距离不够，需要走到 %s 旁边（%.0f 米内）才能递交" % [_character_display_name(recipient_id), radius],
		}

	# 逐项 best-effort：货币走 wallet（count 是小数 silver），其他走 add_instance/remove_item（count 是整数）。
	# leftover>0 留 giver 不报错。event_items 用于 world_event 渲染（quantity 数值与 count 同单位）。
	var transferred_lines: Array = []
	var event_items: Array = []
	# 货架主站在自家货架旁白送时，背包不够的部分会从货架上扣；committed 的货架条目记这里，收尾刷新 context。
	var consumed_shelf_entries: Array = []
	for line_v in offer_lines:
		if typeof(line_v) != TYPE_DICTIONARY:
			continue
		var line: Dictionary = line_v as Dictionary
		var item_id := str(line.get("item", "")).strip_edges()
		var count_f := float(line.get("count", 0.0))
		if item_id.is_empty() or count_f <= 0.0:
			continue
		var transferred_f := _give_transfer_one(recipient, item_id, count_f, line.get("slot_index", null), consumed_shelf_entries)
		transferred_lines.append({"itemId": item_id, "requested": count_f, "transferred": transferred_f})
		if transferred_f > 0.0:
			event_items.append({"itemId": item_id, "quantity": transferred_f})

	# 全部 transferred=0 视为失败（背包满 / 库存不足）。
	var any_transferred := false
	for line_v in transferred_lines:
		if float((line_v as Dictionary).get("transferred", 0.0)) > 0.0:
			any_transferred = true
			break
	if not any_transferred:
		return {"ok": false, "message": "%s 装不下任何递交的物品" % _character_display_name(recipient_id)}

	# 货架被白送扣减过 → 刷新货架 context，让 giver 的 # 我的货架 / 旁人感知同步更新。
	for entry_v in consumed_shelf_entries:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var shelf := (entry_v as Dictionary).get("shelf") as ShelfNode
		if shelf != null and Shelves != null and Shelves.has_method("refresh_contexts_for_shelf"):
			Shelves.refresh_contexts_for_shelf(shelf.effective_shelf_id(), [giver_id, recipient_id])

	# affectedCharacterIds 包含 giver + recipient + voice_far visibility 旁观者：
	# giver=ignored / recipient=direct_speech / bystander=ambient_sensory（backend classification.ts）。
	var affected: Array = _character.perception().voice_affected_character_ids("far") as Array
	if not affected.has(giver_id):
		affected.append(giver_id)
	if not affected.has(recipient_id):
		affected.append(recipient_id)
	_character.emit_world_event("give", {
		"actorId": giver_id,
		"affectedCharacterIds": affected,
		"recipientCharacterId": recipient_id,
		"items": event_items,
	})
	return {
		"ok": true,
		"result": {
			"recipientCharacterId": recipient_id,
			"transferred": transferred_lines,
		},
	}


# 单项转移：货币走 wallet（小数枚数支持，最终按 centi 整数转账）；
# 其他物品先从背包按 slot 复制 instance → recipient.add_instance → 从 giver remove_item，
# 背包不够（或压根没有）时，剩余从 giver 自家附近货架取（货架主站在货架旁才有候选）。
# 返回实际 transferred（货币 = 小数枚数；非货币 = 整数件）。
func _give_transfer_one(recipient: Character, item_id: String, count: float, slot_hint: Variant, shelf_entries_out: Array) -> float:
	var coin_centi := CharacterInventory.currency_item_centi(item_id)
	if coin_centi > 0:
		# 货币：count_silver × coin_centi = 想转的 centi 数（已保证 0.01 精度整数 centi）。
		var want_centi := int(round(count * coin_centi))
		if want_centi <= 0:
			return 0.0
		var have_centi := _character.wallet_centi
		var actually_centi := mini(want_centi, have_centi)
		if actually_centi <= 0:
			return 0.0
		_character.wallet_add(-actually_centi)
		recipient.wallet_add(actually_centi)
		# 转回 count 单位（枚数）：actually_centi / coin_centi。保留小数精度。
		return float(actually_centi) / float(coin_centi)

	# 非货币：count 必为正整数（_trade_lines_from_value 已校验）。
	var want_int := int(round(count))
	if want_int <= 0:
		return 0.0
	var transferred := 0
	# 1) 先从背包取：slot_hint 优先，否则第一个匹配的非空背包槽（沿用原单槽语义）。
	var src_slot := -1
	if slot_hint != null and typeof(slot_hint) in [TYPE_INT, TYPE_FLOAT]:
		var hinted := int(slot_hint)
		if hinted >= 0 and hinted < _character.inventory.size():
			var slot_dict: Dictionary = _character.inventory[hinted]
			if str(slot_dict.get("item_id", "")) == item_id and int(slot_dict.get("quantity", 0)) > 0:
				src_slot = hinted
	if src_slot < 0:
		src_slot = _character.first_inventory_slot_for_item(item_id)
	if src_slot >= 0:
		var source: Dictionary = _character.inventory[src_slot]
		var have := int(source.get("quantity", 0))
		if have > 0:
			var want := mini(want_int, have)
			# 复制 instance 全字段（保 quality / freshness / aspects 等）给 recipient.add_instance。
			var inst_copy: Dictionary = source.duplicate(true)
			var leftover := recipient.inventory_ops().add_instance(inst_copy, want)
			var actually := want - leftover
			if actually > 0:
				_character.inventory_ops().remove_item(src_slot, actually)
				transferred += actually
	# 2) 背包不够，剩余从 giver 自家附近货架取。
	var remaining := want_int - transferred
	if remaining > 0:
		transferred += _give_from_shelf(recipient, item_id, remaining, shelf_entries_out)
	return float(transferred)


# 白送时从 giver 自家附近货架取 item_id 最多 want 件给 recipient，按实际接收量即时扣减 listing。
# gift 是 best-effort 即时转移、无回滚：取一件给一件扣一件。committed 的货架条目记入
# shelf_entries_out 供调用方收尾刷新货架 context。返回实际转移件数。候选复用交易那套
# _eligible_trade_shelf_candidates（只要货架主本人在自家货架 3 米内）。
func _give_from_shelf(recipient: Character, item_id: String, want: int, shelf_entries_out: Array) -> int:
	if want <= 0:
		return 0
	var transferred := 0
	for candidate_v in _eligible_trade_shelf_candidates(_character):
		if transferred >= want:
			break
		if typeof(candidate_v) != TYPE_DICTIONARY:
			continue
		var candidate: Dictionary = candidate_v as Dictionary
		var listing: Dictionary = candidate.get("listing", {})
		var slot: Dictionary = listing.get("slot", {})
		if str(slot.get("item_id", "")) != item_id:
			continue
		var available := int(slot.get("quantity", 0))
		if available <= 0:
			continue
		var take := mini(available, want - transferred)
		# 复制货架 listing 的 instance 全字段给 recipient.add_instance。
		var inst_copy: Dictionary = slot.duplicate(true)
		var leftover := recipient.inventory_ops().add_instance(inst_copy, take)
		var actually := take - leftover
		if actually <= 0:
			continue
		var entry := {
			"listing": listing,
			"shelf": candidate.get("shelf"),
			"quantity": actually,
		}
		_commit_trade_shelf_entries([entry])
		shelf_entries_out.append(entry)
		transferred += actually
	return transferred


func _character_display_name(cid: String) -> String:
	if cid.is_empty():
		return ""
	var key := "npc.%s.name" % cid
	# static-safe i18n（RefCounted 上 tr() 不可用；走 TranslationServer 拿当前 locale 翻译）
	var translated := str(TranslationServer.translate(key))
	if translated != key and not translated.strip_edges().is_empty():
		return translated
	return cid


func _interrupt_seller_walk_for_offer(seller_id: String, buyer_id: String) -> void:
	var seller := _character.find_other_character(seller_id)
	if seller == null:
		return
	if not seller.has_method("_backend_actions"):
		return
	var seller_runner: BackendActionRunner = seller.call("_backend_actions")
	if seller_runner == null:
		return
	seller_runner.interrupt_walk("被 %s 的交易请求打断" % buyer_id)


# Wire contract: backend/src/godot-link/actions.ts. offer.characterId = seller (request 非空时);
# respond.buyerCharacterId = buyer (kind="trade" 时)。Single canonical key per field — no aliases.


# Wire contract guarantees offer / request 是 Array[{item:String, count:Number>=1 整数；
# 货币 silver_coin/gold_coin 允许小数 ≥0.01，精度 0.01}]。
# 仍做结构校验是因为：玩家 UI / DB replay / 内部 trade_create 调用都会经过这里，
# 不只是 backend 提交的 LLM action。货币 count 内部统一存 float；下游结算 round 到 centi。
# 返回 {ok, message?, lines}。
func _trade_lines_from_value(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_ARRAY:
		return {"ok": false, "message": "交易条目必须为数组"}
	var out: Array = []
	for entry_v in (value as Array):
		if typeof(entry_v) != TYPE_DICTIONARY:
			return {"ok": false, "message": "交易条目必须为 {item, count} 对象"}
		var entry: Dictionary = entry_v as Dictionary
		var item := str(entry.get("item", "")).strip_edges()
		if item.is_empty():
			return {"ok": false, "message": "交易条目缺少 item"}
		var count_raw: float = float(entry.get("count", 0.0))
		var is_currency := CharacterInventory.currency_item_centi(item) > 0
		# slotIndex 是 backend 反查 LLM {name,index} 时透传的真实背包槽位 id；
		# offer/give 路径用它精确扣对那份 stack，trade 撮合也透传给 lua（不强求用上）。
		var line_out := {"item": item}
		if entry.has("slotIndex"):
			line_out["slot_index"] = int(entry.get("slotIndex", -1))
		if is_currency:
			if count_raw < 0.01 - 0.000001:
				return {"ok": false, "message": "%s 的 count 必须 ≥ 0.01" % item}
			line_out["count"] = _round_currency_count(count_raw)
		else:
			var count_int := int(round(count_raw))
			if absf(count_raw - float(count_int)) > 0.000001 or count_int <= 0:
				return {"ok": false, "message": "%s 的 count 必须为正整数" % item}
			line_out["count"] = count_int
		out.append(line_out)
	return {"ok": true, "lines": out}


# trade_create / trade_respond 内部用：丢弃明显损坏的 DB 回放条目。正常路径不该触发。
func _normalize_trade_lines(value: Variant) -> Array:
	var out: Array = []
	if typeof(value) != TYPE_ARRAY:
		return out
	for entry_v in (value as Array):
		if typeof(entry_v) != TYPE_DICTIONARY:
			push_warning("[trade] 丢弃非 dict 交易条目：%s" % str(entry_v))
			continue
		var entry: Dictionary = entry_v as Dictionary
		var item := str(entry.get("item", "")).strip_edges()
		var count_raw: float = float(entry.get("count", 0.0))
		var is_currency := CharacterInventory.currency_item_centi(item) > 0
		if item.is_empty() or count_raw <= 0.0:
			push_warning("[trade] 丢弃无效交易条目：%s" % str(entry))
			continue
		if is_currency:
			out.append({"item": item, "count": _round_currency_count(count_raw)})
		else:
			out.append({"item": item, "count": int(round(count_raw))})
	return out


# 把货币 count 量化到 centi 网格（0.01 精度），消除浮点误差，便于结算时 round 出整 centi。
static func _round_currency_count(count: float) -> float:
	return round(count * 100.0) / 100.0


func _commit_trade_shelf_entries(entries: Array) -> void:
	for entry_v in entries:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_v as Dictionary
		var listing: Dictionary = entry.get("listing", {})
		var shelf := entry.get("shelf") as ShelfNode
		if shelf == null:
			continue
		var quantity := int(entry.get("quantity", 0))
		var slot: Dictionary = (listing.get("slot", {}) as Dictionary).duplicate(true)
		var available := int(slot.get("quantity", 0))
		var listing_id := str(listing.get("listing_id", ""))
		var seller_id := str(listing.get("owner_character_id", ""))
		if quantity >= available:
			Db.delete_shelf_listing(listing_id)
		else:
			slot["quantity"] = available - quantity
			Db.save_shelf_listing(
				shelf.effective_shelf_id(),
				int(listing.get("slot_index", 0)),
				listing_id,
				seller_id,
				int(listing.get("price_centi", 0)),
				slot,
				shelf.effective_location_id()
			)


# owner 用"自己的背包 + 自己附近货架"履约这些交易条目（货币从 owner 钱包扣）。
# 同时服务两个方向：trade 应答方履约买家的 request（被动卖），以及发起 offer 的货架主把
# 货架上的货拿出来 offer（主动卖）。返回：
#   stacks           = 对方实际会收到的（背包货 + 货架 sold_stack）
#   inventory_stacks = 只从背包扣出的部分，回滚时只还这部分
#   shelf_entries    = 待 commit 的货架扣减（reserve 阶段不碰 DB，成交后才 _commit_trade_shelf_entries）
#   centi_taken      = 已从钱包扣走的货币
func _extract_trade_lines_with_shelf(owner: Character, lines: Array) -> Dictionary:
	var inventory_stacks: Array[Dictionary] = []
	var delivery_stacks: Array[Dictionary] = []
	var shelf_entries: Array = []
	var shelf_entry_indices := {}
	var reserved_by_listing := {}
	var shelf_candidates := _eligible_trade_shelf_candidates(owner)
	var centi_taken := 0
	for line_v in lines:
		var line: Dictionary = line_v as Dictionary
		var item_id := str(line.get("item", "")).strip_edges()
		var coin_centi := CharacterInventory.currency_item_centi(item_id)
		var count_raw: float = float(line.get("count", 0.0))
		if item_id.is_empty() or count_raw <= 0.0:
			owner.inventory_ops().restore_extracted_stacks(inventory_stacks)
			owner.inventory_ops().refund_centi(centi_taken)
			return {"ok": false, "message": "无效交易条目：%s" % str(line)}
		if coin_centi > 0:
			# 货币：count 是"几枚币"（float），换算到 centi 后必为整数（schema 保证 0.01 精度）。
			var line_centi := int(round(float(coin_centi) * count_raw))
			if line_centi <= 0:
				owner.inventory_ops().restore_extracted_stacks(inventory_stacks)
				owner.inventory_ops().refund_centi(centi_taken)
				return {"ok": false, "message": "无效交易条目：%s" % str(line)}
			var pay := owner.inventory_ops().pay_centi(line_centi)
			if not bool(pay.get("ok", false)):
				owner.inventory_ops().restore_extracted_stacks(inventory_stacks)
				owner.inventory_ops().refund_centi(centi_taken)
				return pay
			centi_taken += line_centi
			continue
		var quantity := int(round(count_raw))
		if quantity <= 0:
			owner.inventory_ops().restore_extracted_stacks(inventory_stacks)
			owner.inventory_ops().refund_centi(centi_taken)
			return {"ok": false, "message": "无效交易条目：%s" % str(line)}
		var remaining := quantity
		var inventory_take := _extract_named_trade_item_across_inventory(owner, item_id, remaining)
		var named_stacks := _as_dict_array(inventory_take.get("stacks", []))
		if not named_stacks.is_empty():
			inventory_stacks.append_array(named_stacks)
			delivery_stacks.append_array(named_stacks)
			remaining = int(inventory_take.get("remaining", remaining))
		if remaining > 0:
			remaining = _reserve_trade_shelf_items(
				shelf_candidates,
				item_id,
				remaining,
				reserved_by_listing,
				shelf_entries,
				shelf_entry_indices,
				delivery_stacks
			)
		if remaining > 0:
			owner.inventory_ops().restore_extracted_stacks(inventory_stacks)
			owner.inventory_ops().refund_centi(centi_taken)
			return {
				"ok": false,
				"message": "背包和当前附近自家货架里都没有足够的 %s（需要 %d）" % [item_id, quantity],
			}
	return {
		"ok": true,
		"stacks": delivery_stacks,
		"inventory_stacks": inventory_stacks,
		"shelf_entries": shelf_entries,
		"centi_taken": centi_taken,
	}


func _extract_named_trade_item_across_inventory(owner: Character, item_id: String, quantity: int) -> Dictionary:
	var remaining := maxi(quantity, 0)
	var extracted: Array[Dictionary] = []
	if remaining <= 0:
		return {"stacks": extracted, "remaining": 0}
	for slot_index in owner.inventory.size():
		if remaining <= 0:
			break
		var slot: Dictionary = owner.inventory_ops().get_slot(slot_index)
		if str(slot.get("item_id", "")) != item_id:
			continue
		var take := mini(int(slot.get("quantity", 0)), remaining)
		if take <= 0:
			continue
		var stack := owner.inventory_ops().extract_stack(slot_index, take)
		if stack.is_empty():
			continue
		extracted.append(stack)
		remaining -= take
	return {
		"stacks": extracted,
		"remaining": remaining,
	}


# 只要货架主(owner)本人站在自家货架 3 米内即可，不再要求交易对手也站在旁边——
# 货从货架主自己的货架上扣，对手在不在场跟"能不能扣这座货架"无关。
func _eligible_trade_shelf_candidates(owner: Character) -> Array:
	var candidates: Array = []
	if owner == null:
		return candidates
	if Shelves == null or not Shelves.has_method("find_shelf_node"):
		return candidates
	var owner_id := owner.backend_character_id()
	for snapshot_v in owner.perception().owned_shelf_snapshots():
		if typeof(snapshot_v) != TYPE_DICTIONARY:
			continue
		var snapshot: Dictionary = snapshot_v as Dictionary
		var shelf_id := str(snapshot.get("id", "")).strip_edges()
		if shelf_id.is_empty():
			continue
		var shelf := Shelves.find_shelf_node(shelf_id)
		if shelf == null:
			continue
		if not _is_character_near_shelf(owner, shelf):
			continue
		for listing in Db.list_shelf_listings(shelf_id):
			if str(listing.get("owner_character_id", "")).strip_edges() != owner_id:
				continue
			candidates.append({
				"shelf": shelf,
				"listing": listing,
			})
	return candidates


func _reserve_trade_shelf_items(
	candidates: Array,
	item_id: String,
	quantity: int,
	reserved_by_listing: Dictionary,
	shelf_entries: Array,
	shelf_entry_indices: Dictionary,
	delivery_stacks: Array
) -> int:
	var remaining := maxi(quantity, 0)
	for candidate_v in candidates:
		if remaining <= 0:
			break
		if typeof(candidate_v) != TYPE_DICTIONARY:
			continue
		var candidate: Dictionary = candidate_v as Dictionary
		var listing: Dictionary = candidate.get("listing", {})
		var slot: Dictionary = listing.get("slot", {})
		if str(slot.get("item_id", "")) != item_id:
			continue
		var listing_id := str(listing.get("listing_id", "")).strip_edges()
		if listing_id.is_empty():
			continue
		var reserved := int(reserved_by_listing.get(listing_id, 0))
		var available := int(slot.get("quantity", 0)) - reserved
		if available <= 0:
			continue
		var take := mini(available, remaining)
		reserved_by_listing[listing_id] = reserved + take
		if shelf_entry_indices.has(listing_id):
			var existing_index := int(shelf_entry_indices.get(listing_id, -1))
			if existing_index >= 0 and existing_index < shelf_entries.size():
				var existing: Dictionary = shelf_entries[existing_index] as Dictionary
				var sold_stack: Dictionary = existing.get("sold_stack", {})
				sold_stack["quantity"] = int(sold_stack.get("quantity", 0)) + take
				existing["quantity"] = int(existing.get("quantity", 0)) + take
				existing["sold_stack"] = sold_stack
				shelf_entries[existing_index] = existing
			else:
				shelf_entry_indices.erase(listing_id)
		else:
			var sold_stack := slot.duplicate(true)
			sold_stack["quantity"] = take
			shelf_entry_indices[listing_id] = shelf_entries.size()
			shelf_entries.append({
				"listing": listing.duplicate(true),
				"shelf": candidate.get("shelf"),
				"quantity": take,
				"sold_stack": sold_stack,
			})
			delivery_stacks.append(sold_stack)
		remaining -= take
	return remaining


# Variant 拿出来的 Array 会丢掉 Array[Dictionary] 标签（Dictionary 存的是 Variant），
# 这里 .assign() 复制并重新打上类型，给 character.receive/restore/rollback_inventory_stacks
# 这些 typed-array 入参用。
func _as_dict_array(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(value) == TYPE_ARRAY:
		out.assign(value as Array)
	return out


func _refresh_trade_contexts(trade: Dictionary, shelf_entries: Array = []) -> void:
	var buyer_id := str(trade.get("from_character_id", ""))
	var seller_id := str(trade.get("to_character_id", ""))
	for character_id in [buyer_id, seller_id]:
		var node := _character.find_other_character(character_id)
		if node != null and node.has_method("send_perception_manifest"):
			node.call_deferred("send_perception_manifest")
	for entry_v in shelf_entries:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_v as Dictionary
		var shelf := entry.get("shelf") as ShelfNode
		if shelf != null and Shelves != null and Shelves.has_method("refresh_contexts_for_shelf"):
			Shelves.refresh_contexts_for_shelf(shelf.effective_shelf_id(), [buyer_id, seller_id])


func _is_character_near_shelf(other: Character, shelf: ShelfNode) -> bool:
	if other == null or shelf == null:
		return false
	var radius := maxf(float(shelf.interaction_radius), 3.0)
	return other.global_position.distance_squared_to(shelf.get_approach_node().global_position) <= radius * radius
