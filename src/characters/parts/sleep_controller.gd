class_name SleepController
extends RefCounted

# sleep 子系统：deadline + tick 驱动的 timer。Character 级 service，不持有 BackendActionRunner ref。
#
# 协议：
# - start() 传一个 completion: Callable —— 自然到点 _commit / 外部刺激 wake / 显式 cancel
#   都通过它 fire 回 dispatcher（runner.finish 或 silent cleanup）。
# - tick() 由 character._tick_backend_action 每帧调；推 rest 恢复 + 到点 _commit。
# - cancel/preempt/wake_from_stimulus 都跑 sleep.lua on_commit 发 woke_up event 后清状态。
#   后两者 fire completion，cancel 不 fire（caller 走 runner.cancel 自己处理 lifecycle）。
#
# 当前 MVP：进入 sleep 后只能 ① 自然睡满 ② 被新 action preempt ③ 显式 cancel ④ 外部刺激唤醒。

var _character: Character
var _active: Dictionary = {}


func _init(owner: Character) -> void:
	_character = owner


func is_active() -> bool:
	return not _active.is_empty()


# 由 runner.start sleep 分支调。返回 "" 或错误字符串。
# completion 仅在自然 _commit / wake_from_stimulus 时 fire；显式 cancel 不 fire。
func start(action_request: Dictionary, completion: Callable) -> String:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return "sleep target must be object"
	var t: Dictionary = target as Dictionary
	var minutes: int = int(t.get("durationGameMinutes", 0))
	var action_id: String = str(action_request.get("id", ""))
	var actor_id: String = _character.backend_character_id()
	var deadline: float = GameClock.game_seconds + float(minutes) * 60.0
	var hours: int = ceili(float(minutes) / 60.0)
	if hours < 1:
		hours = 1
	var expires_total_hours: int = GameClock.total_game_hours() + hours

	# Lua 决定能不能 sleep + 加 condition + 发 went_to_sleep event
	var result := MechanicVerb.resolve("sleep", {
		"actor": _character,
		"actor_id": actor_id,
		"action_id": action_id,
		"duration_minutes": minutes,
		"expires_total_hours": expires_total_hours,
	})
	if not bool(result.get("ok", false)):
		return str(result.get("message", "sleep rejected"))

	_active = {
		"action_id": action_id,
		"duration_game_minutes": minutes,
		"started_game_seconds": GameClock.game_seconds,
		"last_rest_game_seconds": GameClock.game_seconds,
		"rest_recovery_carry": 0.0,
		"deadline_game_seconds": deadline,
		"actor_id": actor_id,
		"completion": completion,
	}
	_character.perception().send_manifest()
	return ""


func tick(_delta: float) -> void:
	if _active.is_empty():
		return
	_tick_rest()
	var deadline: float = float(_active.get("deadline_game_seconds", 0.0))
	if GameClock.game_seconds >= deadline:
		_commit()


# cancel：runner.cancel/preempt 调用。发 woke_up event + 清状态，不 fire completion。
func cancel(reason: String) -> void:
	if _active.is_empty():
		return
	_emit_woke_up(_active, reason)
	_active = {}


func preempt() -> void:
	cancel("preempted by new action_request")


# 外部刺激（loud speech 等）唤醒 sleep action。fire completion with (false, reason, {}) 让
# dispatcher 把当前 action 当 cancelled 收尾。返回 true 表示走的是 action 路径（character
# 拿到 false 后自己走 condition-only 路径）。
func wake_from_stimulus(reason: String) -> bool:
	if _active.is_empty():
		return false
	var completion: Callable = _active.get("completion", Callable())
	_emit_woke_up(_active, reason)
	_active = {}
	if completion.is_valid():
		completion.call(false, reason, {})
	return true


func _commit() -> void:
	if _active.is_empty():
		return
	_tick_rest()
	var active: Dictionary = _active.duplicate(true)
	_active = {}
	var minutes: int = _elapsed_minutes(active)
	var actor_id: String = str(active.get("actor_id", _character.backend_character_id()))
	# Lua 移除 condition + 发 woke_up event
	MechanicVerb.resolve("sleep", {
		"actor": _character,
		"actor_id": actor_id,
		"duration_minutes": minutes,
		"reason": "natural",
	}, "on_commit")
	var completion: Callable = active.get("completion", Callable())
	if completion.is_valid():
		completion.call(true, "", {"durationGameMinutes": minutes, "wakeReason": "natural"})


