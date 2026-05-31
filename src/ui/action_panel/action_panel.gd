class_name ActionPanel
extends CanvasLayer

# 万能动词 UI（client only）：所有工作站共用同一套槽位 + 动作按钮。
# - 监听 EventBus.workstation_proximity_changed 维护 _active_workstation
# - 玩家在 workstation Area3D 内按 E → 弹面板（按 ESC 或走出范围 → 关）
# - 槽位数固定 6 个（generic labels）。具体反应需要几个由 dispatcher 按 reaction.inputs 匹配
# - 动作按钮：从 Workstations.by_id(ws_id).verbs 填；有 sub_options 时展开为具体动作
# - 点击动作按钮 → request_craft.rpc_id(1, verb, ws_id, sub_option)
#
# 设计：docs/architecture/crafting-interaction.md §2.2 / §2.6 + reaction-schema.md §6.1

const ACTION_SLOT := preload("res://src/ui/action_panel/action_slot.gd")
const SLOT_COL_LIMIT := 4
# Fallback：找不到 workstation Resource 时用。正常路径走 Workstation.slot_count（默认 5）。
const SLOT_COUNT_FALLBACK := 5

var _player: Node = null
var _active_workstation: Node = null
var _open_workstation: Node = null
var _slots: Array = []

# UI 控件（部分动态生成）
@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/Title
@onready var _verb_label: Label = $Root/Panel/Margin/VBox/Verb
@onready var _grid: GridContainer = $Root/Panel/Margin/VBox/Grid
@onready var _close_btn: Button = $Root/Panel/Margin/VBox/Buttons/Close
@onready var _hint: Label = $Hint
@onready var _vbox: VBoxContainer = $Root/Panel/Margin/VBox

var _action_buttons_box: VBoxContainer
var _action_buttons: Array[Button] = []

# 进度条（动态注入为底部浮层）。craft / 玩家动作 started 时显示，completed/cancelled 隐藏。
# craft active 期间禁用动作按钮防止误点。process tick 插值显示剩余时间。
# 时基用 GameClock.game_seconds：duration 是 game-second，timewarp 时进度条也跟着加速。
var _progress_box: VBoxContainer
var _progress_label: Label
var _progress_bar: ProgressBar
var _craft_started_at_game_seconds: float = 0.0
var _craft_duration_game_seconds: float = 0.0
var _progress_is_craft: bool = false

# Walk-cancel modal：制造期间玩家点 walk 目标 → server 拒绝 + 通过 EventBus 通知，
# 这里弹 ConfirmationDialog。Yes → confirm_cancel_craft_and_move RPC + 走过去
var _walk_cancel_dialog: ConfirmationDialog
var _pending_walk_target: Vector3 = Vector3.ZERO


func _ready() -> void:
	_root.visible = false
	_hint.visible = false
	EventBus.workstation_proximity_changed.connect(_on_proximity_changed)
	EventBus.craft_started.connect(_on_craft_started)
	EventBus.craft_completed.connect(_on_craft_completed)
	EventBus.craft_cancelled.connect(_on_craft_cancelled)
	EventBus.player_action_started.connect(_on_player_action_started)
	EventBus.player_action_completed.connect(_on_player_action_completed)
	EventBus.player_action_cancelled.connect(_on_player_action_cancelled)
	EventBus.craft_walk_block_requested.connect(_on_walk_block_requested)
	_close_btn.pressed.connect(close)
	_inject_action_buttons()
	_inject_progress_bar()
	_inject_walk_cancel_dialog()
	set_process(false)


