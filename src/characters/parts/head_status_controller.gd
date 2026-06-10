class_name HeadStatusController
extends RefCounted

# Character 头顶气泡状态机。渲染已经迁到 2D HeadNameplateLayer；这里只保留
# server-authoritative 文本状态、RPC 转发和发言淡出计时。
#
# 边界：
# - **5 个 @rpc 函数必须留在 Character Node**（Godot 限制：RefCounted 不能持 @rpc）。
#   Character 端的 @rpc shim 只做 1 行转发：apply_remote_*。
# - 外部动作通过 `character.head_status().push_override/clear_override` 改状态；
#   RPC 入口 still on Character。
# - 状态字段 + 渲染逻辑 + 文本 / 颜色都搬到这里。Character 留 facade
#   （RPC shim / set_backend_thinking / sync_to_clients）转发给 controller。
# - 发言优先；无发言时显示状态/动作/思考。状态气泡只显示 emoji/短标记。

const _THINKING_BUBBLE_FRAMES := ["🤔", "🤔💭", "💭", "✨"]
const _THINKING_BUBBLE_FRAME_SEC := 0.45
const _HEAD_STATUS_RESEND_SEC := 1.0
# 说话气泡阅读速度：CJK 字符权重 1，ASCII 0.5（窄）。每秒约 3 个权重单位
# ≈ 普通阅读节奏。下限走 character.speech_bubble_hold_sec（默认 3s），保证
# 一两个字也至少能看清。
const _SPEECH_BUBBLE_UNITS_PER_SEC := 3.0
const _SLEEPING_STATUS_TEXT := "💤"
const _EATING_STATUS_EMOJI := "🍽️"
const _WORKING_STATUS_EMOJI := "🛠️"
const _CRAFTING_STATUS_EMOJI := "🔨"
const _BUSY_STATUS_EMOJI := "⚙️"

var character: Character

var _speech_text: String = ""
var _speech_bubble_remaining: float = 0.0

var _status_text: String = ""
var _override_text: String = ""
var _thinking: bool = false
var _thinking_sources: Dictionary = {}
var _thinking_frame: int = 0
var _thinking_timer: float = 0.0
var _status_sent_at_sec: float = -9999.0
var _override_sent_at_sec: float = -9999.0
var _thinking_sent_at_sec: float = -9999.0
var _rpc_enabled: bool = true


func _init(owner: Character) -> void:
	character = owner


func set_rpc_enabled(enabled: bool) -> void:
	_rpc_enabled = enabled


func _can_send_rpc() -> bool:
	return _rpc_enabled and RunMode.is_runtime() and character != null and is_instance_valid(character) and character.is_inside_tree()


# ─── server-side state setters（来自 Character facade）──────

# 计算当前应显示的 status text（hungry / idle / 子类 override），与上次差异 / resend 窗口
# 触发时通过 RPC 推给 client。同时把 override / thinking 三个状态的 resend 窗口也跑一遍。
func sync_to_clients() -> void:
	if not _can_send_rpc():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var next: String = String(character._head_status_text()).strip_edges()
	if _status_text != next or now - _status_sent_at_sec >= _HEAD_STATUS_RESEND_SEC:
		_status_text = next
		_status_sent_at_sec = now
		character.set_status_label_rpc.rpc(next)
	if not _override_text.is_empty() and now - _override_sent_at_sec >= _HEAD_STATUS_RESEND_SEC:
		_override_sent_at_sec = now
		character.show_action_label_rpc.rpc(_override_text)
	if _thinking and now - _thinking_sent_at_sec >= _HEAD_STATUS_RESEND_SEC:
		_thinking_sent_at_sec = now
		character.set_thinking_status_rpc.rpc(true)


func push_override(text: String) -> void:
	_override_text = text.strip_edges()
	if not _can_send_rpc():
		return
	_override_sent_at_sec = Time.get_ticks_msec() / 1000.0
	character.show_action_label_rpc.rpc(_override_text)


func clear_override() -> void:
	_override_text = ""
	if not _can_send_rpc():
		return
	_override_sent_at_sec = Time.get_ticks_msec() / 1000.0
	character.hide_action_label_rpc.rpc()


func set_thinking(active: bool, source: String = "") -> void:
	if not RunMode.is_runtime():
		return
	var source_key := source.strip_edges()
	if not source_key.is_empty():
		if active:
			_thinking_sources[source_key] = true
		else:
			_thinking_sources.erase(source_key)
		_set_thinking_active(not _thinking_sources.is_empty())
		return
	_thinking_sources = {}
	_set_thinking_active(active)


func _set_thinking_active(active: bool) -> void:
	if _thinking == active:
		return
	_thinking = active
	if not _can_send_rpc():
		return
	_thinking_sent_at_sec = Time.get_ticks_msec() / 1000.0
	character.set_thinking_status_rpc.rpc(active)


# ─── client-side state setters（来自 Character RPC shim）────

func apply_remote_override_text(text: String) -> void:
	_override_text = text.strip_edges()
	_update_process_state()


func apply_remote_clear_override() -> void:
	_override_text = ""
	_update_process_state()


func apply_remote_status_text(text: String) -> void:
	_status_text = text.strip_edges()
	_update_process_state()


func apply_remote_thinking(active: bool) -> void:
	_thinking = active
	_thinking_frame = 0
	_thinking_timer = _THINKING_BUBBLE_FRAME_SEC
	_update_process_state()


# ─── speech bubble ─────────────────────────────────────

