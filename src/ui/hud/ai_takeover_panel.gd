class_name AiTakeoverPanel
extends CanvasLayer

# 玩家「AI 托管」开关 + 模型选择弹窗（纯 client UI，程序化构建，参考 npc_context_menu.gd）。
#
# 流程：
#   - 右上角按钮：未托管时「AI 托管」→ 点开弹窗；托管中「取消托管」→ 直接 request_ai_release。
#   - 弹窗：选 agent 类型（默认 two-track）+ 两个模型（action / thinking），确认 → request_ai_takeover。
#   - 模型列表来自 backend：弹窗打开时 request_available_models，server 回经 EventBus 填下拉。
#   - 托管状态变化经 EventBus.ai_takeover_state_changed 同步，更新按钮文案。
#
# UI 是 client 概念，server（headless）不实例化；set_player(null) 时整体隐藏。

const AGENT_TYPES := ["two-track"]

var _player: Node = null
var _ai_active: bool = false
var _available_models: PackedStringArray = PackedStringArray()

var _toggle_button: Button = null
var _dialog: PanelContainer = null
var _agent_type_btn: OptionButton = null
var _action_model_btn: OptionButton = null
var _thinking_model_btn: OptionButton = null
var _confirm_button: Button = null
var _models_hint: Label = null


func _ready() -> void:
	layer = 9
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.available_models_received.connect(_on_available_models)
	EventBus.ai_takeover_state_changed.connect(_on_ai_state_changed)
	_refresh_visibility()


func set_player(player: Node) -> void:
	_player = player
	if player == null:
		_ai_active = false
		_close_dialog()
	_refresh_visibility()
	_refresh_toggle_text()


func _build_ui() -> void:
	# 右上角开关按钮（显式 anchor+offset，避免 preset 与 position 打架）
	_toggle_button = Button.new()
	_toggle_button.text = tr("ui.ai_takeover.button_takeover")
	_toggle_button.anchor_left = 1.0
	_toggle_button.anchor_right = 1.0
	_toggle_button.anchor_top = 0.0
	_toggle_button.anchor_bottom = 0.0
	_toggle_button.offset_left = -150.0
	_toggle_button.offset_top = 12.0
	_toggle_button.offset_right = -12.0
	_toggle_button.offset_bottom = 44.0
	_toggle_button.pressed.connect(_on_toggle_pressed)
	add_child(_toggle_button)

	# 弹窗（打开时再居中，见 _open_dialog）
	_dialog = PanelContainer.new()
	_dialog.visible = false
	_dialog.add_theme_stylebox_override("panel", _panel_style())
	add_child(_dialog)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	_dialog.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(320.0, 0.0)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = tr("ui.ai_takeover.dialog_title")
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48, 1.0))
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	_agent_type_btn = _add_labeled_option(vbox, tr("ui.ai_takeover.agent_type"))
	for t in AGENT_TYPES:
		_agent_type_btn.add_item(t)
	_agent_type_btn.select(0)

	_action_model_btn = _add_labeled_option(vbox, tr("ui.ai_takeover.action_model"))
	_thinking_model_btn = _add_labeled_option(vbox, tr("ui.ai_takeover.thinking_model"))

	_models_hint = Label.new()
	_models_hint.add_theme_font_size_override("font_size", 12)
	_models_hint.add_theme_color_override("font_color", Color(0.9, 0.6, 0.4, 1.0))
	_models_hint.visible = false
	vbox.add_child(_models_hint)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)

	var cancel := Button.new()
	cancel.text = tr("ui.ai_takeover.cancel")
	cancel.pressed.connect(_close_dialog)
	buttons.add_child(cancel)

	_confirm_button = Button.new()
	_confirm_button.text = tr("ui.ai_takeover.confirm")
	_confirm_button.pressed.connect(_on_confirm_pressed)
	buttons.add_child(_confirm_button)


func _add_labeled_option(parent: VBoxContainer, label_text: String) -> OptionButton:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(opt)
	parent.add_child(row)
	return opt


func _on_toggle_pressed() -> void:
	if _player == null:
		return
	if _ai_active:
		_player.request_ai_release.rpc_id(1)
		return
	_open_dialog()


func _open_dialog() -> void:
	if _player == null:
		return
	_dialog.visible = true
	# 向 server 要可用模型（server 再问 backend），回来经 EventBus 填下拉。
	_player.request_available_models.rpc_id(1)
	_refresh_models_state()
	_center_dialog.call_deferred()


func _center_dialog() -> void:
	if _dialog == null or not _dialog.visible:
		return
	var panel_size := _dialog.get_combined_minimum_size()
	_dialog.size = panel_size
	var viewport_size := get_viewport().get_visible_rect().size
	_dialog.position = (viewport_size - panel_size) * 0.5


func _close_dialog() -> void:
	if _dialog != null:
		_dialog.visible = false


func _on_available_models(models: PackedStringArray) -> void:
	_available_models = models
	_fill_model_option(_action_model_btn)
	_fill_model_option(_thinking_model_btn)
	_refresh_models_state()


func _fill_model_option(opt: OptionButton) -> void:
	if opt == null:
		return
	var prev := opt.get_item_text(opt.selected) if opt.selected >= 0 else ""
	opt.clear()
	for m in _available_models:
		opt.add_item(m)
	# 尽量保留之前的选择
	if not prev.is_empty():
		for i in opt.item_count:
			if opt.get_item_text(i) == prev:
				opt.select(i)
				return
	if opt.item_count > 0:
		opt.select(0)


func _refresh_models_state() -> void:
	var has_models := _available_models.size() > 0
	if _confirm_button != null:
		_confirm_button.disabled = not has_models
	if _models_hint != null:
		_models_hint.visible = not has_models
		_models_hint.text = tr("ui.ai_takeover.no_models")


func _on_confirm_pressed() -> void:
	if _player == null:
		return
	var agent_type := _agent_type_btn.get_item_text(_agent_type_btn.selected) if _agent_type_btn.selected >= 0 else "two-track"
	var action_model := _action_model_btn.get_item_text(_action_model_btn.selected) if _action_model_btn.selected >= 0 else ""
	var thinking_model := _thinking_model_btn.get_item_text(_thinking_model_btn.selected) if _thinking_model_btn.selected >= 0 else ""
	if action_model.is_empty() or thinking_model.is_empty():
		_refresh_models_state()
		return
	_player.request_ai_takeover.rpc_id(1, agent_type, action_model, thinking_model)
	_close_dialog()


func _on_ai_state_changed(active: bool) -> void:
	_ai_active = active
	_refresh_toggle_text()
	if active:
		_close_dialog()


func _refresh_toggle_text() -> void:
	if _toggle_button == null:
		return
	_toggle_button.text = tr("ui.ai_takeover.button_release") if _ai_active else tr("ui.ai_takeover.button_takeover")


func _refresh_visibility() -> void:
	if _toggle_button != null:
		_toggle_button.visible = _player != null


func _unhandled_input(event: InputEvent) -> void:
	if _dialog == null or not _dialog.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_close_dialog()
			get_viewport().set_input_as_handled()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.05, 0.97)
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