# 进度条 + 状态文字注入为全局底部浮层。默认隐藏。
func _inject_progress_bar() -> void:
	_progress_box = VBoxContainer.new()
	_progress_box.add_theme_constant_override("separation", 4)
	_progress_box.anchor_left = 0.5
	_progress_box.anchor_top = 1.0
	_progress_box.anchor_right = 0.5
	_progress_box.anchor_bottom = 1.0
	_progress_box.offset_left = -220.0
	_progress_box.offset_top = -116.0
	_progress_box.offset_right = 220.0
	_progress_box.offset_bottom = -64.0
	_progress_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_box.visible = false
	_progress_label = Label.new()
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_progress_label.add_theme_constant_override("outline_size", 4)
	_progress_box.add_child(_progress_label)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.step = 0.001
	_progress_bar.show_percentage = true
	_progress_bar.custom_minimum_size = Vector2(0, 18)
	_progress_box.add_child(_progress_bar)
	add_child(_progress_box)


# 把动作按钮区注入到槽位下方，保持 .tscn 结构尽量简单。
func _inject_action_buttons() -> void:
	_verb_label.visible = false
	_action_buttons_box = VBoxContainer.new()
	_action_buttons_box.add_theme_constant_override("separation", 8)
	_vbox.add_child(_action_buttons_box)
	_vbox.move_child(_action_buttons_box, _grid.get_index() + 1)


func set_player(player: Node) -> void:
	_player = player


func _on_proximity_changed(workstation: Node, entered: bool) -> void:
	# 容器型 workstation 由 ContainerPanel 处理（独立 UI），ActionPanel 不接管。
	if workstation != null and workstation.is_in_group("containers"):
		return
	if entered:
		_active_workstation = workstation
		_show_hint(workstation)
	else:
		if workstation == _active_workstation:
			_active_workstation = null
			_hint.visible = false
		if workstation == _open_workstation and _root.visible:
			close()


func _show_hint(workstation: Node) -> void:
	var prompt_text: String = workstation.get("prompt_text") if workstation.get("prompt_text") != null else tr("ui.action_panel.default.action")
	var ws_name: String = workstation.get("display_name") if workstation.get("display_name") != null else tr("ui.action_panel.title")
	_hint.text = tr("ui.action_panel.hint.press_e_format") % [prompt_text, ws_name]
	_hint.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_E and _active_workstation != null and not _root.visible:
		_handle_e_press(_active_workstation)
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and _root.visible:
		close()
		get_viewport().set_input_as_handled()


# 按 E：根据 workstation 的 interaction_mode 走 ActionPanel 或直接 RPC。
func _handle_e_press(workstation: Node) -> void:
	# Group 权限校验：本地用 player.groups（owner-private 同步过来的快照）。
	# server 端在 RPC handler 还会再校验一遍（防 client 篡改 / 同步 lag）。
	if _player != null and workstation.has_method("can_be_used_by") and not workstation.can_be_used_by(_player):
		var ws_name := String(workstation.display_name) if workstation.get("display_name") != null else String(workstation.workstation_id)
		EventBus.notification_posted.emit(tr("ui.action_panel.notification.no_permission_format") % [ws_name, String(workstation.owner_group)], "warn")
		return
	var ws_def: Workstation = Workstations.by_id(String(workstation.workstation_id))
	var mode := "action_panel" if ws_def == null else String(ws_def.interaction_mode)
	if mode == "direct":
		if _player == null:
			EventBus.notification_posted.emit(tr("ui.action_panel.notification.character_not_ready"), "warn")
			return
		_player.request_workstation_direct.rpc_id(1, String(workstation.workstation_id))
		return
	open(workstation)


func open(workstation: Node) -> void:
	_open_workstation = workstation
	_title.text = String(workstation.display_name)
	_build_slots()
	_populate_action_buttons(String(workstation.workstation_id))
	_refresh_staged_view()
	_root.visible = true
	_hint.visible = false
	# 持续 polling staged_items 变化（server 推回 → MultiplayerSynchronizer 改 _player.staged_items）
	set_process(true)


func close() -> void:
	# 关 panel 时如果没有进行中的 craft，server 把 staged 退回背包；craft 中则留着等 commit
	if _player != null and not _is_craft_in_progress():
		_player.request_clear_staging.rpc_id(1)
	_root.visible = false
	_open_workstation = null
	for s in _slots:
		s.display_empty()
	if _active_workstation != null:
		_show_hint(_active_workstation)
	set_process(_progress_box != null and _progress_box.visible)


