class_name FarmActionRunner
extends RefCounted

# Character 的农事动作 + 队列调度收口。包含三层：
# 1. **显式 target API** (try_*_at)：op 已知 slot/farm，做业务校验 + 状态变更。
# 2. **facing 包装** (try_*_facing)：用 character 朝向找前方目标 → 调 try_*_at。
# 3. **队列** (enqueue / cancel / tick)：每 op walking → working → apply → 下一个。
#
# 队列推进时调 character 的虚 hook：
# - `character._queue_walk_to(pos)` / `character._queue_stop_walking()` —— NPC/Player override
# - `character.set("anim_state", ...)` —— 切动画（NPC/Player 各自有 anim_state 属性）
# - `character.head_status().push_override(text)` / `character.head_status().clear_override()`
# - `character._on_farm_queue_completed(summary)` —— NPC override 用来回报 plan_farm_work ack

# 时长以 game-second 计（GameClock.game_seconds，跟 timewarp 一起加速）。
# stamina_cost / duration_seconds 唯一真值住在 data/mechanics/crops.lua on_action_cost；
# 通过 Farming.resolve_action_cost(kind) 取，StaminaWallet 扣体力。本文件不再持有任何
# stamina / duration 常量。
# character 走到目标 ≤ 此值即算"到位"，进入 working
const FARM_QUEUE_ARRIVE_DIST := 1.2

const FACING_PLANT_RANGE := 1.5
const FACING_INTERACT_RANGE := 1.5

var character: Character
# op schema: { kind, slot_node?: Node3D, farm_node?: Node3D, payload?: Variant, slot_index?: int }
var _queue: Array[Dictionary] = []
var _active: Dictionary = {}        # 空 = idle；非空时含 op + target_pos + (working 时) deadline_game_seconds
var _active_state: String = ""      # "" | "walking" | "working"
var _completed_log: Array[Dictionary] = []  # 完成项日志，cancel/drain 时返回
# 记录当前已写盘的 activity 关联 farm_id；_enter_working 写、所有出口路径清。
# 用变量而非每次从 op 反推：cancel/_stop_queue/_on_drained 进来时 _active 可能已被清空，
# 拿不到 op；但 _active_farm_id 仍能让我们调一次 clear_character_activity 兜底。
var _active_farm_id: String = ""


func _init(owner: Character) -> void:
	character = owner


# ─── 显式 target 版本（队列驱动 + 直接调用都用这套）────────────

func try_plant_seed_at(slot: FarmSlot, item_id: String, slot_index: int = -1) -> Dictionary:
	assert(RunMode.is_runtime(), "try_plant_seed_at must run on server")
	if slot == null or not is_instance_valid(slot):
		return {"ok": false, "message": _msg("error.farm.slot_missing")}
	var access := _check_field_access_for_slot(slot)
	if not bool(access.get("ok", true)):
		return access
	if slot.is_occupied():
		var occupied_slot_index := slot_index
		var parent := slot.get_parent()
		if occupied_slot_index < 0 and parent is FarmGroup:
			var farm_slots := (parent as FarmGroup).slots()
			for i in farm_slots.size():
				if farm_slots[i] == slot:
					occupied_slot_index = i
					break
		var slot_label := "目标 slot"
		if occupied_slot_index >= 0:
			slot_label = "slot_index=%d" % occupied_slot_index
		return {
			"ok": false,
			"code": "slot_occupied",
			"slot_index": occupied_slot_index,
			"message": _fmt("error.farm.slot_occupied_format", [slot_label]),
		}
	if character.inventory_ops().count_item(item_id) <= 0:
		return {"ok": false, "message": _fmt("error.farm.backpack_missing_format", [item_id])}
	var item := Items.by_id(item_id)
	if item == null or not item.tags.has("seed") or item.crop_variety_id.is_empty():
		return {"ok": false, "message": _fmt("error.farm.not_seed_format", [item_id])}
	var spawner := character.get_tree().current_scene.get_node_or_null("CropSpawner") as MultiplayerSpawner
	if spawner == null:
		return {"ok": false, "message": _msg("error.farm.crop_spawner_missing")}
	if not Varieties.has_id(item.crop_variety_id):
		return {"ok": false, "message": _msg("error.farm.variety_missing")}
	var stamina_spend := _spend_for("plant")
	if not bool(stamina_spend.get("ok", false)):
		return stamina_spend
	# 醉酒/生病：手抖种砸了——种子照样废掉（不返还），不长作物。
	if randf() < Impairment.fail_chance(Impairment.work_impair(character)):
		character.inventory_ops().consume_one(item_id)
		return _annotate({"ok": false, "code": "plant_fumbled", "message": _msg("error.farm.plant_fumbled")}, stamina_spend)
	var crop := Crop.spawn(spawner, item.crop_variety_id, slot.global_position)
	if crop == null:
		return {"ok": false, "message": _msg("error.farm.variety_missing")}
	# 扣 1 颗（找第一个非空 stack）
	for i in character.inventory.size():
		var s: Dictionary = character.inventory[i]
		if s["item_id"] == item_id and int(s["quantity"]) > 0:
			character.inventory_ops().remove_item(i, 1)
			break
	return _annotate({"ok": true, "message": _fmt("tool.tool_result.farm.planted_format", [item.display_name])}, stamina_spend)


