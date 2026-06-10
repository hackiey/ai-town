class_name WaterDrawPanel
extends CanvasLayer

# 玩家专用打水面板（client only）。InteractionController 在水井（infinite water source）上按 E 时
# 调 open(well)。列出背包里可装水的液体容器，每行：容器槽 + 数字框（默认=装满所需量）+ [取水]。
# 点取水 → player.request_draw_water RPC（服务端权威，复用 WaterDrawRunner）。背包变化靠 _process 跟随刷新。
#
# 不复用 NPC 的 take 工具——玩家走独立 RPC + 本面板。见 plan: 玩家侧水井打水 UI。

const WATER := "water"

var _player: Node = null
var _well: Node = null          # 当前打开的水井（ContainerNode，infinite source）
var _well_id: String = ""
var _active_well: Node = null   # proximity 跟踪：走出范围自动关

var _root: Control
var _rows_box: VBoxContainer
var _title: Label
var _empty_label: Label
var _last_signature: String = ""


func _ready() -> void:
	layer = 12   # 高于 ContainerPanel(10)/ActionPanel(11)，避免被其它面板/背板压住
	_build_ui()
	_root.visible = false
	EventBus.workstation_proximity_changed.connect(_on_proximity_changed)
	set_process(false)


func set_player(node: Node) -> void:
	_player = node


func is_open() -> bool:
	return _root != null and _root.visible


# InteractionController 在水井上按 E 时调。
func open(well_node: Node) -> void:
	if well_node == null or not well_node.has_method("is_infinite_source") or not well_node.is_infinite_source():
		return
	_well = well_node
	_well_id = String(well_node.effective_container_id()) if well_node.has_method("effective_container_id") else String(well_node.get("workstation_id"))
	_title.text = tr("ui.water_draw.title_format") % String(well_node.display_name)
	_last_signature = ""
	_rebuild_rows()
	_root.visible = true
	set_process(true)


func close() -> void:
	_root.visible = false
	_well = null
	_well_id = ""
	set_process(false)


func _on_proximity_changed(ws: Node, entered: bool) -> void:
	if ws == null or not ws.has_method("is_infinite_source") or not ws.is_infinite_source():
		return
	if entered:
		_active_well = ws
	else:
		if ws == _active_well:
			_active_well = null
		if ws == _well and _root.visible:
			close()


func _unhandled_input(event: InputEvent) -> void:
	if not _root.visible:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


func _process(_dt: float) -> void:
	if not _root.visible:
		return
	if _player == null or _well == null or not is_instance_valid(_well):
		close()
		return
	# 背包/液体量变化 → 重建行（签名防止每帧重建，避免清掉玩家正在编辑的数字框）。
	var sig := _signature()
	if sig != _last_signature:
		_rebuild_rows()


# ─ 行构建 ──────────────────────────────────────────────────────────────

# 可装水容器的签名：slot_index + item + 当前水量。仅这些变了才重建。
func _signature() -> String:
	if _player == null:
		return ""
	var parts: Array[String] = []
	var inv: Array = _player.inventory
	for idx in inv.size():
		var view := InventorySlotData.of(inv[idx])
		if not view.has_tag("liquid_container"):
			continue
		var cont := view.as_container()
		if cont == null:
			continue
		if not (cont.is_empty() or cont.content_id() == WATER):
			continue
		if cont.capacity() - cont.amount() <= 0.0:
			continue
		parts.append("%d:%s:%.1f/%.1f" % [idx, view.id(), cont.amount(), cont.capacity()])
	return "|".join(parts)


func _rebuild_rows() -> void:
	_last_signature = _signature()
	for c in _rows_box.get_children():
		c.queue_free()
	var inv: Array = _player.inventory if _player != null else []
	var any := false
	for idx in inv.size():
		var slot: Dictionary = inv[idx]
		var view := InventorySlotData.of(slot)
		if not view.has_tag("liquid_container"):
			continue
		var cont := view.as_container()
		if cont == null:
			continue
		if not (cont.is_empty() or cont.content_id() == WATER):
			continue
		var room := cont.capacity() - cont.amount()
		if room <= 0.0:
			continue
		_rows_box.add_child(_build_row(idx, slot, view, cont, room))
		any = true
	_empty_label.visible = not any


func _build_row(idx: int, slot: Dictionary, view: InventorySlotData, cont: ContainerAspect, room: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var icon := InventorySlot.new()
	icon.custom_minimum_size = Vector2(44, 44)
	row.add_child(icon)
	icon.set_slot(idx, slot)

	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(180, 0)
	name_label.text = tr("ui.water_draw.row_format") % [view.display_name(), int(round(cont.amount())), int(round(cont.capacity()))]
	row.add_child(name_label)

	var spin := SpinBox.new()
	spin.min_value = 1.0
	spin.max_value = room
	spin.step = 1.0
	spin.value = room   # 默认装满所需量
	spin.custom_minimum_size = Vector2(90, 0)
	row.add_child(spin)

	var btn := Button.new()
	btn.text = tr("ui.water_draw.draw_button")
	btn.pressed.connect(func() -> void: _draw(idx, int(spin.value)))
	row.add_child(btn)
	return row


func _draw(backpack_slot_index: int, amount: int) -> void:
	if _player == null or _well_id.is_empty() or amount <= 0:
		return
	if not _player.has_method("request_draw_water"):
		return
	_player.request_draw_water.rpc_id(1, _well_id, backpack_slot_index, float(amount))


# ─ UI 搭建 ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -240.0
	panel.offset_top = -180.0
	panel.offset_right = 240.0
	panel.offset_bottom = 180.0
	_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(440, 240)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 6)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)

	_empty_label = Label.new()
	_empty_label.text = tr("ui.water_draw.empty")
	_empty_label.visible = false
	vbox.add_child(_empty_label)

	var close_btn := Button.new()
	close_btn.text = tr("ui.water_draw.close")
	close_btn.pressed.connect(close)
	vbox.add_child(close_btn)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.05, 0.95)
	style.border_color = Color(0.55, 0.74, 0.95, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(4)
	return style
