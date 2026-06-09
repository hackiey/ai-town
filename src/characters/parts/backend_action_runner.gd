class_name BackendActionRunner
extends RefCounted

# Backend agent action_request 派发与生命周期收口。纯 coordinator —— 只管：
# 1) 路由 action_request 到对应 handler / Character service
# 2) 维护"当前是否在跑 action"状态（_action_id / _active / _completion）
# 3) snapshot/diff + log + 完成事件
#
# 真正干活的：
# - Trade / Sleep / UseItem 子系统住 Character 上（character.trade_runner() / sleep_controller()
#   / use_item_controller()），可被 lua / 跨角色调用，不依赖 runner。
# - inventory / shelf / container / ledger / social / farming handler 是无状态静态函数，
#   签名统一 (character, action_request[, completion]) → Dictionary。
#
# Pending 协议：
# - handler 返回 {pending: true} → runner 设 _active = true，等子系统通过 completion(ok, err, result)
#   回调到 finish 解锁。
# - handler 返回 {ok, result} → runner 立即调 finish。
# - handler 返回 {ok: false, message} → runner finish(false, message, {})。
#
# 子类差异通过 character 的虚 hook 表达：
#   - `_begin_action_walk(action_id)`：NPC 切 `_state="walking" + anim`；Player 切 `_has_target=true + anim="walking"`。
#   - `_cancel_action_walk()`：各自重置 walk state + 切 idle 动画。
#   - `_on_backend_action_finished(ok, error, result)`：Player override 加 owner 通知；NPC 默认 noop。
#
# NPC 的 plan_farm_work 跑农事队列那一支不进 dispatch：NPC 在 `start_backend_action`
# 薄壳里前置识别，调 `start_external(action_id, completion)` 把 runner 状态置上，再自己
# enqueue 农事；queue drain 时 `_on_farm_queue_completed` 反过来调 `finish(...)`。
#
# 工作台 craft actions —— production skill craft 全部路由到同一个
# character.workstation_actions().start_from_action()。target shape 由 backend WorkstationActionTarget 统一填好。

var character: Character

var _action_id: String = ""
var _active: bool = false
var _completion: Callable = Callable()
var _pre_action_snapshot: Dictionary = {}
var _action_name: String = ""
var _action_target: Variant = {}
# fast tool（say_to / respond）派发期间置真：它们与 body 动作并发，不该让自己发出的事件
# 蹭到 body 动作的 _action_id。详见 current_emit_action_id() + send_world_event 盖戳。
var _in_fast_tool: bool = false


func _init(owner: Character) -> void:
	character = owner


func is_active() -> bool:
	return _active


func current_action_id() -> String:
	return _action_id


# send_world_event 盖 actionId 用：fast tool 派发期间返回 ""（其事件不归属当前 body 动作），
# 否则返回当前 body/instant 动作 id。
func current_emit_action_id() -> String:
	return "" if _in_fast_tool else _action_id