func try_water_at(crop: Crop) -> Dictionary:
	assert(RunMode.is_runtime(), "try_water_at must run on server")
	if crop == null or not is_instance_valid(crop):
		return {"ok": false, "message": _msg("error.farm.crop_missing")}
	var farm := crop.owning_farm()
	if farm == null:
		return {"ok": false, "message": _msg("error.farm.crop_not_in_watering_farm")}
	return try_water_farm_at(farm)


# 一次浇整片农场：消耗 20 点水，把整片田 moisture +20%。
# 即使这片田当前没有作物，也允许先把土浇湿；但满水时不再消耗桶水。
func try_water_farm_at(farm: FarmGroup) -> Dictionary:
	assert(RunMode.is_runtime(), "try_water_farm_at must run on server")
	if farm == null or not is_instance_valid(farm):
		return {"ok": false, "message": _msg("error.farm.farm_missing")}
	var access := _check_field_access_for_farm(farm)
	if not bool(access.get("ok", true)):
		return access
	if farm.moisture >= 0.999:
		return {"ok": false, "message": _msg("error.farm.already_full_water")}
	var water_check := character.inventory_ops().consume_water_amount(FarmGroup.WATERING_WATER_COST, false)
	if not bool(water_check.get("ok", false)):
		return {"ok": false, "message": str(water_check.get("message", _msg("error.farm.no_water")))}
	var stamina_spend := _spend_for("water")
	if not bool(stamina_spend.get("ok", false)):
		return stamina_spend
	var draw := character.inventory_ops().consume_water_amount(FarmGroup.WATERING_WATER_COST)
	if not bool(draw.get("ok", false)):
		return {"ok": false, "message": str(draw.get("message", _msg("error.farm.no_water")))}
	# 醉酒/生病：水照样从桶里全扣，但大半洒在地上——入土湿度按 water_mult 打折。
	var impair := Impairment.work_impair(character)
	var moisture_delta := FarmGroup.WATERING_MOISTURE_DELTA * Impairment.water_mult(impair)
	var r := farm.water(moisture_delta)
	var before_pct := int(round(float(r.get("before", farm.moisture)) * 100.0))
	var after_pct := int(round(float(r.get("after", farm.moisture)) * 100.0))
	var occupied := int(r.get("occupied_crops", 0))
	var too_wet := int(r.get("too_wet_crops", 0))
	var msg := _fmt("tool.tool_result.farm.watered_prefix_format", [before_pct, after_pct])
	if impair >= Impairment.DRUNK_TIPSY:
		msg += _msg("tool.tool_result.farm.water_shaky_suffix")
	if occupied > 0:
		msg += _fmt("tool.tool_result.farm.water_affected_format", [occupied])
	else:
		msg += _msg("tool.tool_result.farm.water_no_crop_suffix")
	msg += _msg("tool.tool_result.farm.close_paren")
	if too_wet > 0:
		msg += _fmt("tool.tool_result.farm.water_too_wet_suffix_format", [too_wet])
	return _annotate({"ok": true, "message": msg}, stamina_spend)


