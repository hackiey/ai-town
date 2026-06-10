class_name WorkstationActionRunner
extends RefCounted

# 工作台运行时执行器。
#
# 边界：
# - Character 只负责暴露薄入口、生命周期 callback 和上下文 snapshot。
# - 本类负责工作台发现、Agent inputs 解析、制作 duration、
#   dispatcher 调用、材料消耗、产物入包和 world_event summary。
# - Player 的 ActionPanel staging 仍由 Player 管 UI/RPC，但 commit outcome 复用这里。

# 可交互距离 = 工作台自己 SiteMarker 的半径（逐对象，SiteMarker.interaction_radius_of）。
# 以工作台自身位置为基准：NPC 寻路到 Approach（≤半径的对象前方点）后从自身量仍在范围内；
# 大型对象的 Approach 必须落在此半径内（SiteMarker 会校验）。
const MINING_TOOL_INPUT_NAME := "pick_head_on_shaft"
# 所有 cost / duration 数值住在 data/mechanics/{crafting,mining,well,crops}.lua。
# 体力扣除统一走 StaminaWallet。本文件不再持有任何 stamina/duration 常量。

# 工作台 craft event 名映射真值由 Crafts autoload 提供（读 data/skills/crafts.json）。
# 见 src/autoload/crafts.gd 与 backend craft-registry.ts —— 三端同一份；不要在这里再起镜像。
# 找不到时回退到工作台 id 作为事件类型 —— 触发后端 fallback renderer，让漏配立刻被看见。
static func _craft_event_name(workstation_id: String, verb: String) -> String:
	var slug: String = Crafts.for_workstation_verb(workstation_id, verb)
	if not slug.is_empty():
		return slug
	push_warning("craft_event_name: no craft mapped for %s|%s — check data/skills/crafts.json" % [workstation_id, verb])
	return workstation_id


# slug → i18n 显示名（"silver_mine_workstation" → "银矿矿井"）。
# 跨 LLM 边界的错误消息必须走这一层，避免把工程 id 漏给 NPC。
# 见 [[feedback_llm_id_name_boundary]]。fallback 到原 slug 仅用于 i18n 缺失的紧急保底。
static func _ws_display_name(workstation_id: String) -> String:
	if workstation_id.is_empty():
		return ""
	var key := "workstation.%s.name" % workstation_id
	var name := TranslationServer.translate(key)
	return name if name != key and not name.is_empty() else workstation_id

var character
var _active: Dictionary = {}
var _town_world_cache = null


func _init(owner) -> void:
	character = owner


# 工作台对象 id —— 与 TownWorld.workstation_logical_id / workstation_states seed 同源。
# perception manifest、active work、busy 占用镜像统一走 WorldObjectIdentity.object_id。
func _workstation_logical_id(ws_node: WorkstationNode) -> String:
	if _town_world_cache == null or not is_instance_valid(_town_world_cache):
		_town_world_cache = character.get_tree().get_first_node_in_group("town_world")
	if _town_world_cache != null and _town_world_cache.has_method("workstation_logical_id"):
		return str(_town_world_cache.call("workstation_logical_id", ws_node))
	return ws_node.world_object_id()


func nearby_snapshots(max_distance: float = Containers.INTERACTION_RADIUS) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var max_sq: float = max_distance * max_distance
	var char_pos_dbg: Vector3 = character.global_position
	for n in character.get_tree().get_nodes_in_group("workstations"):
		if not n is WorkstationNode:
			continue
		# 货架（ShelfNode）虽是 WorkstationNode 子类，但单独走 perceivedShelves 上报（backend
		# 渲染成带标价的货架）；这里排除，避免它又作为无 verb 的"工作台"混进来。
		if n is ShelfNode:
			continue
		var ws_node := n as WorkstationNode
		# 可交互判定以工作台自身位置为基准（NPC 寻路点 approach 另算）。
		var anchor_pos: Vector3 = ws_node.global_position
		var d_dbg: float = char_pos_dbg.distance_to(anchor_pos)
		if char_pos_dbg.distance_squared_to(anchor_pos) > max_sq:
			continue
		# 可见性 = 物理距离；access 不再过滤掉条目，只通过 accessible 字段标记
		var can_use: bool = not ws_node.has_method("can_be_used_by") or ws_node.can_be_used_by(character)
		var ws_def: Workstation = Workstations.by_id(String(ws_node.world_object_def_id()))
		var verbs: PackedStringArray = PackedStringArray()
		var mode: String = "action_panel"
		var slot_count: int = 5
		# 容器（仓库 / 水井 / 货架）身份由节点类型决定，不依赖 Workstation .tres def——
		# 它们不是工作台，只是借用 WorkstationNode 的接近/锁基建。
		if ws_node is ContainerNode:
			mode = "container"
			slot_count = (ws_node as ContainerNode).slot_count
		elif ws_def != null:
			verbs = ws_def.verbs.duplicate()
			mode = ws_def.interaction_mode
			slot_count = ws_def.slot_count
		var snap := {
			"id": _workstation_logical_id(ws_node),
			"workstationId": String(ws_node.world_object_def_id()),
			"displayName": String(ws_node.display_name),
			"directlyInteractable": d_dbg <= SiteMarker.interaction_radius_of(ws_node),
			"interactionMode": mode,
			"verbs": verbs,
			"slotCount": slot_count,
			"locked": ws_node.is_locked(),
			"unlocked": ws_node.is_unlocked_by(character),
			"lockItemId": String(ws_node.world_object_lock_item_id()),
			"accessible": can_use,
		}
		# Container 型 workstation 额外暴露当前库存（让 LLM 知道里面有什么）。
		if mode == "container" and ws_node is ContainerNode:
			var cnode := ws_node as ContainerNode
			snap["displayName"] = cnode.effective_display_name()
			# 容器的身份键回退到纯 effective_container_id（≠ workstation_logical_id 复合 id）。
			# container_states 主键、Containers.system_deposit、铸币/挖矿自动入库、item ownerId
			# 全用这个纯 id；backend assemble 拿 manifest id 去 join container_states，复合 id 会
			# 落空 → 容器从 nearby 列表消失 → put/take "无法识别容器"。复合 id 只是
			# 真工作台为防 node.name 跨铺重名而设；容器本就有 def 级稳定 id，无需复合。
			# 导航（move_to_location）另走 sites 表的复合 id，互不影响。
			snap["id"] = cnode.effective_container_id()
			snap["containerId"] = cnode.effective_container_id()
			if cnode.is_infinite_source():
				# 无限液体源（水井）：报 content，不报 slot 列表。
				snap["infiniteContent"] = cnode.infinite_content
				snap["items"] = []
			else:
				snap["items"] = Containers.detailed_items_for(cnode) if (Containers != null and snap["unlocked"]) else []
		out.append(snap)
	return out