func _is_craft_in_progress() -> bool:
	return _progress_box != null and _progress_box.visible and _progress_is_craft


# 从 Workstation Resource 填动作按钮；有 sub_options 的 verb 展开成可直接执行的按钮。
func _populate_action_buttons(ws_id: String) -> void:
	_clear_action_buttons()
	var ws_def: Workstation = Workstations.by_id(ws_id)
	if ws_def == null:
		push_warning("ActionPanel: 找不到 workstation '%s'" % ws_id)
		_action_buttons_box.visible = false
		return
	var plain_row: HBoxContainer = null
	for v_id in ws_def.verbs:
		var v_def: Verb = Verbs.by_id(v_id)
		var verb_label: String = v_def.display_name if v_def != null and not v_def.display_name.is_empty() else v_id
		if v_def != null and not v_def.sub_options.is_empty():
			plain_row = null
			_add_action_heading(verb_label)
			var sub_grid := _add_action_grid()
			for sub_id in v_def.sub_options.keys():
				var sub_label := v_def.sub_option_label(String(sub_id))
				_add_action_button(sub_grid, v_id, String(sub_id), sub_label if not sub_label.is_empty() else String(sub_id))
		else:
			if plain_row == null:
				plain_row = _add_action_row()
			_add_action_button(plain_row, v_id, "", verb_label)
	_action_buttons_box.visible = not _action_buttons.is_empty()
	_set_action_buttons_disabled(_is_craft_in_progress())


func _clear_action_buttons() -> void:
	for c in _action_buttons_box.get_children():
		_action_buttons_box.remove_child(c)
		c.queue_free()
	_action_buttons.clear()


func _add_action_heading(label_text: String) -> void:
	var label := Label.new()
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.78, 0.78, 0.88))
	_action_buttons_box.add_child(label)


func _add_action_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_action_buttons_box.add_child(grid)
	return grid


func _add_action_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_theme_constant_override("separation", 8)
	_action_buttons_box.add_child(row)
	return row


func _add_action_button(parent: Node, verb_id: String, sub_id: String, label: String) -> void:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(132, 34)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.tooltip_text = verb_id if sub_id.is_empty() else "%s (%s)" % [verb_id, sub_id]
	btn.pressed.connect(_on_action_button_pressed.bind(verb_id, sub_id))
	parent.add_child(btn)
	_action_buttons.append(btn)


func _build_slots() -> void:
	for c in _grid.get_children():
		c.queue_free()
	_slots.clear()
	# 槽数取自 workstation Resource（mill=1，其余默认 5）。columns 跟着收，
	# 1 槽时不要排 4 列空位
	var count := SLOT_COUNT_FALLBACK
	if _open_workstation != null:
		var ws_def: Workstation = Workstations.by_id(String(_open_workstation.workstation_id))
		if ws_def != null:
			count = max(1, ws_def.slot_count)
	_grid.columns = min(SLOT_COL_LIMIT, count)
	for i in count:
		var slot = ACTION_SLOT.new()
		slot.configure(i, tr("ui.action_panel.slot.label_format") % (i + 1))
		slot.staging_request.connect(_on_staging_request)
		slot.unstaging_request.connect(_on_unstaging_request)
		_grid.add_child(slot)
		_slots.append(slot)


func _on_staging_request(inv_slot: int, qty: int) -> void:
	if _player == null:
		return
	_player.request_stage_to_workstation.rpc_id(1, inv_slot, qty)


func _on_unstaging_request(staged_idx: int, qty: int) -> void:
	if _player == null:
		return
	_player.request_unstage_from_workstation.rpc_id(1, staged_idx, qty)


# 把 _player.staged_items 同步到 6 个 ActionSlot 显示
func _refresh_staged_view() -> void:
	if _player == null:
		return
	var staged: Array = _player.get("staged_items") if _player.get("staged_items") != null else []
	for i in _slots.size():
		if i < staged.size():
			_slots[i].display_staged(staged[i])
		else:
			_slots[i].display_empty()