func try_remove_pest_at(slot: FarmSlot) -> Dictionary:
	assert(RunMode.is_runtime(), "try_remove_pest_at must run on server")
	var access := _check_field_access_for_slot(slot)
	if not bool(access.get("ok", true)):
		return access
	var crop := _crop_on_slot(slot)
	if crop == null:
		return {"ok": false, "message": _msg("error.farm.slot_crop_missing")}
	if not crop.has_pest:
		return {"ok": false, "message": _fmt("error.farm.no_pest_format", [crop.variety.display_name])}
	if character.inventory_ops().count_item("wood_ash") <= 0:
		return {"ok": false, "message": _msg("error.farm.no_wood_ash")}
	var stamina_spend := _spend_for("pest")
	if not bool(stamina_spend.get("ok", false)):
		return stamina_spend
	if not character.inventory_ops().consume_one("wood_ash"):
		return {"ok": false, "message": _msg("error.farm.consume_wood_ash_failed")}
	# 醉酒/生病：撒歪了——草木灰照样废掉（不返还），虫没除掉。
	if randf() < Impairment.fail_chance(Impairment.work_impair(character)):
		return _annotate({"ok": false, "code": "pest_fumbled", "message": _fmt("error.farm.pest_fumbled_format", [crop.variety.display_name])}, stamina_spend)
	crop.remove_pest()
	return _annotate({"ok": true, "message": _fmt("tool.tool_result.farm.pest_removed_format", [crop.variety.display_name])}, stamina_spend)


func try_harvest_at(slot: FarmSlot) -> Dictionary:
	assert(RunMode.is_runtime(), "try_harvest_at must run on server")
	var access := _check_field_access_for_slot(slot)
	if not bool(access.get("ok", true)):
		return access
	var crop := _crop_on_slot(slot)
	if crop == null:
		return {"ok": false, "message": _msg("error.farm.slot_crop_missing")}
	if crop.variety == null or crop.stage != crop.variety.stages.back():
		return {"ok": false, "message": _fmt("error.farm.not_ripe_format", [crop.variety.display_name])}
	return _do_harvest_crop(crop)


# 铲除：把 slot 上的作物直接清掉（不返还任何收成），用于收获结束后的清场
# 或玩家想替换品种时清空。无视 stage / has_pest。需要铁铲（消耗耐久）。
func try_uproot_at(slot: FarmSlot) -> Dictionary:
	assert(RunMode.is_runtime(), "try_uproot_at must run on server")
	var access := _check_field_access_for_slot(slot)
	if not bool(access.get("ok", true)):
		return access
	var crop := _crop_on_slot(slot)
	if crop == null:
		return {"ok": false, "message": _msg("error.farm.slot_crop_missing")}
	if character.inventory_ops().count_item("iron_shovel") <= 0:
		return {"ok": false, "message": _msg("error.farm.no_iron_shovel")}
	var stamina_spend := _spend_for("uproot")
	if not bool(stamina_spend.get("ok", false)):
		return stamina_spend
	var name_cn: String = crop.variety.display_name if crop.variety != null else _msg("tool.tool_result.farm.crop_fallback")
	crop.clear_from_db()
	crop.queue_free()
	var wear: Dictionary = character.inventory_ops().decrement_tool_durability_by_id("iron_shovel", 1)
	var msg: String = _fmt("tool.tool_result.farm.uprooted_format", [name_cn])
	if bool(wear.get("broke", false)):
		msg += _msg("tool.tool_result.farm.shovel_broke_suffix")
	return _annotate({"ok": true, "message": msg}, stamina_spend)


