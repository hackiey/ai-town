class_name ChatBar
extends CanvasLayer

# 屏幕底部输入框 + 上方聊天 log。玩家输入 → emit command_submitted。
# 文本本身的语义由上层（town.gd 的 client 分支）解释：
# - 普通文本 → 当成对附近喊话（say_to）
# - 以 `/command` 开头 → 当成对自己角色下达的命令，走 player.command
#
# 聊天 log：订阅 EventBus.character_spoke（server 通过 Character.show_speech RPC 推过来），
# 显示最近 LOG_MAX_LINES 条。BBCode 实现颜色区分，scroll_following 自动滚到底。
#
# Focus / 输入吞噬：
# - LineEdit 拿到键盘焦点时按键不会落到 _unhandled_input，所以 wasd 等不会
#   误触发；但鼠标点击只有在 LineEdit 矩形内被它吞掉，框外的左键点地仍由
#   CameraRig.click_to_move 处理（这是想要的）。
# - log 区域 mouse_filter=2 (IGNORE) → 鼠标穿透，不挡点地。
# - 提交后清空文本并把焦点交还（release_focus），避免输入框继续吃键盘输入。

signal command_submitted(text: String, directed_target_id: String)

const LOG_MAX_LINES := 50

# 折叠/展开两套尺寸 + 字号。展开时 Log 抓鼠标（可选中文本、滚轮），折叠回 IGNORE 保留"鼠标穿透不挡点地"。
const COLLAPSED_OFFSET_TOP := -200.0
const EXPANDED_OFFSET_TOP := -520.0
const COLLAPSED_OFFSET_RIGHT := 496.0
const EXPANDED_OFFSET_RIGHT := 820.0
const COLLAPSED_LOG_MIN_H := 120.0
const EXPANDED_LOG_MIN_H := 440.0
const EXPANDED_FONT_SIZE := 18

# scroll 容差：scrollbar 浮点偏差时仍判定为"在底部"。
const SCROLL_BOTTOM_TOLERANCE := 4.0

@onready var _input: LineEdit = $Root/InputRow/Input
@onready var _send: Button = $Root/InputRow/Send
@onready var _expand: Button = $Root/InputRow/Expand
@onready var _log: RichTextLabel = $Root/Log
@onready var _root: VBoxContainer = $Root

var _log_lines: Array[String] = []
var _expanded := false

# 定向模式：右键 NPC → 选"说话"时设置；下一次提交按 say_to(target) 发，发完自动清。
var _directed_target_id: String = ""
var _directed_target_name: String = ""
var _directed_label: Label = null


func _ready() -> void:
	_input.text_submitted.connect(_on_submitted)
	_send.pressed.connect(_on_send_pressed)
	_expand.pressed.connect(_toggle_expanded)
	EventBus.character_spoke.connect(_on_character_spoke)
	EventBus.notification_posted.connect(_on_notification)
	_apply_expanded_state()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	# Esc：聚焦时清掉定向 + 失焦（即便没定向也失焦，给玩家"退出输入"的直觉）
	if key.keycode == KEY_ESCAPE and _input.has_focus():
		var had_directed := not _directed_target_id.is_empty()
		clear_directed_target()
		_input.release_focus()
		if had_directed:
			get_viewport().set_input_as_handled()
		return
	# Enter 键在输入框未聚焦时把焦点切过去；聚焦后输入框自己处理 Enter（提交）
	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		if not _input.has_focus():
			_input.grab_focus()
			get_viewport().set_input_as_handled()


func _on_send_pressed() -> void:
	_on_submitted(_input.text)


func _on_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return
	var target := _directed_target_id
	command_submitted.emit(trimmed, target)
	_input.text = ""
	_input.release_focus()
	# 定向只生效一句：发完清掉，再说要再右键
	if not target.is_empty():
		clear_directed_target()


# 外部接口（town.gd 收到 NPC 菜单"说话"选择后调）。
func set_directed_target(target_id: String, target_name: String) -> void:
	_directed_target_id = target_id.strip_edges()
	_directed_target_name = target_name.strip_edges()
	_ensure_directed_label()
	if _directed_target_id.is_empty():
		_directed_label.visible = false
		return
	var display := _directed_target_name if not _directed_target_name.is_empty() else _directed_target_id
	_directed_label.text = tr("ui.chat.directed_to") % display
	_directed_label.visible = true
	_input.grab_focus()


func clear_directed_target() -> void:
	_directed_target_id = ""
	_directed_target_name = ""
	if _directed_label != null:
		_directed_label.visible = false


func _ensure_directed_label() -> void:
	if _directed_label != null:
		return
	_directed_label = Label.new()
	_directed_label.name = "DirectedLabel"
	_directed_label.add_theme_font_size_override("font_size", 12)
	_directed_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.36, 1.0))
	_directed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_directed_label.visible = false
	# 插在 InputRow 之前（Log 下面、Input 上面）
	var input_row: Node = _root.get_node("InputRow")
	_root.add_child(_directed_label)
	_root.move_child(_directed_label, input_row.get_index())