func _on_action_button_pressed(verb_id: String, sub_id: String) -> void:
	if _open_workstation == null:
		return
	if _player == null:
		EventBus.notification_posted.emit(tr("ui.action_panel.notification.character_not_ready"), "warn")
		return
	if verb_id.is_empty():
		EventBus.notification_posted.emit(tr("ui.action_panel.notification.no_verb"), "warn")
		return
	_player.request_craft.rpc_id(1, verb_id,
		String(_open_workstation.workstation_id), sub_id)


func _on_craft_started(reaction_name: String, duration_sec: float) -> void:
	_start_progress(reaction_name, duration_sec, true)


func _on_player_action_started(action_name: String, duration_sec: float) -> void:
	_start_progress(action_name, duration_sec, false)


func _start_progress(action_name: String, duration_sec: float, is_craft: bool) -> void:
	_progress_is_craft = is_craft
	_progress_label.text = tr("ui.action_panel.progress.format") % action_name
	_progress_bar.value = 0.0
	_progress_box.visible = true
	if is_craft:
		_set_action_buttons_disabled(true)
	_craft_started_at_game_seconds = GameClock.game_seconds
	_craft_duration_game_seconds = max(0.001, duration_sec)
	set_process(true)


func _on_craft_completed(_message: String) -> void:
	if _progress_is_craft:
		_finish_progress_ui()


func _on_craft_cancelled(_reason: String) -> void:
	if _progress_is_craft:
		_finish_progress_ui()


func _on_player_action_completed(_message: String) -> void:
	if not _progress_is_craft:
		_finish_progress_ui()


func _on_player_action_cancelled(_reason: String) -> void:
	if not _progress_is_craft:
		_finish_progress_ui()


func _finish_progress_ui() -> void:
	_progress_box.visible = false
	_progress_bar.value = 0.0
	_progress_label.text = ""
	if _progress_is_craft:
		_set_action_buttons_disabled(false)
	_progress_is_craft = false
	if _root.visible:
		_refresh_staged_view()
		set_process(true)
	else:
		set_process(false)


func _set_action_buttons_disabled(disabled: bool) -> void:
	for btn in _action_buttons:
		btn.disabled = disabled


func _process(_delta: float) -> void:
	# Panel 打开期间持续 polling：（1）刷新 staged 显示（server 推回的状态变化）
	# （2）progress bar 插值。set_process(false) 在 close() 里关。
	if _root.visible:
		_refresh_staged_view()
	if _progress_box.visible:
		var elapsed: float = GameClock.game_seconds - _craft_started_at_game_seconds
		var p: float = clampf(elapsed / _craft_duration_game_seconds, 0.0, 1.0)
		_progress_bar.value = p


# 注入到 Root 下，跟 Panel 同级，独立于 _root.visible（craft 期间 panel 可能已关）
func _inject_walk_cancel_dialog() -> void:
	_walk_cancel_dialog = ConfirmationDialog.new()
	_walk_cancel_dialog.title = tr("ui.action_panel.dialog.crafting_title")
	_walk_cancel_dialog.dialog_text = tr("ui.action_panel.dialog.crafting_text")
	_walk_cancel_dialog.ok_button_text = tr("ui.action_panel.dialog.confirm_cancel")
	_walk_cancel_dialog.cancel_button_text = tr("ui.action_panel.dialog.continue_crafting")
	_walk_cancel_dialog.confirmed.connect(_on_walk_cancel_confirmed)
	add_child(_walk_cancel_dialog)


func _on_walk_block_requested(target_pos: Vector3) -> void:
	_pending_walk_target = target_pos
	_walk_cancel_dialog.popup_centered()


func _on_walk_cancel_confirmed() -> void:
	if _player == null:
		return
	_player.confirm_cancel_craft_and_move.rpc_id(1, _pending_walk_target)