# 主入口。preempt 已有 action_request → 派发动作。
func start(action_request: Dictionary, completion: Callable) -> void:
	var action := str(action_request.get("action", ""))
	# say_to 是瞬时 fast tool：不占身体、不打断当前 body action。直接独立 dispatch，
	# 不动 runner state（_action_id / _completion / _active）。
	if action == "say_to":
		_in_fast_tool = true
		var speech_action_id := str(action_request.get("id", ""))
		var speech_target: Variant = action_request.get("target", {})
		_log_npc_action(speech_action_id, action, speech_target, "start")
		var speech := SocialHandlers.run_say_to(character, action_request)
		var speech_result: Dictionary = {}
		var result_v: Variant = speech.get("result", {})
		if typeof(result_v) == TYPE_DICTIONARY:
			speech_result = result_v as Dictionary
		var speech_ok := bool(speech.get("ok", false))
		var speech_error := str(speech.get("error", ""))
		_log_npc_action(speech_action_id, action, speech_target, "completed" if speech_ok else "failed", speech_result, speech_error)
		if not speech_ok:
			_emit_action_failed_event(speech_action_id, action, speech_target, speech_error)
		_in_fast_tool = false
		completion.call(speech_ok, speech_error, speech_result)
		return
	if _active and action == "respond":
		# respond 不打断其他身体动作（走路 / 农事 / 工作台 / 睡觉）：DB 标 status
		# + 撮合 + 库存转移都是即时操作，跑完直接返回，runner 的 _active/_action_id 不变，
		# 主线 action 继续。买家阻塞的 offer 由 trade_runner.resolve_pending 单独 finish。
		# _in_fast_tool 守卫：撮合发出的 give 事件不该蹭到正在进行的 body 动作 _action_id。
		_in_fast_tool = true
		var resp_action_id := str(action_request.get("id", ""))
		var resp_target: Variant = action_request.get("target", {})
		_log_npc_action(resp_action_id, action, resp_target, "start")
		var resp := character.trade_runner().run_respond(action_request)
		var resp_ok := bool(resp.get("ok", false))
		var resp_error := "" if resp_ok else str(resp.get("message", ""))
		var resp_result: Dictionary = {}
		var resp_result_v: Variant = resp.get("result", {})
		if typeof(resp_result_v) == TYPE_DICTIONARY:
			resp_result = resp_result_v as Dictionary
		_log_npc_action(resp_action_id, action, resp_target, "completed" if resp_ok else "failed", resp_result, resp_error)
		if not resp_ok:
			_emit_action_failed_event(resp_action_id, action, resp_target, resp_error)
		_in_fast_tool = false
		completion.call(resp_ok, resp_error, resp_result)
		return
	_preempt_if_active()
	_pre_action_snapshot = ActionChangeTracker.capture(character)
	_action_name = action
	_action_target = action_request.get("target", {})
	_action_id = str(action_request.get("id", ""))
	_completion = completion
	_log_npc_action(_action_id, _action_name, _action_target, "start")
	# 工作台 craft actions 全部走同一 dispatcher。
	if Crafts.is_action(action):
		_active = true
		var ws_err := character.workstation_actions().start_from_action(action_request)
		if not ws_err.is_empty():
			finish(false, ws_err, {})
		return
	match action:
		"move_to_location":
			var err := _start_move_to_location(action_request)
			if not err.is_empty():
				finish(false, err, {})
		"sleep":
			# completion = self.finish 让 sleep_controller 在自然到点 / 外部刺激唤醒时收尾。
			var sleep_err := character.sleep_controller().start(action_request, finish)
			if sleep_err.is_empty():
				_active = true
			else:
				finish(false, sleep_err, {})
		_:
			if _is_farming_action(action):
				_complete_farming_action(action_request)
			elif _is_instant_action(action):
				_complete_instant_action(action_request)
			else:
				finish(false, "unsupported action: %s" % action, {})


# NPC plan_farm_work 用：runner 的状态置上但派发交给 caller（caller 自己 enqueue 农事）。
# completion 触发由 _on_farm_queue_completed → finish(...) 走。
func start_external(action_id: String, completion: Callable, action_name: String = "", action_target: Variant = {}) -> void:
	_preempt_if_active()
	_pre_action_snapshot = ActionChangeTracker.capture(character)
	_action_name = action_name
	_action_target = action_target
	_action_id = action_id
	_active = true
	_completion = completion
	_log_npc_action(_action_id, _action_name, _action_target, "start")


# 第三方（trade 撮合、未来其他系统）想让本 runner 中止走路用。和 cancel() 不同：
# cancel() 是 backend RPC 路径，BackendRuntimeClient 紧跟着自己 ack 给 backend，所以
# runner 内部丢 _completion；这里没人帮 ack，必须走 finish() 把 _completion fire 掉，
# 否则 backend 的 waitForTerminal 永远卡住。
# 只处理 move_to_location；其他 action 一律不动（农事/工作台/睡觉等让本人 LLM 自决）。
func interrupt_walk(reason: String) -> bool:
	if not _active or _action_name != "move_to_location":
		return false
	character._cancel_action_walk()
	# 第三方打断走路不是本人可反应的失败（对方发起的交互会另发 direct_speech 事件）→ 不发 action_failed。
	finish(false, reason, {}, false)
	return true