func _emit_woke_up(active: Dictionary, reason: String) -> void:
	_tick_rest()
	var minutes: int = _elapsed_minutes(active)
	var actor_id: String = str(active.get("actor_id", _character.backend_character_id()))
	MechanicVerb.resolve("sleep", {
		"actor": _character,
		"actor_id": actor_id,
		"duration_minutes": minutes,
		"reason": reason,
	}, "on_commit")


func _tick_rest() -> void:
	if _active.is_empty():
		return
	var deadline: float = float(_active.get("deadline_game_seconds", GameClock.game_seconds))
	var until: float = minf(GameClock.game_seconds, deadline)
	var last: float = float(_active.get("last_rest_game_seconds", until))
	if until <= last:
		return
	var recovered: float = float(_active.get("rest_recovery_carry", 0.0)) \
		+ (until - last) * rest_recovery_per_game_second()
	var points := int(floor(recovered))
	if points > 0:
		recover_rest_points(points)
		recovered -= float(points)
		if _character.rest >= _character.max_rest:
			recovered = 0.0
	_active["rest_recovery_carry"] = recovered
	_active["last_rest_game_seconds"] = until


func _elapsed_minutes(active: Dictionary) -> int:
	var started: float = float(active.get("started_game_seconds", GameClock.game_seconds))
	var deadline: float = float(active.get("deadline_game_seconds", GameClock.game_seconds))
	var ended: float = minf(GameClock.game_seconds, deadline)
	var elapsed_seconds: float = maxf(0.0, ended - started)
	if elapsed_seconds <= 0.0:
		return 0
	return maxi(1, int(ceil(elapsed_seconds / GameClock.SECONDS_PER_GAME_MINUTE)))


# ─── sleep condition state（与 sleep action 解耦的常驻字段操作）─────────
# active_conditions 数组仍住 Character（多 condition 共用），但 sleeping 这条 type 的
# 增删 / 查询 / rest 恢复速率全归本 controller 管。boot 时直接放 sleeping condition、
# 不走 action 路径的早期 NPC 用 add_sleeping_condition 直调。

func rest_recovery_per_game_second() -> float:
	var needed_seconds := maxf(_character.sleep_needed_hours, 0.1) * GameClock.SECONDS_PER_GAME_HOUR
	return _character.max_rest / needed_seconds


func recover_rest_points(points: int) -> int:
	if points <= 0:
		return 0
	var before := _character.rest
	_character.rest = clampf(roundf(_character.rest) + float(points), 0.0, _character.max_rest)
	return int(_character.rest - before)


func add_sleeping_condition(duration_game_minutes: int, source_id: String) -> void:
	_character.remove_condition_type("sleeping")
	var hours: int = ceili(float(duration_game_minutes) / 60.0)
	if hours < 1:
		hours = 1
	_character.active_conditions.append({
		"type": "sleeping",
		"started_at": Time.get_ticks_msec() / 1000.0,
		"expires_total_hours": GameClock.total_game_hours() + hours,
		"source_id": source_id,
	})
	_character.head_status().sync_to_clients()
	_character.state_io().persist()


func remove_sleeping_condition() -> void:
	if not is_sleeping():
		return
	_character.remove_condition_type("sleeping")
	_character.head_status().sync_to_clients()
	_character.state_io().persist()


func is_sleeping() -> bool:
	return _character.has_condition("sleeping")


# 外部刺激（loud speech 等）唤醒。Server-only。两种睡眠来源统一退出路径：
# - sleep action 起的睡 → wake_from_stimulus 走 sleep.lua on_commit 标准退出 + fire completion
# - boot/condition-only 睡（没 action 在跑，只是 sleeping condition）→ 直接 remove + 手动发 woke_up event
# 没在睡 / 不在 runtime → no-op。
func wake_from_external_stimulus(reason: String) -> void:
	if not RunMode.is_runtime():
		return
	if not is_sleeping():
		return
	if wake_from_stimulus(reason):
		# sleep 是 action 路径：completion 已 fire（runner.finish 收尾），这里啥都不用做。
		return
	# condition-only 路径
	remove_sleeping_condition()
	_character.emit_world_event("woke_up", {
		"actorId": _character.backend_character_id(),
		"affectedCharacterIds": [_character.backend_character_id()],
		"durationGameMinutes": 0,
		"reason": reason,
	})
	_character.perception().send_manifest()