# 提取出来给 facing / at / batch 共用的 harvest 应用逻辑。crop 已校验非空 + 成熟。
# Crop.harvest 内部走 mechanics/crops.lua → affect.give_item 已经把产物加入 character 背包；
# 这里只读结果用于 message / ack。
func _do_harvest_crop(crop: Crop) -> Dictionary:
	var stamina_spend := _spend_for("harvest")
	if not bool(stamina_spend.get("ok", false)):
		return stamina_spend
	var yield_dict := crop.harvest(character)
	var yields_v: Variant = yield_dict.get("yields", [])
	var yields: Array = yields_v if yields_v is Array else []
	if yields.is_empty() and not str(yield_dict.get("item_id", "")).is_empty():
		yields = [yield_dict]
	if yields.is_empty():
		return {"ok": false, "message": _msg("error.farm.empty_yield")}
	var parts: Array[String] = []
	var normalized_yields: Array[Dictionary] = []
	var total_leftover := 0
	var first_yield: Dictionary = {}
	for y_v in yields:
		if not (y_v is Dictionary):
			continue
		var y: Dictionary = y_v
		var item_id := str(y.get("item_id", ""))
		var qty := int(y.get("quantity", 0))
		var got := int(y.get("granted", qty))
		var quality := int(y.get("quality", Character.ITEM_DEFAULT_QUALITY))
		var leftover := int(y.get("leftover", 0))
		if item_id.is_empty() or qty <= 0:
			continue
		if first_yield.is_empty():
			first_yield = y
		parts.append("%s x%d" % [item_id, got])
		total_leftover += leftover
		normalized_yields.append({
			"item_id": item_id,
			"quantity": got,
			"quality": quality,
			"leftover": leftover,
		})
	if normalized_yields.is_empty():
		return {"ok": false, "message": _msg("error.farm.empty_yield")}
	var yield_q := int(first_yield.get("quality", Character.ITEM_DEFAULT_QUALITY))
	var first_id := str(first_yield.get("item_id", ""))
	var first_qty := int(first_yield.get("granted", first_yield.get("quantity", 0)))
	# 种地不挂熟练度——farming 已从 skills.json 移除（设计：技巧靠 farming_basics 知识传授，
	# 实际操作无 skill check）。需要差异化产出请走作物本身的 quality/freshness 链。
	return _annotate({
		"ok": true,
		"message": _fmt("tool.tool_result.farm.harvested_format", [_msg("tool.tool_result.list_separator").join(parts), QualityTier.display_name(yield_q), yield_q]),
		"yields": normalized_yields,
		"yield_id": first_id,
		"yield_qty": first_qty,
		"yield_quality": yield_q,
		"leftover": total_leftover,
	}, stamina_spend)


# ─── facing 包装（slash 命令 + emergency fallback 用）──────────
# 业务核心 + 错误文案都在 *_at 版本里；这里只负责"用 facing 找目标"。

func try_plant_seed_facing(item_id: String) -> Dictionary:
	assert(RunMode.is_runtime(), "try_plant_seed_facing must run on server")
	# 早 return 一个友好提示：背包没可种植物时不需要面对 slot 也能反馈
	if character.inventory_ops().count_item(item_id) <= 0:
		return {"ok": false, "message": _fmt("error.farm.backpack_missing_format", [item_id])}
	var slot_node := _find_facing_node("farm_slots", FACING_PLANT_RANGE, 0.3,
		func(n: Node3D) -> bool: return n is FarmSlot and not (n as FarmSlot).is_occupied())
	if slot_node == null:
		return {"ok": false, "message": _msg("error.farm.front_empty_slot_missing")}
	return try_plant_seed_at(slot_node as FarmSlot, item_id)