# Cancel 入口：校验 id → 委托子系统 cancel → 兜底走 walk cancel → 清状态。
# 返回 "" = 成功；非空 = error。NPC plan_farm_work 在外层（NPC.cancel_backend_action）单独处理。
# Cancel 不 fire _completion —— BackendRuntimeClient 自己 ack。
func cancel(action_id: String, reason: String = "interrupted") -> String:
	if not _active:
		return ""
	if not action_id.is_empty() and _action_id != action_id:
		return "active action_request mismatch: %s" % _action_id
	var cancelled_action_id := _action_id
	var cancelled_action_name := _action_name
	var cancelled_action_target: Variant = _action_target
	if character.workstation_actions().is_active():
		var workstation_summary := character.workstation_actions().cancel(reason)
		if bool(workstation_summary.get("actionCompleted", false)):
			finish(true, "", workstation_summary)
			return ""
		_clear_lifecycle()
		_log_npc_action(cancelled_action_id, cancelled_action_name, cancelled_action_target, "cancelled", {}, reason)
		return ""
	if character.sleep_controller().is_active():
		character.sleep_controller().cancel(reason)
	elif character.use_item_controller().is_pending():
		character.use_item_controller().cancel()
	elif character.water_draw_actions().is_active():
		character.water_draw_actions().cancel(reason)
	elif character.trade_runner().has_pending():
		character.trade_runner().cancel_pending(reason)
	else:
		character._cancel_action_walk()
	_clear_lifecycle()
	_log_npc_action(cancelled_action_id, cancelled_action_name, cancelled_action_target, "cancelled", {}, reason)
	character.perception().send_manifest()
	return ""


# 主 finish。子类的额外副作用通过 character._on_backend_action_finished hook 触发。
# emit_failed=false：抑制 action_failed 自感知事件（用于第三方打断走路这类"非本人可反应失败"的噪声）。
func finish(ok: bool, error: String = "", result: Dictionary = {}, emit_failed: bool = true) -> void:
	var finished_action_id := _action_id
	var finished_action := _action_name
	var finished_target: Variant = _action_target
	_active = false
	_action_id = ""
	_action_name = ""
	_action_target = {}
	var final_result := _with_action_changes(result)
	_pre_action_snapshot = {}
	_log_npc_action(finished_action_id, finished_action, finished_target, "completed" if ok else "failed", final_result, error)
	_emit_public_finish_event(finished_action_id, finished_action, finished_target, ok, error, final_result)
	# 失败 → 发一条 actor-only action_failed 事件进历史（按视角渲染："（未成）你尝试…：原因"）。
	# 即时反馈本就由 tool 同步返回值给 agent，这条只供后续 turn 的历史时间线。
	if not ok and emit_failed and not finished_action_id.is_empty() and not _action_self_reports_failure(finished_action):
		_emit_action_failed_event(finished_action_id, finished_action, finished_target, error)
	character.perception().send_manifest()
	character._on_backend_action_finished(ok, error, final_result)
	if _completion.is_valid():
		var completion := _completion
		_completion = Callable()
		completion.call(ok, error, final_result)


func _with_action_changes(result: Dictionary) -> Dictionary:
	var changes := ActionChangeTracker.build(_pre_action_snapshot, ActionChangeTracker.capture(character))
	if changes.is_empty():
		return result
	var out := result.duplicate(true)
	out["character_changes"] = changes
	return out


func _log_npc_action(action_id: String, action: String, target: Variant, status: String, result: Dictionary = {}, error: String = "") -> void:
	if character == null or not character.is_in_group("npcs"):
		return
	var character_id := character.backend_character_id()
	if character_id.is_empty():
		return
	var line := "[NPC_ACTION] npc=%s action=%s status=%s" % [character_id, action, status]
	if not action_id.is_empty():
		line += " action_id=%s" % action_id
	var target_text := _log_value(target)
	if not target_text.is_empty():
		line += " target=%s" % target_text
	if not error.is_empty():
		line += " error=%s" % _log_value(error)
	var result_text := _log_value(result)
	if status != "start" and not result_text.is_empty():
		line += " result=%s" % result_text
	print(line)


func _log_value(value: Variant) -> String:
	if value == null:
		return ""
	if typeof(value) == TYPE_DICTIONARY and (value as Dictionary).is_empty():
		return ""
	if typeof(value) == TYPE_ARRAY and (value as Array).is_empty():
		return ""
	var text := str(value).replace("\n", "\\n")
	if text.length() > 300:
		text = text.substr(0, 297) + "..."
	return text


