class_name NpcContextMenu
extends CanvasLayer

# 玩家右键 NPC 时显示的操作菜单。CameraRig 拾取 NPC 后通过 EventBus 发信号，
# 这里负责弹小面板（NPC 名 + 两按钮：说话 / 提出交易），选完后 emit 信号让 town
# 来处理（走近 + 触发动作）。
#
# UI 全部程序化构建，参考 NpcHoverStatus 的同款做法（避免再开一个 .tscn）。

signal talk_selected(npc: Node)
signal trade_selected(npc: Node)

const SCREEN_PADDING := 12.0
const OFFSET := Vector2(8.0, 8.0)

var _panel: PanelContainer = null
var _title: Label = null
var _talk_button: Button = null
var _trade_button: Button = null
var _target_npc: Node = null


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.npc_context_menu_requested.connect(_on_requested)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "NpcContextPanel"
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48, 1.0))
	vbox.add_child(_title)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	_talk_button = Button.new()
	_talk_button.text = tr("ui.npc_menu.talk")
	_talk_button.pressed.connect(_on_talk_pressed)
	vbox.add_child(_talk_button)

	_trade_button = Button.new()
	_trade_button.text = tr("ui.npc_menu.trade")
	_trade_button.pressed.connect(_on_trade_pressed)
	vbox.add_child(_trade_button)


func _on_requested(npc: Node, screen_position: Vector2) -> void:
	if npc == null or not is_instance_valid(npc):
		return
	_target_npc = npc
	var display := ""
	if npc.has_method("head_ui_display_name"):
		display = str(npc.call("head_ui_display_name"))
	if display.strip_edges().is_empty():
		display = npc.name
	_title.text = display
	_panel.visible = true
	# 等下一帧让 PanelContainer 完成 layout 后再算尺寸定位
	_place_panel.call_deferred(screen_position)


func _place_panel(anchor: Vector2) -> void:
	if not _panel.visible:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var panel_size := _panel.get_combined_minimum_size()
	_panel.size = panel_size

	var pos := anchor + OFFSET
	if pos.x + panel_size.x > viewport_size.x - SCREEN_PADDING:
		pos.x = anchor.x - panel_size.x - OFFSET.x
	if pos.y + panel_size.y > viewport_size.y - SCREEN_PADDING:
		pos.y = anchor.y - panel_size.y - OFFSET.y

	var max_x := maxf(SCREEN_PADDING, viewport_size.x - panel_size.x - SCREEN_PADDING)
	var max_y := maxf(SCREEN_PADDING, viewport_size.y - panel_size.y - SCREEN_PADDING)
	_panel.position = Vector2(
		clampf(pos.x, SCREEN_PADDING, max_x),
		clampf(pos.y, SCREEN_PADDING, max_y)
	)


func _unhandled_input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	# Esc 关闭
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_close()
			get_viewport().set_input_as_handled()
			return
	# 任意鼠标按下且不在面板矩形内 → 关闭（不吞事件，让 CameraRig 等正常处理）
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var rect := Rect2(_panel.position, _panel.size)
		if not rect.has_point((event as InputEventMouseButton).position):
			_close()


func _close() -> void:
	_panel.visible = false
	_target_npc = null


func _on_talk_pressed() -> void:
	var npc := _target_npc
	_close()
	if npc != null and is_instance_valid(npc):
		talk_selected.emit(npc)


func _on_trade_pressed() -> void:
	var npc := _target_npc
	_close()
	if npc != null and is_instance_valid(npc):
		trade_selected.emit(npc)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.05, 0.96)
	style.border_color = Color(0.88, 0.70, 0.38, 0.85)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	return style