func try_water_facing() -> Dictionary:
	assert(RunMode.is_runtime(), "try_water_facing must run on server")
	var crop := _find_facing_node("crops", FACING_INTERACT_RANGE) as Crop
	if crop == null:
		return {"ok": false, "message": _msg("error.farm.front_crop_missing")}
	# 桶水校验在 try_water_at 内统一做（slash facing 入口不重复校验，错误文案同源）
	return try_water_at(crop)


func try_remove_pest_facing() -> Dictionary:
	assert(RunMode.is_runtime(), "try_remove_pest_facing must run on server")
	if character.inventory_ops().count_item("wood_ash") <= 0:
		return {"ok": false, "message": _msg("error.farm.no_wood_ash")}
	var crop := _find_facing_node("crops", FACING_INTERACT_RANGE, 0.3,
		func(n: Node3D) -> bool: return n is Crop and (n as Crop).has_pest) as Crop
	if crop == null:
		return {"ok": false, "message": _msg("error.farm.front_pest_crop_missing")}
	var access := _check_field_access_for_crop(crop)
	if not bool(access.get("ok", true)):
		return access
	var stamina_spend := _spend_for("pest")
	if not bool(stamina_spend.get("ok", false)):
		return stamina_spend
	if not character.inventory_ops().consume_one("wood_ash"):
		return {"ok": false, "message": _msg("error.farm.consume_wood_ash_failed")}
	# 醉酒/生病：撒歪了——草木灰照样废掉（不返还），虫没除掉。
	if randf() < Impairment.fail_chance(Impairment.work_impair(character)):
		return _annotate({"ok": false, "code": "pest_fumbled", "message": _fmt("error.farm.pest_fumbled_format", [crop.variety.display_name])}, stamina_spend)
	crop.remove_pest()
	return _annotate({"ok": true, "message": _fmt("tool.tool_result.farm.pest_removed_format", [crop.variety.display_name])}, stamina_spend)


func try_harvest_facing() -> Dictionary:
	assert(RunMode.is_runtime(), "try_harvest_facing must run on server")
	var crop := _find_facing_node("crops", FACING_INTERACT_RANGE, 0.3,
		func(n: Node3D) -> bool:
			var c := n as Crop
			return c != null and c.variety != null and c.stage == c.variety.stages.back()
	) as Crop
	if crop == null:
		return {"ok": false, "message": _msg("error.farm.front_ripe_crop_missing")}
	var access := _check_field_access_for_crop(crop)
	if not bool(access.get("ok", true)):
		return access
	return _do_harvest_crop(crop)


# ─── 队列 ──────────────────────────────────────────────

func enqueue(ops: Array) -> void:
	assert(RunMode.is_runtime(), "enqueue_farm_actions must run on server")
	if ops.is_empty():
		return
	var was_idle := _queue.is_empty() and _active.is_empty()
	if was_idle:
		_completed_log.clear()
	for op in ops:
		_queue.append(op as Dictionary)
	_report_progress()


func cancel(reason: String = "cancelled") -> Dictionary:
	if _queue.is_empty() and _active.is_empty():
		return {"completed": [], "remaining": [], "interrupted": false, "reason": reason}
	var summary := _build_summary(true, reason)
	_queue.clear()
	_active = {}
	_active_state = ""
	_release_farm_operator()
	character._queue_stop_walking()
	character.head_status().clear_override()
	character._on_farm_op_cancelled(reason)
	character._on_farm_queue_completed(summary)
	return summary


func is_active() -> bool:
	return not _queue.is_empty() or not _active.is_empty()


# 是否正在处理某个 op（NPC physics 用：到位时若有 active op 不要 finish backend，
# 因为 queue tick 接着会进 working）。
func is_processing_op() -> bool:
	return not _active.is_empty()


func active_state() -> String:
	return _active_state