func _clear_lifecycle() -> void:
	_active = false
	_action_id = ""
	_action_name = ""
	_action_target = {}
	_completion = Callable()


# ─── 内部派发 ─────────────────────────────────────────

func _preempt_if_active() -> void:
	if not _active:
		return
	if character.workstation_actions().is_active():
		var workstation_summary := character.workstation_actions().cancel("preempted by new action_request")
		if bool(workstation_summary.get("actionCompleted", false)):
			finish(true, "", workstation_summary)
			return
	# Sleep cancel 不 fire completion（preempt 路径要走下面 finish）；use_item / trade 同理。
	if character.sleep_controller().is_active():
		character.sleep_controller().preempt()
	if character.use_item_controller().is_pending():
		character.use_item_controller().preempt()
	if character.water_draw_actions().is_active():
		character.water_draw_actions().preempt()
	if character.trade_runner().has_pending():
		character.trade_runner().preempt()
	# 被本人下达的新 action_request 抢占，不是可反应失败 → 不发 action_failed。
	finish(false, "preempted by new action_request", {}, false)


func _start_move_to_location(action_request: Dictionary) -> String:
	var resolved := character.walk().resolve_move_to_location_request(action_request)
	if not bool(resolved.get("ok", false)):
		return str(resolved.get("error", "move_to_location failed"))
	var action_id := str(resolved.get("action_id", ""))
	if bool(resolved.get("done", false)):
		finish(true, "", {})
		return ""
	# 卖家真正起步去别处：所有指向自己的 pending offer（议价）一律 cancel，让买家
	# tool 解锁返回 response="cancelled"，避免对方走远后买家永久阻塞。
	character.trade_runner().cancel_incoming_offers_as_seller("seller_left")
	if resolved.has("position"):
		return _start_walk(
			action_id,
			resolved.get("position", character.global_position),
			float(resolved.get("arrival_distance", character.walk().default_arrival_distance()))
		)
	return character.walk().start_walk_to_region_common(
		str(resolved.get("region_id", "")),
		action_id,
		Callable(self, "_start_walk")
	)


func _start_walk(action_id: String, raw_target: Vector3, final_arrival_distance: float = 0.0) -> String:
	var err := character.walk().plan_to_world_position(raw_target, final_arrival_distance)
	if not err.is_empty():
		return err
	_action_id = action_id
	_active = true
	character._begin_action_walk(action_id)
	return ""


# ─── 行动分类 ────────────────────────────────────────

func _is_instant_action(action: String) -> bool:
	return action in [
		"say_to",
		"use_item",
		"pick_up_item",
		"drop_item",
		"offer",
		"respond",
		"create_item",
		"put_take_container",
		"view_container",
		"brew",
		"write",
		"read",
	]


func _is_farming_action(action: String) -> bool:
	return action in [
		"plant_seed",
		"water_crop",
		"harvest_crop",
		"remove_pest",
	]


# ─── farming（瞬时）────────────────────────────────────
# FarmingHandlers.resolve 返回 {ok, message?, event?: {type, data}}。dispatcher 负责
# emit event + finish。

func _complete_farming_action(action_request: Dictionary) -> void:
	var farm_result := FarmingHandlers.resolve(character, action_request)
	if not bool(farm_result.get("ok", false)):
		finish(false, str(farm_result.get("message", "farming failed")), {})
		return
	var event_v: Variant = farm_result.get("event", {})
	if typeof(event_v) == TYPE_DICTIONARY:
		var ev: Dictionary = event_v
		character.emit_world_event(str(ev.get("type", "")), ev.get("data", {}))
	finish(true, "", {})


# ─── instant ────────────────────────────────────────
# handler 协议：返回 {ok, pending?, result?, message?}。pending=true 时 runner 设 _active
# 等子系统通过 completion 回调；否则立即 finish。

