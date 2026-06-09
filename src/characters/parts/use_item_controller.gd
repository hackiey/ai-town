class_name UseItemController
extends RefCounted

# use_item 的 deferred 计时器子系统。Character 级 service —— 由 character.use_item_controller()
# 懒加载暴露，不持有 BackendActionRunner 反向引用。
#
# 协议：
# - start() 调用方给一个 completion: Callable —— 触发 _commit 时调 completion.call(ok, error, result)。
#   sync 路径（duration<=0）不存 completion，直接返回结果。
# - is_pending() 让外部（character.tick / dispatcher）知道是不是在 pending。
# - cancel / preempt 清状态 + 撤 label，不调 completion（caller 自己处理 lifecycle 取消）。
# - tick() 由 character._tick_backend_action 每帧调一次。

var _character: Character
var _active: Dictionary = {}


func _init(owner: Character) -> void:
	_character = owner


func is_pending() -> bool:
	return not _active.is_empty()


# 由 InventoryHandlers.run_use_item 调。决定 instant 还是 deferred；
# 返回 {ok, pending?, result?, message?} —— dispatcher 兼容格式。
# completion 仅 deferred 路径用：deadline 到时 _commit 通过它 fire 回 runner.finish。
func start(action_request: Dictionary, slot_index: int, food_only: bool, completion: Callable) -> Dictionary:
	var slot := _character.inventory_ops().get_slot(slot_index)
	var view := InventorySlotData.of(slot)
	var use := ItemUse.resolve(view, food_only)
	if not bool(use.get("ok", false)):
		return {"ok": false, "message": str(use.get("message", "use_item failed"))}
	var duration := float(use.get("duration_seconds", 0.0))
	if duration <= 0.0:
		return _use_slot(slot_index, food_only, view.id())
	_active = {
		"slot_index": slot_index,
		"item_id": view.id(),
		"food_only": food_only,
		"duration": duration,
		"started_at_game_seconds": GameClock.game_seconds,
		"deadline_game_seconds": GameClock.game_seconds + duration,
		"completion": completion,
	}
	_character.head_status().push_override(str(use.get("action_name", "使用物品")))
	return {"ok": true, "pending": true}


func tick(_delta: float) -> void:
	if _active.is_empty():
		return
	var deadline: float = float(_active.get("deadline_game_seconds", 0.0))
	if GameClock.game_seconds >= deadline:
		_commit()


# cancel/preempt：清状态 + 撤 label override。不 fire completion —— caller (runner) 自己负责
# lifecycle 重置（_active/_action_id/_completion）。
func cancel() -> void:
	if _active.is_empty():
		return
	_active = {}
	_character.head_status().clear_override()


func preempt() -> void:
	cancel()


func _commit() -> void:
	if _active.is_empty():
		return
	var active := _active.duplicate(true)
	_active = {}
	_character.head_status().clear_override()
	var result := _use_slot(
		int(active.get("slot_index", -1)),
		bool(active.get("food_only", false)),
		str(active.get("item_id", ""))
	)
	var completion: Callable = active.get("completion", Callable())
	if not completion.is_valid():
		return
	if not bool(result.get("ok", false)):
		completion.call(false, str(result.get("message", "use_item failed")), {})
		return
	var result_v: Variant = result.get("result", {})
	var final_result: Dictionary = {}
	if typeof(result_v) == TYPE_DICTIONARY:
		final_result = result_v as Dictionary
	completion.call(true, "", final_result)


func _use_slot(slot_index: int, food_only: bool = false, expected_item_id: String = "") -> Dictionary:
	var slot := _character.inventory_ops().get_slot(slot_index)
	var view := InventorySlotData.of(slot)
	if not expected_item_id.is_empty() and view.id() != expected_item_id:
		return {"ok": false, "message": _msg("error.use_item.slot_changed")}
	var use := ItemUse.resolve(view, food_only)
	if not bool(use.get("ok", false)):
		return {"ok": false, "message": str(use.get("message", "use_item failed"))}

	var result := ItemUse.execute(_character, view, use)
	if not bool(result.get("ok", false)):
		return {"ok": false, "message": _fmt("error.use_item.script_error_format", [str(result.get("error", ""))])}

	_character.inventory_ops().remove_item(slot_index, 1)
	var item := use.get("item") as Item
	if item != null and item.kind == "food":
		_character.refresh_statuses()
	var actor_id := _character.backend_character_id()
	_character.emit_world_event("use_item", {
		"actorId": actor_id,
		"affectedCharacterIds": _character.perception().voice_affected_character_ids("far"),
		"itemId": view.id(),
		"targetId": actor_id,
	})
	return {"ok": true, "result": {"itemId": view.id(), "quantity": 1}}


func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