func tick(_delta: float) -> void:
	if _active.is_empty():
		if _queue.is_empty():
			return
		_begin_next()
		return
	match _active_state:
		"walking":
			var target_pos: Vector3 = _active.get("target_pos", character.global_position)
			# Navmesh height can differ from the slot marker height; NPC walking also uses XZ arrival.
			var to_target_xz := Vector2(character.global_position.x - target_pos.x, character.global_position.z - target_pos.z)
			if to_target_xz.length() <= FARM_QUEUE_ARRIVE_DIST:
				_enter_working()
		"working":
			var deadline: float = float(_active.get("deadline_game_seconds", 0.0))
			if GameClock.game_seconds >= deadline:
				_finish_active()


func _begin_next() -> void:
	while not _queue.is_empty():
		var op: Dictionary = _queue.pop_front()
		var target_pos: Variant = _action_target_pos(op)
		if typeof(target_pos) != TYPE_VECTOR3:
			# 目标节点不在了 → 标记 failed，立刻试下一个，不浪费 tick
			_record_completed(op, {"ok": false, "message": _msg("error.farm.target_node_invalid")})
			continue
		_active = {
			"op": op,
			"target_pos": target_pos,
		}
		_active_state = "walking"
		character._queue_walk_to(target_pos)
		_report_progress()
		return
	# 队列消化完
	_on_drained()


func _enter_working() -> void:
	var op: Dictionary = _active.get("op", {})
	var kind := String(op.get("kind", ""))
	var duration := _action_duration_sec(kind)
	_active["deadline_game_seconds"] = GameClock.game_seconds + duration
	_active_state = "working"
	character._queue_stop_walking()
	character.set("anim_state", "working")
	var label := _action_label_text(kind, op)
	character.head_status().push_override(label)
	character._on_farm_op_started(label, duration)
	_claim_farm_operator(op)
	_report_progress()


func _finish_active() -> void:
	var op: Dictionary = _active.get("op", {})
	var result := _apply_action(op)
	_record_completed(op, result)
	_active = {}
	_active_state = ""
	_release_farm_operator()
	character._on_farm_op_completed(String(result.get("message", "")))
	var result_code := str(result.get("code", ""))
	if result_code == "stamina_depleted" or result_code == "slot_occupied":
		_stop_queue(result_code)
		return
	_report_progress()
	if _queue.is_empty():
		_on_drained()
	else:
		_begin_next()


func _on_drained() -> void:
	character.head_status().clear_override()
	character.set("anim_state", "idle")
	_release_farm_operator()
	character._on_farm_queue_completed(_build_summary(false, ""))


func _stop_queue(reason: String) -> void:
	character.head_status().clear_override()
	character.set("anim_state", "idle")
	_release_farm_operator()
	# 若 op 正处于 working 时被打断（如 stamina_depleted），_finish_active 已 emit completed；
	# 但若是从 walking 状态被打断，没 emit 过 started，所以 cancelled 也安全 noop 在 Player 端。
	character._on_farm_op_cancelled(reason)
	var summary := _build_summary(true, reason)
	_queue.clear()
	character._on_farm_queue_completed(summary)


func _record_completed(op: Dictionary, result: Dictionary) -> void:
	_completed_log.append({
		"kind": String(op.get("kind", "")),
		"slot_index": int(op.get("slot_index", -1)),
		"result": result,
	})


func _build_summary(interrupted: bool, reason: String) -> Dictionary:
	var remaining: Array = []
	var active_kind := ""
	var active_slot_index := -1
	if not _active.is_empty():
		var ao: Dictionary = _active.get("op", {})
		active_kind = String(ao.get("kind", ""))
		active_slot_index = int(ao.get("slot_index", -1))
		remaining.append({
			"kind": active_kind,
			"slot_index": active_slot_index,
		})
	for op in _queue:
		remaining.append({
			"kind": String(op.get("kind", "")),
			"slot_index": int(op.get("slot_index", -1)),
		})
	var summary := {
		"completed": _completed_log.duplicate(true),
		"remaining": remaining,
		"interrupted": interrupted,
		"reason": reason,
	}
	if not active_kind.is_empty():
		summary["active_kind"] = active_kind
		summary["active_slot_index"] = active_slot_index
		summary["active_state"] = _active_state
	return summary