# Server 通过 Character.show_speech RPC 把说话事件广播过来 → 本端的 Character
# 转 EventBus 信号 → 这里转成一行 log。Character.show_speech 入口已按 speech.lua
# 算出的 affected_character_ids 过滤了"本地玩家听不到的"，所以这里到的都是该显示的。
# 格式：[06:08][名字]对[名字]说(near/far)：text；无 target 时省略"对…"段。
func _on_character_spoke(character_id: String, text: String, volume: String, target_character_id: String, affected_character_ids: PackedStringArray) -> void:
	var speaker := _resolve_character_name(character_id)
	var time_str := "%02d:%02d" % [GameClock.game_hour(), GameClock.game_minute()]
	var color := "#aac8ff" if volume == "far" else "#cfead0"
	var head: String
	if not target_character_id.is_empty():
		var target := _resolve_character_name(target_character_id)
		head = "[%s][%s]对[%s]说(%s)：" % [time_str, speaker, target, volume]
	else:
		head = "[%s][%s]说(%s)：" % [time_str, speaker, volume]
	_append_line("[color=%s]%s[/color]%s" % [color, head, text])


# character_id → 显示名。先扫 npcs/players 组找 Character node 用其 head_ui_display_name；
# 找不到再退到 i18n key（npc.<id>.name），最后用 raw id 兜底，保证永远有可读字符串。
func _resolve_character_name(character_id: String) -> String:
	var cid := character_id.strip_edges()
	if cid.is_empty():
		return "?"
	var tree := get_tree()
	if tree != null:
		for group_name in ["npcs", "players"]:
			for node in tree.get_nodes_in_group(group_name):
				if not (node is Character):
					continue
				var ch := node as Character
				if ch.backend_character_id() == cid:
					var disp: String = ch.head_ui_display_name().strip_edges()
					if not disp.is_empty():
						return disp
	var key := "npc.%s.name" % cid
	var translated := tr(key)
	if translated != key and not translated.strip_edges().is_empty():
		return translated
	return cid


# 系统通知（命令成功/失败、本地校验报错等）。颜色按 level 区分，前缀 [系统] 让玩家
# 一眼跟"角色说话"分开。直接调用 EventBus.notification_posted 也走这条路径。
func notify(text: String, level: String = "info") -> void:
	EventBus.notification_posted.emit(text, level)


func _on_notification(text: String, level: String) -> void:
	var color := _color_for_level(level)
	_append_line("[color=%s]%s %s[/color]" % [color, tr("ui.chat.system_prefix"), text])


func _color_for_level(level: String) -> String:
	match level:
		"success": return "#9ce6a0"
		"warn":    return "#f0c060"
		"error":   return "#ff7a7a"
		_:         return "#cfcfcf"


func _append_line(line: String) -> void:
	# 只有原本就贴底，新消息才把视图拉到底；否则保持玩家当前的滚动位置，
	# 让向上翻看历史时不被新消息打断。RichTextLabel 改文本后布局要一帧才更新，
	# 所以滚到底的动作要 defer。
	var was_at_bottom := _is_scrolled_to_bottom()
	_log_lines.append(line)
	if _log_lines.size() > LOG_MAX_LINES:
		_log_lines = _log_lines.slice(_log_lines.size() - LOG_MAX_LINES)
	_log.text = "\n".join(_log_lines)
	if was_at_bottom:
		_scroll_to_bottom_deferred()


func _is_scrolled_to_bottom() -> bool:
	var sb := _log.get_v_scroll_bar()
	if sb == null:
		return true
	# max_value == 0 或内容没填满视口时永远算"在底部"。
	if sb.max_value <= sb.page:
		return true
	return sb.value + sb.page >= sb.max_value - SCROLL_BOTTOM_TOLERANCE


func _scroll_to_bottom_deferred() -> void:
	# 等两帧确保 RichTextLabel 重新算出新的 max_value 再设 value。
	await get_tree().process_frame
	await get_tree().process_frame
	var sb := _log.get_v_scroll_bar()
	if sb != null:
		sb.value = sb.max_value


func _toggle_expanded() -> void:
	_expanded = not _expanded
	_apply_expanded_state()


func _apply_expanded_state() -> void:
	var was_at_bottom := _is_scrolled_to_bottom()
	if _expanded:
		_root.offset_top = EXPANDED_OFFSET_TOP
		_root.offset_right = EXPANDED_OFFSET_RIGHT
		_log.custom_minimum_size = Vector2(0, EXPANDED_LOG_MIN_H)
		_log.add_theme_font_size_override("normal_font_size", EXPANDED_FONT_SIZE)
		_log.add_theme_font_size_override("bold_font_size", EXPANDED_FONT_SIZE)
		_log.add_theme_font_size_override("italics_font_size", EXPANDED_FONT_SIZE)
		_log.add_theme_font_size_override("mono_font_size", EXPANDED_FONT_SIZE)
		# 展开时让 Log 接收鼠标，玩家可用滚轮翻历史、按住拖选文本；
		# 代价是 Log 矩形内的左键不会落到 click-to-move，符合"专注阅读"语义。
		_log.mouse_filter = Control.MOUSE_FILTER_STOP
		_expand.text = tr("ui.chat.collapse")
	else:
		_root.offset_top = COLLAPSED_OFFSET_TOP
		_root.offset_right = COLLAPSED_OFFSET_RIGHT
		_log.custom_minimum_size = Vector2(0, COLLAPSED_LOG_MIN_H)
		_log.remove_theme_font_size_override("normal_font_size")
		_log.remove_theme_font_size_override("bold_font_size")
		_log.remove_theme_font_size_override("italics_font_size")
		_log.remove_theme_font_size_override("mono_font_size")
		_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_expand.text = tr("ui.chat.expand")
	if was_at_bottom:
		_scroll_to_bottom_deferred()