func _complete_instant_action(action_request: Dictionary) -> void:
	var action := str(action_request.get("action", ""))
	# say_to 已在 start() 顶部独立分支处理，瞬时完成，不会走到这里。
	var structured: Dictionary = {}
	match action:
		"use_item":
			structured = InventoryHandlers.run_use_item(character, action_request, finish)
		"offer":
			structured = character.trade_runner().run_offer(action_request, finish)
		"respond":
			structured = character.trade_runner().run_respond(action_request)
		"put_take_container":
			structured = ContainerHandlers.run_put_take(character, action_request, finish)
		"view_container":
			structured = ContainerHandlers.run_view_container(character, action_request)
		"brew":
			structured = BrewHandlers.run_brew(character, action_request)
		"write":
			structured = LedgerHandlers.run_write(character, action_request)
		"read":
			structured = LedgerHandlers.run_read(character, action_request)
		"drop_item":
			structured = InventoryHandlers.run_drop_item(character, action_request)
		"pick_up_item":
			structured = InventoryHandlers.run_pick_up_item(character, action_request)
		_:
			# 历史路径：未识别 instant action，发个通用 world_event 然后 finish。
			# 当前列表已穷举所有 _is_instant_action，正常不该走到这里。
			var target: Variant = action_request.get("target", {})
			var target_dict: Dictionary = target as Dictionary if typeof(target) == TYPE_DICTIONARY else {}
			character.emit_world_event(action, {
				"actorId": character.backend_character_id(),
				"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
				"target": target_dict,
			})
			finish(true, "", {})
			return
	if not bool(structured.get("ok", false)):
		finish(false, str(structured.get("message", "%s failed" % action)), {})
		return
	if bool(structured.get("pending", false)):
		_active = true
		return
	var result_v: Variant = structured.get("result", {})
	var result: Dictionary = result_v as Dictionary if typeof(result_v) == TYPE_DICTIONARY else {}
	finish(true, "", result)


func _emit_public_finish_event(action_id: String, action: String, target: Variant, ok: bool, error: String, result: Dictionary) -> void:
	if not ok:
		return
	if action != "move_to_location" and action != "plan_farm_work":
		return
	var actor_id := character.backend_character_id()
	var target_dict: Dictionary = target as Dictionary if typeof(target) == TYPE_DICTIONARY else {}
	# Wire contract: move/plan_farm prose is composed by backend renderers
	# (event-descriptions/move.ts, farm.ts) from target + result. No baked text.
	# actionId 显式带上：此处在 finish() 内、_action_id 已清空，send_world_event 的隐式盖戳读不到，
	# 必须用 finish 捕获的 finished_action_id 显式塞进 data。
	var data := {
		"actorId": actor_id,
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"target": target_dict,
		"result": result,
	}
	if not action_id.is_empty():
		data["actionId"] = action_id
	if not error.is_empty():
		data["error"] = error
	character.emit_world_event(action, data)


# 这些动作失败时自己已经发了能体现失败的事件，不该再补 action_failed（否则重复）：
# - craft（工作台）：失败发 outcome=failure 事件（含难度/熟练度）。
# - sleep：被外部刺激唤醒走 finish(false)，但 woke_up 事件已表达"睡眠中断"。
# - view/read/write/pick_up：handler 自己发成功/失败可感知事件（viewer-specific 渲染）。
# 代价：这几类的"启动即失败"（没产生自有事件那种）也不会进历史，但 tool 同步返回值已即时告知。
func _action_self_reports_failure(action: String) -> bool:
	return Crafts.is_action(action) or action == "sleep" or action in ["view_container", "read", "write", "pick_up_item"]


# 失败动作 → actor-only 的 action_failed 自感知事件。data.actionId 与 action_log.actionId 一致，
# renderer 据此精确 join；say_to 额外带 spokenText（想说但没传到的话）。
func _emit_action_failed_event(action_id: String, action: String, target: Variant, error: String) -> void:
	if character == null:
		return
	var actor_id := character.backend_character_id()
	if actor_id.is_empty():
		return
	var target_dict: Dictionary = target as Dictionary if typeof(target) == TYPE_DICTIONARY else {}
	var data := {
		"actorId": actor_id,
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"actionId": action_id,
		"action": action,
		"target": target_dict,
		"error": error,
	}
	if action == "say_to":
		data["spokenText"] = str(target_dict.get("text", ""))
	character.emit_world_event("action_failed", data)