func _report_progress() -> void:
	if character == null or not character.has_method("_on_backend_action_progress"):
		return
	character.call("_on_backend_action_progress", _build_summary(false, ""))


func _action_duration_sec(kind: String) -> float:
	return float(Farming.resolve_action_cost(kind).get("duration_seconds", 0.0))


func _action_target_pos(op: Dictionary) -> Variant:
	var kind := String(op.get("kind", ""))
	if kind == "water":
		var farm: Variant = op.get("farm_node")
		if farm == null or not is_instance_valid(farm):
			return null
		# 走 SiteMarker 组件的寻路到达点（approach_world_position：可选 Approach 子节点
		# 优先，否则自身位置）：FarmGroup origin 常在 plot collider 中央 / 围栏内，NPC 走不到。
		# get_site_marker 找不到 SiteMarker 会 push_error + 返回 null，
		# 这里返回 null 上层 _begin_next 标记 op 失败、跳下一个，不进 walking。
		if farm.get_site_marker() == null:
			return null
		return farm.approach_world_position()
	var slot: Variant = op.get("slot_node")
	if slot == null or not is_instance_valid(slot):
		return null
	return (slot as Node3D).global_position


func _apply_action(op: Dictionary) -> Dictionary:
	var kind := String(op.get("kind", ""))
	match kind:
		"plant":
			return try_plant_seed_at(
				op.get("slot_node") as FarmSlot,
				String(op.get("payload", "")),
				int(op.get("slot_index", -1))
			)
		"pest":
			return try_remove_pest_at(op.get("slot_node") as FarmSlot)
		"harvest":
			return try_harvest_at(op.get("slot_node") as FarmSlot)
		"uproot":
			return try_uproot_at(op.get("slot_node") as FarmSlot)
		"water":
			return try_water_farm_at(op.get("farm_node") as FarmGroup)
	return {"ok": false, "message": "unknown action: %s" % kind}


func _action_label_text(kind: String, op: Dictionary) -> String:
	match kind:
		"plant":
			var item := Items.by_id(String(op.get("payload", "")))
			var name_cn := item.display_name if item != null and not item.display_name.is_empty() else String(op.get("payload", ""))
			return "种植 %s…" % name_cn
		"pest":
			return "除虫…"
		"water":
			return "浇水…"
		"harvest":
			return "收获…"
		"uproot":
			return "铲除…"
	return "工作中…"


# 扣体力 + 失败返回。cost 来自 crops.lua（Farming.resolve_action_cost），
# 不够时附 code=stamina_depleted 让队列停掉。
func _spend_for(kind: String) -> Dictionary:
	var cost := float(Farming.resolve_action_cost(kind).get("stamina_cost", 0.0))
	var spend := StaminaWallet.try_spend(character, cost, "farm:%s" % kind)
	if not bool(spend.get("ok", false)):
		spend["code"] = "stamina_depleted"
	return spend


# 把 wallet 返回值的 stamina_* 字段贴到业务 result 上，供 ack/event chain 透传。
func _annotate(result: Dictionary, spend: Dictionary) -> Dictionary:
	result["stamina_cost"] = float(spend.get("stamina_cost", 0.0))
	result["stamina_before"] = float(spend.get("stamina_before", character.stamina))
	result["stamina_after"] = float(spend.get("stamina_after", character.stamina))
	return result


# ─── private helpers ────────────────────────────────

# 从 active op 反推所属 FarmGroup。slot_node 优先（直接拿父节点）；其次 farm_node。
# 返回空字符串表示这条 op 不绑某片田（试验田 / 节点失效），调用方按 noop 处理。
func _farm_id_for_op(op: Dictionary) -> String:
	var farm_v: Variant = op.get("farm_node")
	if farm_v is FarmGroup and is_instance_valid(farm_v):
		return (farm_v as FarmGroup).effective_farm_id()
	var slot_v: Variant = op.get("slot_node")
	if slot_v is FarmSlot and is_instance_valid(slot_v):
		var parent := (slot_v as FarmSlot).get_parent()
		if parent is FarmGroup:
			return (parent as FarmGroup).effective_farm_id()
	return ""