# craft action 的内部靠近目标解析。这里只回答“是否需要先走到工作台旁边”，不校验材料、配方、体力等动作条件；
# 那些仍由 start_from_action 在真正开始工作时统一裁决。
func approach_target_for_action(action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {}
	var t: Dictionary = target as Dictionary
	var workstation_id: String = str(t.get("workstationId", "")).strip_edges()
	if workstation_id.is_empty():
		return {}
	var resolved: Dictionary = _find_workstation_for_approach(workstation_id)
	var ws_node: WorkstationNode = resolved.get("node", null)
	if ws_node == null:
		var reason := str(resolved.get("reason", "not_found"))
		if reason == "not_nearby":
			return {"ok": false, "message": "%s 不在附近" % _ws_display_name(workstation_id)}
		if reason == "access_denied":
			return {"ok": false, "message": "%s 不归你管，无权使用" % _ws_display_name(workstation_id)}
		return {}
	var direct_r: float = SiteMarker.interaction_radius_of(ws_node)
	var d_sq: float = character.global_position.distance_squared_to(ws_node.global_position)
	if d_sq <= direct_r * direct_r:
		return {"ok": true, "needed": false}
	return {
		"ok": true,
		"needed": true,
		"position": ws_node.approach_world_position(),
		"arrival_distance": _arrival_radius_of(ws_node),
	}


func start_from_action(action_request: Dictionary) -> String:
	assert(RunMode.is_runtime(), "WorkstationActionRunner.start_from_action must run on server")
	if not _active.is_empty():
		return "already using workstation"
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return _fail_before_start("", "", "", "invalid_target", "use_workstation target must be object")
	var t: Dictionary = target as Dictionary
	var workstation_id: String = str(t.get("workstationId", "")).strip_edges()
	if workstation_id.is_empty():
		return _fail_before_start("", "", "", "missing_workstation_id", "use_workstation missing workstationId")
	var resolved: Dictionary = _find_workstation(workstation_id)
	var ws_node: WorkstationNode = resolved.get("node", null)
	var ws_name: String = _ws_display_name(workstation_id)
	if ws_node == null:
		var reason: String = str(resolved.get("reason", "not_found"))
		match reason:
			"not_nearby":
				return _fail_before_start(workstation_id, "", "", "workstation_not_nearby", "%s 不在附近，先走过去" % ws_name)
			"access_denied":
				return _fail_before_start(workstation_id, "", "", "workstation_access_denied", "%s 不归你管，无权使用" % ws_name)
			_:
				return _fail_before_start(workstation_id, "", "", "workstation_not_found", "找不到 %s" % ws_name)
	var ws_def: Workstation = Workstations.by_id(String(ws_node.world_object_def_id()))
	if ws_def == null:
		return _fail_before_start(workstation_id, "", "", "unknown_workstation", "未登记的工作台：%s" % ws_name)

	var verb: String = str(t.get("verb", "")).strip_edges()
	if verb.is_empty() and ws_def.verbs.size() == 1:
		verb = ws_def.verbs[0]
	if verb.is_empty():
		return _fail_before_start(ws_def.id, verb, "", "missing_verb", "use_workstation missing verb")
	if not ws_def.verbs.has(verb):
		return _fail_before_start(ws_def.id, verb, "", "unsupported_verb", "%s 不支持「%s」动作" % [ws_name, verb])
	var sub_option: String = str(t.get("subOption", "")).strip_edges()
	var is_mining := _is_mining_action(verb, ws_def.id)
	var input_names: PackedStringArray = _input_names_from_target(t.get("inputItemIds", []))
	if is_mining:
		input_names = _mining_tool_input_names()
		if input_names.is_empty():
			return _fail_before_start(ws_def.id, verb, sub_option, "missing_mining_tool", str(TranslationServer.translate("ui.mine.missing_pick_message")))
	elif input_names.is_empty():
		return _fail_before_start(ws_def.id, verb, sub_option, "inputs_empty", "use_workstation inputs empty", input_names)
	var input_slot_indices: Array[int] = []
	if not is_mining:
		input_slot_indices = _input_slot_indices_from_target(t.get("inputItemSlotIndices", []), input_names.size())
	if input_names.size() > ws_def.slot_count:
		return _fail_before_start(ws_def.id, verb, sub_option, "too_many_inputs", "too many inputs for %s: %d > %d" % [ws_def.id, input_names.size(), ws_def.slot_count], input_names)
	var collected: Dictionary = _collect_inventory_inputs(input_names, input_slot_indices)
	if not bool(collected.get("ok", false)):
		return _fail_before_start(ws_def.id, verb, sub_option, "input_resolution_failed", str(collected.get("message", _msg("error.workstation.input_resolution_failed"))), input_names)
	var instances: Array = collected.get("instances", [])
	var result: Dictionary = Crafting.resolve(verb, ws_def.id, sub_option, instances, character.get_proficiency_table(), Impairment.work_impair(character))
	if str(result.get("outcome", "no_match")) == "no_match":
		return _fail_before_start(ws_def.id, verb, sub_option, "no_matching_reaction", str(result.get("message", _msg("error.workstation.no_matching_reaction"))), input_names)
	var duration: float = float(result.get("duration_seconds", 0.0))
	var label: String = craft_label(verb, ws_def.id, sub_option)
	var mining_cost: Dictionary = Mines.attempt_cost() if is_mining else {}
	if is_mining:
		duration = float(mining_cost.get("duration_seconds", duration))
	# 跨角色单占——容器走 backend_action_runner 独立路径，不经过这里。
	var operator_id: String = character.backend_character_id()
	if not ws_node.try_acquire(operator_id, verb):
		return _fail_before_start(ws_def.id, verb, sub_option, "workstation_busy", "%s 正被人占用，稍等再来" % ws_name, input_names)
	_active = {
		"action_id": str(action_request.get("id", "")),
		"workstation_id": ws_def.id,
		"workstation_node_id": _workstation_logical_id(ws_node),
		"workstation_node": ws_node,
		"operator_id": operator_id,
		"verb": verb,
		"sub_option": sub_option,
		"input_names": input_names,
		"input_ops": collected.get("ops", []),
		"result": result,
		"duration": duration,
		"deadline_game_seconds": GameClock.game_seconds + duration,
		"label": label,
	}
	# Character 侧的 activity 真值——backend perception 直接读 character_states，不再反查站。
	Db.update_character_activity(operator_id, "using_workstation", ws_def.id)
	if is_mining:
		var interval: float = float(mining_cost.get("interval_game_seconds", 0.0))
		_active.merge({
			"mining": true,
			"started_at_game_seconds": GameClock.game_seconds,
			"attempt_interval_game_seconds": interval,
			"stamina_cost_per_attempt": float(mining_cost.get("stamina_cost", 0.0)),
			"stamina_spent": 0.0,
			"next_attempt_game_seconds": GameClock.game_seconds + interval,
			"attempts": 0,
			"successful_attempts": 0,
			"mining_diverted": [],
			"mining_totals": {},
			"broken_tools": [],
		}, true)
	character.set("anim_state", "working")
	character.show_action_label_rpc.rpc("%s…" % label)
	_report_progress()
	if duration <= 0.0:
		_commit_active()
	return ""


func is_active() -> bool:
	return not _active.is_empty()


func cancel(reason: String = "cancelled") -> Dictionary:
	if _active.is_empty():
		return {}
	if bool(_active.get("mining", false)):
		return _finish_active_mining(true, reason, false)
	var active: Dictionary = _active.duplicate(true)
	_active = {}
	_release_workstation_from_active(active)
	Db.clear_character_activity(character.backend_character_id())
	character.hide_action_label_rpc.rpc()
	character.set("anim_state", "idle")
	character.perception().send_manifest()
	return {
		"actionCompleted": false,
		"cancelled": true,
		"reason": reason,
		"workstation_id": str(active.get("workstation_id", "")),
		"verb": str(active.get("verb", "")),
		"sub_option": str(active.get("sub_option", "")),
	}


func tick(_delta: float) -> void:
	if _active.is_empty():
		return
	if bool(_active.get("mining", false)):
		_tick_active_mining()
		return
	var deadline: float = float(_active.get("deadline_game_seconds", 0.0))
	if GameClock.game_seconds >= deadline:
		_commit_active()


func _report_progress() -> void:
	if _active.is_empty():
		return
	if character == null or not character.has_method("_on_backend_action_progress"):
		return
	var deadline: float = float(_active.get("deadline_game_seconds", GameClock.game_seconds))
	var summary := {
		"actionCompleted": false,
		"inProgress": true,
		"workstation_id": str(_active.get("workstation_id", "")),
		"verb": str(_active.get("verb", "")),
		"sub_option": str(_active.get("sub_option", "")),
		"inputs": _active.get("input_names", []),
		"duration": float(_active.get("duration", 0.0)),
		"remaining_game_seconds": maxf(0.0, deadline - GameClock.game_seconds),
		"label": str(_active.get("label", "")),
		"message": _fmt("tool.tool_result.workstation.in_progress_format", [str(_active.get("label", _msg("tool.tool_result.workstation.default_label")))]),
	}
	if bool(_active.get("mining", false)):
		var mining_totals: Dictionary = _active.get("mining_totals", {})
		var attempts: int = int(_active.get("attempts", 0))
		summary.merge({
			"elapsed_game_seconds": _active_elapsed_seconds(_active),
			"attempt_interval_game_seconds": float(_active.get("attempt_interval_game_seconds", 0.0)),
			"stamina_cost_per_attempt": float(_active.get("stamina_cost_per_attempt", 0.0)),
			"stamina_spent": float(_active.get("stamina_spent", 0.0)),
			"attempts": attempts,
			"successful_attempts": int(_active.get("successful_attempts", 0)),
			"outputs": _mining_output_labels(mining_totals),
			"mining_totals": mining_totals.duplicate(true),
		}, true)
	character.call("_on_backend_action_progress", summary)


func _is_mining_action(verb: String, workstation_id: String) -> bool:
	return verb == "dig" and Mines.is_mine(workstation_id)


func _tick_active_mining() -> void:
	var deadline: float = float(_active.get("deadline_game_seconds", 0.0))
	var interval: float = maxf(1.0, float(_active.get("attempt_interval_game_seconds", 0.0)))
	var next_attempt: float = float(_active.get("next_attempt_game_seconds", GameClock.game_seconds + interval))
	var did_attempt := false
	while not _active.is_empty() and next_attempt <= deadline and GameClock.game_seconds >= next_attempt:
		did_attempt = true
		if _run_mining_attempt(next_attempt):
			return
		next_attempt += interval
		if not _active.is_empty():
			_active["next_attempt_game_seconds"] = next_attempt
	if _active.is_empty():
		return
	if GameClock.game_seconds >= deadline:
		_finish_active_mining(false, "", true)
	elif did_attempt:
		_report_progress()


# 每个采矿间隔进行一次产出判定，并立刻把矿石入国库或矿工背包/写 mining_log。
# 国营矿（金/银）走 treasury_vault；私营矿（铁）直接进矿工 inventory。
func _run_mining_attempt(attempt_game_seconds: float) -> bool:
	var ws_id: String = str(_active.get("workstation_id", ""))
	var cost := float(_active.get("stamina_cost_per_attempt", 0.0))
	var spend := StaminaWallet.try_spend(character, cost, "mining:attempt")
	if not bool(spend.get("ok", false)):
		_active["ended_at_game_seconds"] = attempt_game_seconds
		_finish_active_mining(false, "stamina_depleted", true)
		return true
	_active["stamina_spent"] = float(_active.get("stamina_spent", 0.0)) + float(spend.get("stamina_cost", 0.0))
	_active["attempts"] = int(_active.get("attempts", 0)) + 1
	if Mines.try_yield(ws_id, Impairment.work_impair(character)):
		_active["successful_attempts"] = int(_active.get("successful_attempts", 0)) + 1
		var result: Dictionary = _active.get("result", {})
		_append_mining_diverted(_deposit_mining_outputs(result, attempt_game_seconds))
		# 每次成功 yield 都按真实 p 计算一次 gain（lua 给出 difficulty + skill_id；
		# q 从 result.outputs 第一项的 quality 取，最低 50 兜底）。
		# Mines.try_yield = false 不计为 skill failure（是矿脉枯竭/运气，不是手艺问题），
		# 所以这里不调 proficiency_gain(succeeded=false)。
		_apply_mining_proficiency_gain(result)
	var broken_tools: Array[String] = _wear_tool_inputs(_active.get("input_ops", []))
	if not broken_tools.is_empty():
		var existing: Array = _active.get("broken_tools", [])
		for tool in broken_tools:
			existing.append(tool)
		_active["broken_tools"] = existing
		_active["ended_at_game_seconds"] = attempt_game_seconds
		_finish_active_mining(false, "tool_broken", true)
		return true
	return false


func _apply_mining_proficiency_gain(result: Dictionary) -> void:
	var skill_id: String = str(result.get("proficiency_skill_id", ""))
	if skill_id.is_empty():
		return
	var cid: String = character.backend_character_id()
	if cid.is_empty():
		return
	# 每次都重读 p，让多次成功的连续 gain 真正"递减"（不是用 craft 启动时的 stale p）。
	var prof_table: Dictionary = character.get_proficiency_table()
	var p: float = float(prof_table.get(skill_id, 0.0))
	var d: float = float(result.get("difficulty", 0.0))
	var outputs: Array = result.get("outputs", [])
	var q: float = 50.0
	if not outputs.is_empty():
		var first: Dictionary = outputs[0]
		q = float(first.get("quality", 50))
	var gain_v: Variant = MechanicHost.query("crafting", "proficiency_gain", [p, d, q, true])
	var gain: float = float(gain_v) if gain_v != null else 0.0
	if absf(gain) < 0.0001:
		return
	var after: float = clampf(p + gain, 0.0, 100.0)
	Db.upsert_proficiency(cid, skill_id, after)


func _deposit_mining_outputs(result: Dictionary, attempt_game_seconds: float) -> Array:
	var diverted: Array = []
	var actor_id: String = character.backend_character_id()
	var ws_id: String = str(_active.get("workstation_id", ""))
	var to_treasury: bool = Mines.routes_to_treasury(ws_id)
	var total_hours := int(floor(attempt_game_seconds / 3600.0))
	var game_day := int(total_hours / 24)
	var game_hour := total_hours % 24
	for inst_v in result.get("outputs", []):
		var inst: Dictionary = inst_v
		var iid := str(inst.get("item_id", ""))
		var qty := int(inst.get("quantity", 1))
		if iid.is_empty() or qty <= 0:
			continue
		var quality: int = int(inst.get("quality", 100))
		if to_treasury:
			var dep := Containers.system_deposit("treasury_vault", iid, qty, quality)
			if not bool(dep.get("ok", false)):
				push_warning("[Mining] divert to vault failed (%s x%d): %s" % [iid, qty, dep.get("message", "?")])
				continue
		else:
			var leftover: int = character.inventory_ops().add_item(iid, qty, quality)
			var taken: int = qty - leftover
			if taken <= 0:
				push_warning("[Mining] inventory full, dropped %s x%d" % [iid, qty])
				continue
			qty = taken
		Db.log_mining(actor_id, iid, qty, game_day, game_hour)
		diverted.append({"item_id": iid, "quantity": qty})
	return diverted


func _append_mining_diverted(diverted: Array) -> void:
	if diverted.is_empty():
		return
	var all_diverted: Array = _active.get("mining_diverted", [])
	var totals: Dictionary = _active.get("mining_totals", {})
	for d_v in diverted:
		var d: Dictionary = d_v
		var item_id := str(d.get("item_id", ""))
		var qty := int(d.get("quantity", 0))
		if item_id.is_empty() or qty <= 0:
			continue
		all_diverted.append(d)
		totals[item_id] = int(totals.get(item_id, 0)) + qty
	_active["mining_diverted"] = all_diverted
	_active["mining_totals"] = totals


func _finish_active_mining(interrupted: bool, reason: String, notify_completion: bool) -> Dictionary:
	if _active.is_empty():
		return {}
	var active: Dictionary = _active.duplicate(true)
	_active = {}
	_release_workstation_from_active(active)
	Db.clear_character_activity(character.backend_character_id())
	character.hide_action_label_rpc.rpc()
	character.set("anim_state", "idle")
	var summary := _build_mining_summary(active, interrupted, reason)
	_send_world_event(summary)
	character.perception().send_manifest()
	if notify_completion:
		character._on_workstation_action_completed(summary)
	return summary


func _build_mining_summary(active: Dictionary, interrupted: bool, reason: String) -> Dictionary:
	var totals: Dictionary = active.get("mining_totals", {})
	var diverted: Array = active.get("mining_diverted", [])
	var outputs := _mining_output_labels(totals)
	var elapsed := _active_elapsed_seconds(active)
	var duration := float(active.get("duration", 0.0))
	var attempts := int(active.get("attempts", 0))
	var summary := {
		"actionCompleted": true,
		"ok": true,
		"outcome": "success",
		"workstation_id": str(active.get("workstation_id", "")),
		"verb": str(active.get("verb", "")),
		"sub_option": str(active.get("sub_option", "")),
		"inputs": active.get("input_names", []),
		"duration": duration,
		"elapsed_game_seconds": elapsed,
		"remaining_game_seconds": maxf(0.0, duration - elapsed),
		"attempt_interval_game_seconds": float(active.get("attempt_interval_game_seconds", 0.0)),
		"stamina_cost_per_attempt": float(active.get("stamina_cost_per_attempt", 0.0)),
		"stamina_spent": float(active.get("stamina_spent", 0.0)),
		"attempts": attempts,
		"successful_attempts": int(active.get("successful_attempts", 0)),
		"outputs": outputs,
		"mining_diverted": diverted.duplicate(true),
		"mining_totals": totals.duplicate(true),
		"message": _mining_message(active, interrupted, reason, outputs, elapsed),
	}
	if interrupted:
		summary["interrupted"] = true
	if not reason.is_empty():
		summary["reason"] = reason
	var broken_tools: Array = active.get("broken_tools", [])
	if not broken_tools.is_empty():
		summary["broken_tools"] = broken_tools.duplicate(true)
	return summary


func _mining_message(active: Dictionary, interrupted: bool, reason: String, outputs: Array[String], elapsed_seconds: float) -> String:
	var elapsed_minutes := int(floor(elapsed_seconds / 60.0))
	var attempts := int(active.get("attempts", 0))
	var successes := int(active.get("successful_attempts", 0))
	var stamina_spent := float(active.get("stamina_spent", 0.0))
	var ws_id: String = str(active.get("workstation_id", ""))
	var dest_text := "已自动入国库" if Mines.routes_to_treasury(ws_id) else "已收入背包"
	var output_text := "未挖到矿石" if outputs.is_empty() else "挖到 %s，%s" % ["、".join(outputs), dest_text]
	var progress_text := "已工作 %d 分钟，产出判断 %d 次，成功 %d 次，消耗体力 %.0f，%s" % [elapsed_minutes, attempts, successes, stamina_spent, output_text]
	if interrupted:
		return "采矿被打断：%s" % progress_text
	if reason == "stamina_depleted":
		return "采矿提前结束：体力不足，%s" % progress_text
	if reason == "tool_broken":
		return "采矿提前结束：工具用坏，%s" % progress_text
	return "采矿完成：%s" % progress_text


func _mining_output_labels(totals_value: Variant) -> Array[String]:
	var labels: Array[String] = []
	if not (totals_value is Dictionary):
		return labels
	var totals: Dictionary = totals_value
	for item_id_v in totals.keys():
		var item_id := str(item_id_v)
		var qty := int(totals.get(item_id, 0))
		if qty > 0:
			labels.append("%s x%d" % [item_id, qty])
	return labels


func _active_elapsed_seconds(active: Dictionary) -> float:
	var started := float(active.get("started_at_game_seconds", GameClock.game_seconds))
	var ended := float(active.get("ended_at_game_seconds", GameClock.game_seconds))
	var duration := float(active.get("duration", 0.0))
	return clampf(ended - started, 0.0, duration)


func _commit_active() -> void:
	if _active.is_empty():
		return
	var active: Dictionary = _active.duplicate(true)
	_active = {}
	_release_workstation_from_active(active)
	Db.clear_character_activity(character.backend_character_id())
	character.hide_action_label_rpc.rpc()
	character.set("anim_state", "idle")
	var result: Dictionary = active.get("result", {})

	# 矿场反馈控制：dig 反应到此处时 dispatcher 已给 success（difficulty=0）。
	# 由 Mines.try_yield 用 mine_state.currentP 决定本次是否真的产出。
	# 失败时把 result 改成 failure，并把"会被消耗的输入"挪到 returned（镐子已经
	# 因 tool=true 不在 consumed 里，这里只是统一维护语义）。
	# 成功时把矿石直接 deposit 进国库（绕过矿工背包）；入库成功才写 mining_log。
	var verb: String = str(active.get("verb", ""))
	var ws_id: String = str(active.get("workstation_id", ""))
	var mining_diverted: Array = []
	if verb == "dig" and Mines.is_mine(ws_id):
		var lucky: bool = Mines.try_yield(ws_id, Impairment.work_impair(character))
		if not lucky:
			var consumed_idx: Array = result.get("consumed_input_indices", [])
			var returned_idx: Array = result.get("returned_input_indices", []).duplicate()
			for s in consumed_idx:
				returned_idx.append(int(s))
			result = result.duplicate(true)
			result["outcome"] = "failure"
			result["outputs"] = []
			result["consumed_input_indices"] = []
			result["returned_input_indices"] = returned_idx
			result["fail_mode_name"] = TranslationServer.translate("ui.mine.fail_label")
			result["message"] = TranslationServer.translate("ui.mine.fail_message")
		else:
			# 国营矿（金/银）转 treasury_vault 并清空 outputs，避免 apply_outputs_to_character 重复入包；
			# 私营矿（铁）保留 outputs 走标准 craft 路径直接入矿工背包，只额外写 mining_log。
			var actor_id: String = character.backend_character_id()
			var g_day: int = GameClock.game_day()
			var g_hour: int = GameClock.game_hour()
			var to_treasury: bool = Mines.routes_to_treasury(ws_id)
			for inst_v in result.get("outputs", []):
				var inst: Dictionary = inst_v
				var iid := str(inst.get("item_id", ""))
				var qty := int(inst.get("quantity", 1))
				if iid.is_empty() or qty <= 0:
					continue
				if to_treasury:
					var dep := Containers.system_deposit("treasury_vault", iid, qty, int(inst.get("quality", 100)))
					if not bool(dep.get("ok", false)):
						push_warning("[Mining] divert to vault failed (%s x%d): %s" % [iid, qty, dep.get("message", "?")])
						continue
					mining_diverted.append({"item_id": iid, "quantity": qty})
				Db.log_mining(actor_id, iid, qty, g_day, g_hour)
			if to_treasury:
				result = result.duplicate(true)
				result["outputs"] = []
				result["mining_diverted"] = mining_diverted

	# 体力扣除：reaction.stamina_cost 在 commit 时扣（cancelled/失败前置校验路径不扣）。
	# 所有 craft/dig 反应必经此处，新增反应不需要 runner 改动——cost 由 lua 透传。
	var reaction_id: String = str(result.get("reaction_id", str(active.get("verb", ""))))
	var spend := StaminaWallet.try_spend(character, float(result.get("stamina_cost", 0.0)), "craft:%s" % reaction_id)
	if not bool(spend.get("ok", false)):
		var stamina_failed: Dictionary = {
			"actionCompleted": false,
			"ok": false,
			"outcome": "failed",
			"workstation_id": str(active.get("workstation_id", "")),
			"verb": str(active.get("verb", "")),
			"sub_option": str(active.get("sub_option", "")),
			"reason": "stamina_depleted",
			"message": str(spend.get("message", _msg("error.workstation.stamina_not_enough"))),
			"stamina_cost": float(spend.get("stamina_cost", 0.0)),
			"stamina_before": float(spend.get("stamina_before", character.stamina)),
			"stamina_after": float(spend.get("stamina_after", character.stamina)),
		}
		character._on_workstation_action_completed(stamina_failed)
		return

	var consume: Dictionary = _consume_inventory_inputs(result.get("consumed_input_indices", []), active.get("input_ops", []))
	if not bool(consume.get("ok", false)):
		var failed_summary: Dictionary = {
			"actionCompleted": false,
			"ok": false,
			"outcome": "failed",
			"workstation_id": str(active.get("workstation_id", "")),
			"verb": str(active.get("verb", "")),
			"sub_option": str(active.get("sub_option", "")),
			"message": str(consume.get("message", _msg("error.workstation.consume_inputs_failed"))),
		}
		character._on_workstation_action_completed(failed_summary)
		return

	# 工具耐久：reaction.inputs 里 tool=true 的 slot 在 consume 阶段没被移除，
	# 由这里扣 1 点耐久；归零则报废清空。每个 op 只扣一次。
	var broken_tools: Array[String] = _wear_tool_inputs(active.get("input_ops", []))

	var summary: Dictionary = apply_outputs_to_storage(character, active.get("workstation_node", null) as WorkstationNode, result, {
		"workstation_id": str(active.get("workstation_id", "")),
		"verb": str(active.get("verb", "")),
		"sub_option": str(active.get("sub_option", "")),
		"inputs": active.get("input_names", []),
		"consumed_inputs": _input_names_by_indices(active.get("input_names", []), result.get("consumed_input_indices", [])),
		"returned_inputs": _input_names_by_indices(active.get("input_names", []), result.get("returned_input_indices", [])),
		"stamina_cost": float(spend.get("stamina_cost", 0.0)),
		"stamina_before": float(spend.get("stamina_before", character.stamina)),
		"stamina_after": float(spend.get("stamina_after", character.stamina)),
	})
	# 矿石被 divert 到国库的话，把 message/outputs 改成"已入国库"格式
	if not mining_diverted.is_empty():
		var divert_parts: Array[String] = []
		var divert_outputs: Array[String] = []
		for d in mining_diverted:
			var label := "%s x%d" % [str(d.get("item_id", "")), int(d.get("quantity", 0))]
			divert_parts.append(label)
			divert_outputs.append(label)
		summary["message"] = _fmt("tool.tool_result.workstation.mining_diverted_format", [_msg("tool.tool_result.list_separator").join(divert_parts)])
		summary["outputs"] = divert_outputs
		summary["mining_diverted"] = mining_diverted
	if not broken_tools.is_empty():
		var msg: String = str(summary.get("message", ""))
		var broken_msg: String = TranslationServer.translate("ui.tool.broken_format") % ", ".join(broken_tools)
		summary["message"] = "%s\n%s" % [msg, broken_msg] if not msg.is_empty() else broken_msg
		summary["broken_tools"] = broken_tools
	# 熟练度成长：把 lua 返回的 delta 应用回 Db。Mining 走 Mines.try_yield 决定成败，
	# lua 的 delta 不一定匹配真实 outcome —— 暂跳过，单独走 _apply_mining_proficiency_gain。
	# 见 docs/proficiency_system.md。
	#
	# Surface 策略两档：
	#   1. skill_id / before / difficulty —— 任何非 mining 反应都打入 summary，让事件渲染
	#      能给失败因果（"难度 X / 你熟练度 Y / 料子状态"）。要求 lua 返回这三项；C-#3 之前
	#      只在 |delta|≥0.5 时才暴露，导致新手失败因果信息缺失。
	#   2. after / delta —— 仍 gated 在 |delta|>0.0001 才入 summary（也仅此时写 Db）；
	#      下游 renderProficiencySuffix 用 |delta|≥0.5 二次门槛决定要不要显示"长进/退步"行。
	var verb_str: String = str(summary.get("verb", ""))
	if verb_str != "dig":
		var skill_id: String = str(result.get("proficiency_skill_id", ""))
		if not skill_id.is_empty():
			var before: float = float(result.get("proficiency_before", 0.0))
			summary["proficiency_skill_id"] = skill_id
			summary["proficiency_before"] = before
			summary["difficulty"] = float(result.get("difficulty", 0.0))
			var delta: float = float(result.get("proficiency_delta", 0.0))
			if absf(delta) > 0.0001:
				var after: float = clampf(before + delta, 0.0, 100.0)
				Db.upsert_proficiency(character.backend_character_id(), skill_id, after)
				summary["proficiency_after"] = after
				summary["proficiency_delta"] = after - before
	_send_world_event(summary)
	character.perception().send_manifest()
	character._on_workstation_action_completed(summary)


static func apply_outputs_to_storage(owner, storage_node: WorkstationNode, result: Dictionary, base_summary: Dictionary = {}) -> Dictionary:
	var outcome: String = str(result.get("outcome", "failure"))
	var outputs: Array[String] = []
	var leftovers: Array[String] = []
	if outcome == "success":
		for inst_v in result.get("outputs", []):
			var inst: Dictionary = inst_v
			var qty: int = int(inst.get("quantity", 1))
			var added := 0
			var leftover := qty
			if storage_node != null and is_instance_valid(storage_node) and Containers != null:
				var stack := inst.duplicate(true)
				stack["quantity"] = qty
				var placed := Containers.adapter_place(storage_node, [stack])
				added = int(placed.get("placed_qty", 0))
				leftover = _sum_stack_quantities(placed.get("leftover", []))
			else:
				leftover = int(owner.inventory_ops().add_instance(inst, qty))
				added = qty - leftover
			var name: String = InventorySlotData.of(inst).display_name()
			outputs.append("%s x%d" % [name, added])
			if leftover > 0:
				leftovers.append("%s x%d" % [name, leftover])
	var message: String = ""
	if outcome == "success":
		message = _fmt("tool.tool_result.workstation.success_outputs_format", [", ".join(outputs)]) if not outputs.is_empty() else _msg("tool.tool_result.workstation.success")
	else:
		var fname: String = str(result.get("fail_mode_name", _msg("tool.tool_result.workstation.failure")))
		var msg: String = str(result.get("message", ""))
		message = _fmt("tool.tool_result.workstation.failure_format", [fname, msg])
	var summary: Dictionary = base_summary.duplicate(true)
	summary.merge({
		"actionCompleted": true,
		"ok": outcome == "success",
		"outcome": outcome,
		"outputs": outputs,
		"leftover_outputs": leftovers,
		"quality_modifier": float(result.get("quality_modifier", 1.0)),
		"message": message,
		# Surface lua's failure category to backend event renderer (workstation.ts)。
		# 料子折损情况不进 event —— actor 看 tool_response 的 character_changes 已经
		# 能知道（"失去 X x1"），event 不再做冗余表达。
		"fail_mode_name": str(result.get("fail_mode_name", "")),
	}, true)
	return summary


static func _sum_stack_quantities(value: Variant) -> int:
	var total := 0
	if value is Array:
		for v in value:
			if v is Dictionary:
				total += int((v as Dictionary).get("quantity", 0))
	return total


static func consume_staged_inputs(staged_items: Array, staged_indices: PackedInt32Array, consumed_input_indices: Array) -> bool:
	var changed: bool = false
	for input_idx in consumed_input_indices:
		var staged_slot: int = int(staged_indices[int(input_idx)])
		var s: Dictionary = staged_items[staged_slot]
		s["quantity"] = int(s.get("quantity", 0)) - 1
		if int(s["quantity"]) <= 0:
			staged_items[staged_slot] = InventorySlotData.empty()
		else:
			staged_items[staged_slot] = s
		changed = true
	return changed


static func poured_content_instance(bucket: Dictionary, content_id: String) -> Dictionary:
	var item_id: String = Items.find_template("fluid_pouch", content_id)
	if item_id.is_empty():
		item_id = content_id
	# 走 from_template 让所有 typed aspect 字段（freshness/durability/base_effects）按
	# 模板初始化 —— 一致于其它产物入背包的路径，避免再手写一份 schema。
	var inst := InventorySlotData.from_template(item_id, int(bucket.get("quality", 100)))
	inst["quantity"] = 1
	# 兜底：item registry 没有该 item_id 时（content_id 本身不在 Items 里），
	# from_template 已经留空 shape_type/materials/tags，这里强制按 "fluid_pouch" body=content_id 填。
	if Items.by_id(item_id) == null:
		inst["shape_type"] = "fluid_pouch"
		inst["materials"] = {"body": content_id}
		inst["tags"] = PackedStringArray(["liquid"])
	return inst


static func craft_label(verb: String, workstation_id: String, sub_option: String) -> String:
	var verb_def: Verb = Verbs.by_id(verb)
	var verb_name: String = verb_def.display_name if verb_def != null and not verb_def.display_name.is_empty() else verb
	var ws_def: Workstation = Workstations.by_id(workstation_id)
	var ws_name: String = ws_def.display_name if ws_def != null and not ws_def.display_name.is_empty() else workstation_id
	if sub_option.is_empty():
		return "%s · %s" % [ws_name, verb_name]
	return "%s · %s (%s)" % [ws_name, verb_name, sub_option]


# 返回 {"node": WorkstationNode?, "reason": "" | "not_found" | "not_nearby" | "access_denied"}.
# 区分三种失败：world 里没有这个 id / 有但距离过远 / 距离够近但节点拒绝使用。
func _find_workstation(workstation_id: String) -> Dictionary:
	var requested: String = _normalize_input(workstation_id)
	var matched_any: bool = false
	var in_range_any: bool = false
	var best: WorkstationNode = null
	var best_sq: float = INF
	for n in character.get_tree().get_nodes_in_group("workstations"):
		if not n is WorkstationNode:
			continue
		var ws: WorkstationNode = n as WorkstationNode
		var aliases: Array[String] = [
			_workstation_logical_id(ws),
			String(ws.world_object_def_id()),
			String(ws.display_name),
		]
		var matches: bool = false
		for alias in aliases:
			if _normalize_input(alias) == requested:
				matches = true
				break
		if not matches:
			continue
		matched_any = true
		# 可交互判定以工作台自身位置为基准，半径用该工作台 SiteMarker 的可交互距离（逐对象）。
		var ws_r: float = SiteMarker.interaction_radius_of(ws)
		var d: float = character.global_position.distance_squared_to(ws.global_position)
		if d > ws_r * ws_r:
			continue
		in_range_any = true
		if ws.has_method("can_be_used_by") and not ws.can_be_used_by(character):
			continue
		if d <= best_sq:
			best = ws
			best_sq = d
	if best != null:
		return {"node": best, "reason": ""}
	if not matched_any:
		return {"node": null, "reason": "not_found"}
	if not in_range_any:
		return {"node": null, "reason": "not_nearby"}
	return {"node": null, "reason": "access_denied"}


# 自动靠近用：匹配同一套工作台别名，但允许目标在工作台可见范围内、直接交互范围外。
func _find_workstation_for_approach(workstation_id: String) -> Dictionary:
	var requested: String = _normalize_input(workstation_id)
	var matched_any: bool = false
	var visible_any: bool = false
	var best: WorkstationNode = null
	var best_sq: float = INF
	var visible_r: float = CharacterPerception.INTERACTIVE_WORKSTATION_VISIBLE_RADIUS
	for n in character.get_tree().get_nodes_in_group("workstations"):
		if not n is WorkstationNode:
			continue
		var ws: WorkstationNode = n as WorkstationNode
		var aliases: Array[String] = [
			_workstation_logical_id(ws),
			String(ws.world_object_def_id()),
			String(ws.display_name),
		]
		var matches: bool = false
		for alias in aliases:
			if _normalize_input(alias) == requested:
				matches = true
				break
		if not matches:
			continue
		matched_any = true
		var d: float = character.global_position.distance_squared_to(ws.global_position)
		if d > visible_r * visible_r:
			continue
		visible_any = true
		if ws.has_method("can_be_used_by") and not ws.can_be_used_by(character):
			continue
		if d <= best_sq:
			best = ws
			best_sq = d
	if best != null:
		return {"node": best, "reason": ""}
	if not matched_any:
		return {"node": null, "reason": "not_found"}
	if not visible_any:
		return {"node": null, "reason": "not_nearby"}
	return {"node": null, "reason": "access_denied"}


func _arrival_radius_of(ws_node: WorkstationNode) -> float:
	var marker := ws_node.get_node_or_null("SiteMarker") as SiteMarker
	if marker != null:
		return marker.eff_arrival_radius()
	return character.walk().default_arrival_distance()


func _input_names_from_target(value: Variant) -> PackedStringArray:
	# Wire contract: inputItemIds is Array[String]. (See actions.ts UseWorkstationTarget.)
	var out: PackedStringArray = PackedStringArray()
	if typeof(value) != TYPE_ARRAY:
		return out
	for entry_v in (value as Array):
		if typeof(entry_v) == TYPE_STRING:
			var name: String = str(entry_v).strip_edges()
			if not name.is_empty():
				out.append(name)
	return out


func _input_slot_indices_from_target(value: Variant, expected_size: int) -> Array[int]:
	# inputItemSlotIndices mirrors inputItemIds. -1 means "no exact slot provided".
	var out: Array[int] = []
	for _i in expected_size:
		out.append(-1)
	if typeof(value) != TYPE_ARRAY:
		return out
	var entries: Array = value as Array
	for i in mini(expected_size, entries.size()):
		var entry_v: Variant = entries[i]
		if typeof(entry_v) == TYPE_INT or typeof(entry_v) == TYPE_FLOAT:
			out[i] = int(entry_v)
	return out


func _collect_inventory_inputs(input_names: PackedStringArray, input_slot_indices: Array[int] = []) -> Dictionary:
	var instances: Array = []
	var ops: Array = []
	for idx in input_names.size():
		var input_name: String = input_names[idx]
		var preferred_slot_index: int = input_slot_indices[idx] if idx < input_slot_indices.size() else -1
		var resolved: Dictionary = _resolve_inventory_input_unit(input_name, ops, preferred_slot_index)
		if not bool(resolved.get("ok", false)):
			return resolved
		instances.append(resolved.get("instance", {}))
		ops.append(resolved.get("op", {}))
	return {"ok": true, "instances": instances, "ops": ops}


# 所有终态（commit/cancel/mining 终态）走这一条释放锁。优先用 _active 里持有的
# node 引用；节点已 free 时退到 node_id 反查（rare：在 ws 节点销毁同帧才会发生）。
func _release_workstation_from_active(active: Dictionary) -> void:
	var operator_id: String = str(active.get("operator_id", character.backend_character_id()))
	var ws_node: WorkstationNode = active.get("workstation_node", null) as WorkstationNode
	if ws_node != null and is_instance_valid(ws_node):
		ws_node.release(operator_id)
		return
	# Fallback：节点已不在树里，直接清 DB 镜像（节点 _exit_tree 自己也会清，幂等）。
	# 多占场景下这里粗暴清零会把别人的 count 也清掉——节点已 free 时该镜像本就要被
	# boot 端重建，不存在长效危害；且这条 fallback 仅在节点销毁同帧触发，极罕见。
	var node_id := str(active.get("workstation_node_id", ""))
	if not node_id.is_empty():
		Db.set_workstation_occupants(node_id, "", "", 0)


func _fail_before_start(workstation_id: String, verb: String, sub_option: String, reason: String, message: String, input_names: Variant = []) -> String:
	character._on_workstation_action_completed({
		"actionCompleted": false,
		"ok": false,
		"outcome": "failed",
		"workstation_id": workstation_id,
		"verb": verb,
		"sub_option": sub_option,
		"inputs": _input_names_to_array(input_names),
		"reason": reason,
		"message": message,
	})
	return ""


func _mining_tool_input_names() -> PackedStringArray:
	var out := PackedStringArray()
	for i in character.inventory.size():
		var slot: Dictionary = character.inventory[i]
		var view: InventorySlotData = InventorySlotData.of(slot)
		if view.is_empty():
			continue
		if not _slot_is_mining_tool(view):
			continue
		out.append(view.id())
		return out
	return out


func _slot_is_mining_tool(view: InventorySlotData) -> bool:
	if _slot_matches_input(view, MINING_TOOL_INPUT_NAME):
		return true
	var tmpl: Item = view.template()
	return tmpl != null and tmpl.kind == "tool" and tmpl.properties.has("can_mine")


func _input_names_to_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(value) == TYPE_PACKED_STRING_ARRAY:
		var packed: PackedStringArray = value as PackedStringArray
		for name_v in packed:
			var packed_name: String = str(name_v).strip_edges()
			if not packed_name.is_empty():
				out.append(packed_name)
		return out
	if typeof(value) == TYPE_ARRAY:
		for entry_v in (value as Array):
			if typeof(entry_v) == TYPE_STRING:
				var array_name: String = str(entry_v).strip_edges()
				if not array_name.is_empty():
					out.append(array_name)
	return out


func _resolve_inventory_input_unit(input_name: String, selected_ops: Array, preferred_slot_index: int = -1) -> Dictionary:
	if preferred_slot_index >= 0:
		return _resolve_inventory_input_unit_at_slot(input_name, selected_ops, preferred_slot_index)
	for i in character.inventory.size():
		var slot: Dictionary = character.inventory[i]
		var view: InventorySlotData = InventorySlotData.of(slot)
		if view.is_empty():
			continue
		if not _slot_matches_input(view, input_name):
			continue
		var available: int = view.quantity() - _selected_remove_count(selected_ops, i)
		if available <= 0:
			continue
		var inst: Dictionary = slot.duplicate(true)
		inst["quantity"] = 1
		return {
			"ok": true,
			"instance": inst,
			"op": {"type": "remove", "slot_index": i, "item_id": view.id()},
		}
	for i in character.inventory.size():
		var slot: Dictionary = character.inventory[i]
		var view: InventorySlotData = InventorySlotData.of(slot)
		var container: ContainerAspect = view.as_container()
		if container == null or container.is_empty():
			continue
		if not _content_matches_input(container.content_id(), input_name):
			continue
		var available_liquid: int = int(floor(container.amount())) - _selected_pour_count(selected_ops, i)
		if available_liquid <= 0:
			continue
		return {
			"ok": true,
			"instance": poured_content_instance(slot, container.content_id()),
			"op": {"type": "pour", "slot_index": i, "content_id": container.content_id()},
		}
	return {"ok": false, "message": _fmt("error.workstation.input_missing_format", [input_name])}


func _resolve_inventory_input_unit_at_slot(input_name: String, selected_ops: Array, slot_index: int) -> Dictionary:
	if slot_index < 0 or slot_index >= character.inventory.size():
		return {"ok": false, "message": _fmt("error.workstation.backpack_slot_missing_format", [slot_index])}
	var slot: Dictionary = character.inventory[slot_index]
	var view: InventorySlotData = InventorySlotData.of(slot)
	if view.is_empty():
		return {"ok": false, "message": _fmt("error.workstation.input_changed_format", [input_name])}
	if _slot_matches_input(view, input_name):
		var available: int = view.quantity() - _selected_remove_count(selected_ops, slot_index)
		if available > 0:
			var inst: Dictionary = slot.duplicate(true)
			inst["quantity"] = 1
			return {
				"ok": true,
				"instance": inst,
				"op": {"type": "remove", "slot_index": slot_index, "item_id": view.id()},
			}
	var container: ContainerAspect = view.as_container()
	if container != null and not container.is_empty() and _content_matches_input(container.content_id(), input_name):
		var available_liquid: int = int(floor(container.amount())) - _selected_pour_count(selected_ops, slot_index)
		if available_liquid > 0:
			return {
				"ok": true,
				"instance": poured_content_instance(slot, container.content_id()),
				"op": {"type": "pour", "slot_index": slot_index, "content_id": container.content_id()},
			}
	return {"ok": false, "message": _fmt("error.workstation.input_changed_format", [input_name])}


func _consume_inventory_inputs(consumed_input_indices: Array, input_ops: Array) -> Dictionary:
	for idx_v in consumed_input_indices:
		var idx: int = int(idx_v)
		if idx < 0 or idx >= input_ops.size():
			return {"ok": false, "message": _fmt("error.workstation.consume_index_oob_format", [idx])}
		var op: Dictionary = input_ops[idx]
		var applied: Dictionary = _apply_inventory_input_op(op)
		if not bool(applied.get("ok", false)):
			return applied
	return {"ok": true}


func _apply_inventory_input_op(op: Dictionary) -> Dictionary:
	var slot_index: int = int(op.get("slot_index", -1))
	if slot_index < 0 or slot_index >= character.inventory.size():
		return {"ok": false, "message": _fmt("error.workstation.backpack_slot_missing_format", [slot_index])}
	var op_type: String = str(op.get("type", ""))
	if op_type == "remove":
		var expected: String = str(op.get("item_id", ""))
		var slot: Dictionary = character.inventory[slot_index]
		if str(slot.get("item_id", "")) != expected or int(slot.get("quantity", 0)) <= 0:
			return {"ok": false, "message": _fmt("error.workstation.input_changed_format", [expected])}
		if character.inventory_ops().remove_item(slot_index, 1) <= 0:
			return {"ok": false, "message": _fmt("error.workstation.consume_failed_format", [expected])}
		return {"ok": true}
	if op_type == "pour":
		var content_id: String = str(op.get("content_id", ""))
		var bucket: Dictionary = character.inventory[slot_index]
		var container: ContainerAspect = InventorySlotData.of(bucket).as_container()
		if container == null or container.content_id() != content_id or container.amount() < 1.0:
			return {"ok": false, "message": _fmt("error.workstation.container_content_changed_format", [content_id])}
		var fields := container.with_consumed(1.0)
		bucket["container_amount"] = fields["container_amount"]
		bucket["container_content"] = fields["container_content"]
		character.inventory[slot_index] = bucket
		character.inventory = character.inventory
		character.inventory_ops().persist_slot(slot_index)
		return {"ok": true}
	return {"ok": false, "message": _fmt("error.workstation.unknown_consume_type_format", [op_type])}


func _slot_matches_input(view: InventorySlotData, input_name: String) -> bool:
	var wanted: String = _normalize_input(input_name)
	var aliases: PackedStringArray = PackedStringArray([
		view.id(),
		view.display_name(),
		view.shape_type(),
		view.body_material_id(),
	])
	var tmpl: Item = view.template()
	if tmpl != null:
		aliases.append(tmpl.id)
		aliases.append(tmpl.display_name)
		aliases.append(tmpl.kind)
	for alias in aliases:
		if not alias.is_empty() and _normalize_input(alias) == wanted:
			return true
	return false


func _content_matches_input(content_id: String, input_name: String) -> bool:
	var wanted: String = _normalize_input(input_name)
	if _normalize_input(content_id) == wanted:
		return true
	var mat: Substance = Materials.by_id(content_id)
	return mat != null and _normalize_input(mat.display_name) == wanted


func _input_names_by_indices(input_names: Variant, indices: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(input_names) != TYPE_PACKED_STRING_ARRAY and typeof(input_names) != TYPE_ARRAY:
		return out
	if typeof(indices) != TYPE_ARRAY:
		return out
	var names: Array = []
	for name_v in input_names:
		names.append(str(name_v))
	for idx_v in indices:
		var idx := int(idx_v)
		if idx >= 0 and idx < names.size():
			out.append(str(names[idx]))
	return out


func _selected_remove_count(ops: Array, slot_index: int) -> int:
	var count: int = 0
	for op_v in ops:
		var op: Dictionary = op_v
		if str(op.get("type", "")) == "remove" and int(op.get("slot_index", -1)) == slot_index:
			count += 1
	return count


func _selected_pour_count(ops: Array, slot_index: int) -> int:
	var count: int = 0
	for op_v in ops:
		var op: Dictionary = op_v
		if str(op.get("type", "")) == "pour" and int(op.get("slot_index", -1)) == slot_index:
			count += 1
	return count


func _normalize_input(value: String) -> String:
	var out: String = value.strip_edges().to_lower().replace("：", ":").replace("（", "(").replace("）", ")")
	var quantity_index: int = out.rfind(" x")
	if quantity_index > 0:
		out = out.substr(0, quantity_index).strip_edges()
	if out.contains(":"):
		out = out.substr(out.find(":") + 1).strip_edges()
	var paren_index: int = out.find("(")
	if paren_index > 0:
		out = out.substr(0, paren_index).strip_edges()
	return out




# 遍历 input_ops，对每个 type=remove 且模板有 max_durability 的 slot 扣 1 点耐久。
# 同 slot_index 只算一次，避免重复输入造成两次磨损。
# 返回报废工具的 display_name 列表（让 caller 拼提示）。
func _wear_tool_inputs(input_ops: Array) -> Array[String]:
	var broken: Array[String] = []
	var seen_slots := {}
	for op_v in input_ops:
		var op: Dictionary = op_v
		if str(op.get("type", "")) != "remove":
			continue
		var slot_idx: int = int(op.get("slot_index", -1))
		if slot_idx < 0 or seen_slots.has(slot_idx):
			continue
		seen_slots[slot_idx] = true
		var slot: Dictionary = character.inventory_ops().get_slot(slot_idx)
		if int(slot.get("quantity", 0)) <= 0:
			continue
		var tmpl: Item = Items.by_id(String(slot.get("item_id", "")))
		if tmpl == null:
			continue
		if int(tmpl.properties.get("max_durability", 0)) <= 0:
			continue
		var res: Dictionary = character.inventory_ops().decrement_tool_durability(slot_idx, 1)
		if bool(res.get("broke", false)):
			broken.append(tmpl.display_name)
	return broken


func _send_world_event(summary: Dictionary) -> void:
	var backend: Node = character.get_node_or_null("/root/BackendRuntimeClient")
	if backend == null or not backend.has_method("send_world_event"):
		return
	var character_id: String = str(character.backend_character_id())
	# 工作台是公共行为：附近 10m 内的人都能看到你在操作（避免矿工偷偷
	# 把矿石装兜里）。voice_affected 给的是听得到你说话的那批，离得近就该看得到。
	var witnesses: Array[String] = character.perception().voice_affected_character_ids("far")
	# Wire contract: see UseWorkstationEventData in
	# backend/src/godot-link/world-events.ts. Backend renderer
	# (event-descriptions/workstation.ts) composes the human description
	# from outcome / outputs / failModeName — Godot ships pure structure.
	var data: Dictionary = {
		"actorId": character_id,
		"affectedCharacterIds": witnesses,
		"workstationId": str(summary.get("workstation_id", "")),
		"verb": str(summary.get("verb", "")),
		"outcome": str(summary.get("outcome", "")),
	}
	if summary.has("outputs"):
		data["outputs"] = summary.get("outputs", [])
	if summary.has("leftover_outputs"):
		data["leftoverOutputs"] = summary.get("leftover_outputs", [])
	if summary.has("fail_mode_name"):
		data["failModeName"] = str(summary.get("fail_mode_name", ""))
	# Proficiency 字段两档（见 _commit_active surface 策略）：
	#   1. skillId / before / difficulty：任何带 skill 的反应都发，给失败因果用（所有 viewer 可见）
	#   2. after / delta：仅 |delta|≥0.5 发，给"长进/退步" suffix 用（只对 actor 自己渲染）
	if summary.has("proficiency_skill_id"):
		data["proficiencySkillId"] = str(summary.get("proficiency_skill_id", ""))
		data["proficiencyBefore"] = float(summary.get("proficiency_before", 0.0))
	if summary.has("difficulty"):
		data["difficulty"] = float(summary.get("difficulty", 0.0))
	if summary.has("proficiency_delta") and absf(float(summary.get("proficiency_delta", 0.0))) >= 0.5:
		data["proficiencyAfter"] = float(summary.get("proficiency_after", 0.0))
		data["proficiencyDelta"] = float(summary.get("proficiency_delta", 0.0))
	# event 名按 (workstation, verb) 查 craft 表（mine / cook / smelt / ...）；
	# 未配置时回退到工作台 id 当事件类型 + push_warning，让漏配立刻被看见。详见 Crafts.for_workstation_verb。
	var event_name: String = _craft_event_name(
		String(summary.get("workstation_id", "")),
		String(summary.get("verb", "")),
	)
	backend.call("send_world_event", event_name, data)


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


static func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