func show_speech_bubble(text: String) -> float:
	_speech_text = text.strip_edges()
	if _speech_text.is_empty():
		_speech_bubble_remaining = 0.0
		_update_process_state()
		return 0.0
	var dynamic_hold := _speech_units(_speech_text) / _SPEECH_BUBBLE_UNITS_PER_SEC
	var hold := maxf(character.speech_bubble_hold_sec, dynamic_hold)
	_speech_bubble_remaining = hold + character.speech_bubble_fade_sec
	_update_process_state()
	return _speech_bubble_remaining


func _speech_units(text: String) -> float:
	var units := 0.0
	for i in text.length():
		var code := text.unicode_at(i)
		units += 0.5 if code >= 33 and code <= 126 else 1.0
	return units


# ─── per-frame tick (Character._process 委托) ─────────────

func update_process(delta: float) -> void:
	if _speech_bubble_remaining > 0.0:
		_speech_bubble_remaining -= delta
		if _speech_bubble_remaining <= 0.0:
			_speech_bubble_remaining = 0.0
			_speech_text = ""
	if _thinking and _THINKING_BUBBLE_FRAMES.size() > 1:
		_thinking_timer -= delta
		if _thinking_timer <= 0.0:
			_thinking_timer = _THINKING_BUBBLE_FRAME_SEC
			_thinking_frame = (_thinking_frame + 1) % _THINKING_BUBBLE_FRAMES.size()
	_update_process_state()


func bubble_state() -> Dictionary:
	var mode := _current_mode()
	var text := _current_text(mode)
	return {
		"visible": not text.is_empty(),
		"mode": mode,
		"text": text,
		"alpha": _speech_alpha() if mode == "speech" else 1.0,
	}


func _speech_alpha() -> float:
	if character.speech_bubble_fade_sec <= 0.0:
		return 1.0
	if _speech_bubble_remaining >= character.speech_bubble_fade_sec:
		return 1.0
	return clampf(_speech_bubble_remaining / character.speech_bubble_fade_sec, 0.0, 1.0)


func _current_mode() -> String:
	if _speech_bubble_remaining > 0.0 and not _speech_text.is_empty():
		return "speech"
	if _thinking:
		return "thinking"
	if not _override_text.is_empty():
		return "override"
	if not _status_text.is_empty():
		return "status"
	return ""


func _current_text(mode: String) -> String:
	match mode:
		"speech":
			return _speech_text
		"thinking":
			if _THINKING_BUBBLE_FRAMES.is_empty():
				return ""
			return str(_THINKING_BUBBLE_FRAMES[_thinking_frame % _THINKING_BUBBLE_FRAMES.size()])
		"override":
			return _override_display_text(_override_text)
		"status":
			return _status_display_text(_status_text)
	return ""


func _status_display_text(status_text: String) -> String:
	var normalized := status_text.strip_edges()
	if normalized.is_empty():
		return ""
	if _matches_head_status_key(normalized, "ui.head_status.hungry"):
		return ""
	if _matches_head_status_key(normalized, "ui.head_status.sleeping"):
		return _SLEEPING_STATUS_TEXT
	if _matches_head_status_key(normalized, "ui.head_status.working"):
		return _WORKING_STATUS_EMOJI
	if _matches_head_status_key(normalized, "ui.head_status.crafting"):
		return _CRAFTING_STATUS_EMOJI
	if _matches_head_status_key(normalized, "ui.head_status.busy"):
		return _BUSY_STATUS_EMOJI
	return normalized if character._should_show_head_status_bubble(normalized) else ""


func _matches_head_status_key(status_text: String, key: String) -> bool:
	return status_text == key or status_text == character.tr(key).strip_edges()


func _work_emoji_for_text(text: String) -> String:
	var normalized := text.strip_edges().to_lower()
	if normalized.is_empty():
		return ""
	if _contains_any(normalized, ["炼金", "alchemy"]):
		return "🧪"
	if _contains_any(normalized, ["吃", "饭", "食物", "eat", "food"]):
		return _EATING_STATUS_EMOJI
	if _contains_any(normalized, ["浇水", "water", "well"]):
		return "💧"
	if _contains_any(normalized, ["种植", "plant", "seed"]):
		return "🌱"
	if _contains_any(normalized, ["收获", "harvest"]):
		return "🌾"
	if _contains_any(normalized, ["除虫", "pest", "bug"]):
		return "🐛"
	if _contains_any(normalized, ["铲除", "dig", "mine", "矿"]):
		return "⛏️"
	if _contains_any(normalized, ["伐木", "砍木", "chop", "lumber"]):
		return "🪓"
	if _contains_any(normalized, ["烘", "烤", "煮", "灶", "cook", "bake", "boil", "stove"]):
		return "🍳"
	if _contains_any(normalized, ["磨", "grind", "mill"]):
		return "🌾"
	if _contains_any(normalized, ["晾", "dry"]):
		return "☀️"
	if _contains_any(normalized, ["锻", "铁匠", "anvil", "forge", "hammer"]):
		return "🔨"
	if _contains_any(normalized, ["熔", "炉", "smelt", "furnace"]):
		return "🔥"
	return _WORKING_STATUS_EMOJI


func _override_display_text(text: String) -> String:
	var normalized := text.strip_edges()
	if normalized.is_empty():
		return ""
	var emoji := _work_emoji_for_text(normalized)
	if _is_workstation_label(normalized):
		return "%s %s" % [emoji, normalized]
	return emoji


func _is_workstation_label(text: String) -> bool:
	return text.find(" · ") >= 0 or text.find("·") >= 0


func _contains_any(text: String, needles: Array[String]) -> bool:
	for needle in needles:
		if text.find(needle) >= 0:
			return true
	return false


func _update_process_state() -> void:
	var speech_active: bool = _speech_bubble_remaining > 0.0
	character.set_process(speech_active or _thinking)