func _claim_farm_operator(op: Dictionary) -> void:
	var farm_id := _farm_id_for_op(op)
	if farm_id.is_empty():
		return
	var operator_id := character.backend_character_id()
	if operator_id.is_empty():
		return
	_active_farm_id = farm_id
	# Activity 真值落 character_states——backend perception 直接读，不再去 farm 表反查。
	Db.update_character_activity(operator_id, "working_at_farm", farm_id)


# 幂等：未 claim 过 → noop；写盘失败 / 重复进出口路径也安全。
func _release_farm_operator() -> void:
	if _active_farm_id.is_empty():
		return
	_active_farm_id = ""
	Db.clear_character_activity(character.backend_character_id())


# 这片田归 owner_group 时，character 必须是该 group 成员（或 god）才能动土。
# slot 不在任何 FarmGroup 下（试验田 / 装饰）→ 不限制。
# 失败文案故意只露 owner_group 字面值，避免泄露其他 group 的人事关系。
func _check_field_access_for_farm(farm: FarmGroup) -> Dictionary:
	if farm == null or not is_instance_valid(farm):
		return {"ok": true}
	if farm.can_be_used_by(character):
		return {"ok": true}
	return {"ok": false, "message": _fmt("error.farm.access_denied_format", [farm.effective_display_name(), farm.owner_group])}


func _check_field_access_for_slot(slot: FarmSlot) -> Dictionary:
	if slot == null or not is_instance_valid(slot):
		return {"ok": true}
	var parent := slot.get_parent()
	if not (parent is FarmGroup):
		return {"ok": true}
	return _check_field_access_for_farm(parent as FarmGroup)


func _check_field_access_for_crop(crop: Crop) -> Dictionary:
	if crop == null or not is_instance_valid(crop):
		return {"ok": true}
	var farm := crop.owning_farm()
	if farm == null:
		return {"ok": true}
	return _check_field_access_for_farm(farm)


# 找正前方 max_dist 内最近的、属于 group、可选满足 predicate 的 Node3D。
# predicate 是 Callable(node: Node3D) -> bool，留空 = 不过滤。
func _find_facing_node(group: String, max_dist: float, dot_min: float = 0.3, predicate: Callable = Callable()) -> Node3D:
	var forward := character.global_transform.basis.z.normalized()
	var fwd_xz := Vector3(forward.x, 0, forward.z).normalized()
	if fwd_xz.length_squared() < 0.0001:
		return null
	var best: Node3D = null
	var best_dist := max_dist
	for node in character.get_tree().get_nodes_in_group(group):
		if node == character or not node is Node3D:
			continue
		var nd := node as Node3D
		if predicate.is_valid() and not bool(predicate.call(nd)):
			continue
		var to: Vector3 = nd.global_position - character.global_position
		var dist := to.length()
		if dist > best_dist:
			continue
		# 距离 > 0 才校 dot；正好踩在脚下也算"面前"
		if dist > 0.001:
			var to_xz := Vector3(to.x, 0, to.z).normalized()
			if to_xz.dot(fwd_xz) < dot_min:
				continue
		best = nd
		best_dist = dist
	return best


# 给定 slot 反查站在它上面的 Crop（按 OCCUPIED_RADIUS 半径）。空 slot → null。
# 队列 op 都按 slot 寻址，所以 pest/harvest 都通过这个查 crop。
func _crop_on_slot(slot: FarmSlot) -> Crop:
	if slot == null or not is_instance_valid(slot):
		return null
	for n in character.get_tree().get_nodes_in_group("crops"):
		if not n is Crop:
			continue
		var c := n as Crop
		if c.global_position.distance_to(slot.global_position) <= FarmSlot.OCCUPIED_RADIUS:
			return c
	return null


func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
