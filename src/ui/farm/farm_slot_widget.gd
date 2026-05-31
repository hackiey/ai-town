class_name FarmSlotWidget
extends PanelContainer

# 农场面板里的单格行（list 风格）：
# - 左：CheckBox（选中后批量按钮才作用于本格）
# - 中：状态文本（"[i] 空地" / "[i] 番茄·开花·💧60% 🐛"）
# - 右：种植物拖入区（Control，接受 InventorySlot 的 drag_data → emit seed_dropped）
# - 最右：当前已规划动作的徽标（"→ 种 番茄种子" / "→ 种 小麦" / "→ 除虫" / "→ 收获" / "→ 铲除"）
#
# Plant 仅靠拖入可种植物触发；其他动作（pest/harvest/uproot）由 FarmPanel 顶部 toolbar
# 在选中行上批量打标。Plant 与其它动作互斥，互相覆盖。

signal selection_changed(slot_index: int, selected: bool)
signal seed_dropped(slot_index: int, seed_id: String)
signal plan_cleared(slot_index: int)

const ROW_MIN_HEIGHT := 44
const DROP_ZONE_SIZE := Vector2(96, 36)

var slot_index: int = -1
var _planned: String = ""    # "" | "plant" | "pest" | "harvest" | "uproot"
var _planned_seed_id: String = ""
var _occupied: bool = false
var _has_pest: bool = false
var _ripe: bool = false

var _check: CheckBox
var _state_label: Label
var _drop_zone: Control
var _drop_bg: ColorRect
var _drop_label: Label
var _planned_label: Label


func _init() -> void:
	custom_minimum_size = Vector2(0, ROW_MIN_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	margin.add_child(hbox)

	_check = CheckBox.new()
	_check.toggled.connect(_on_check_toggled)
	hbox.add_child(_check)

	_state_label = Label.new()
	_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_label.add_theme_font_size_override("font_size", 12)
	_state_label.text = "—"
	_state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(_state_label)

	_drop_zone = _build_drop_zone()
	hbox.add_child(_drop_zone)

	_planned_label = Label.new()
	_planned_label.custom_minimum_size = Vector2(140, 0)
	_planned_label.add_theme_font_size_override("font_size", 12)
	_planned_label.add_theme_color_override("font_color", Color(0.55, 0.95, 0.6))
	_planned_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_planned_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(_planned_label)


func _build_drop_zone() -> Control:
	var zone := Control.new()
	zone.custom_minimum_size = DROP_ZONE_SIZE
	zone.mouse_filter = Control.MOUSE_FILTER_STOP
	zone.set_drag_forwarding(Callable(), Callable(self, "_drop_zone_can_drop"), Callable(self, "_drop_zone_drop"))
	zone.gui_input.connect(_on_drop_zone_input)
	_drop_bg = ColorRect.new()
	_drop_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drop_bg.color = Color(0.16, 0.20, 0.18, 0.6)
	_drop_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	zone.add_child(_drop_bg)
	_drop_label = Label.new()
	_drop_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_drop_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_drop_label.add_theme_font_size_override("font_size", 11)
	_drop_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.78))
	_drop_label.text = tr("ui.farm.slot.drop_plantable")
	_drop_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	zone.add_child(_drop_label)
	zone.tooltip_text = tr("ui.farm.slot.drop_plantable_tooltip")
	return zone


func _drop_zone_can_drop(_pos: Vector2, data: Variant) -> bool:
	if _occupied:
		return false
	if not (data is Dictionary):
		return false
	var d := data as Dictionary
	if not d.has("from_slot"):
		return false
	var item_id := String(d.get("item_id", ""))
	if item_id.is_empty():
		return false
	var item: Item = Items.by_id(item_id)
	return item != null and item.tags.has("seed") and not item.crop_variety_id.is_empty()


func _drop_zone_drop(_pos: Vector2, data: Variant) -> void:
	var item_id := String((data as Dictionary).get("item_id", ""))
	if item_id.is_empty():
		return
	seed_dropped.emit(slot_index, item_id)


func _on_drop_zone_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if _planned == "plant":
		plan_cleared.emit(slot_index)
		get_viewport().set_input_as_handled()


func _on_check_toggled(pressed: bool) -> void:
	selection_changed.emit(slot_index, pressed)


func set_state(slot_state: Dictionary) -> void:
	# slot_state 来自 FarmGroup.describe_for_context() 的某一项
	var idx := int(slot_state.get("index", -1))
	slot_index = idx
	_occupied = bool(slot_state.get("occupied", false))
	_has_pest = bool(slot_state.get("has_pest", false))
	_ripe = bool(slot_state.get("ripe", false))
	if not _occupied:
		_state_label.text = tr("ui.farm.slot.empty_format") % idx
	else:
		var disp := str(slot_state.get("display_name", slot_state.get("variety", "?")))
		var stage := str(slot_state.get("stage_display", slot_state.get("stage", "?")))
		var moisture := float(slot_state.get("moisture", 0.0))
		var moisture_pct := int(round(moisture * 100.0))
		var dry_mark := "  缺水" if bool(slot_state.get("needs_water", false)) else ""
		var wet_mark := "  过湿" if bool(slot_state.get("too_wet", false)) else ""
		var pest_mark := "  🐛" if _has_pest else ""
		var ripe_mark := "  🌾" if _ripe else ""
		_state_label.text = "[%d] %s · %s · 💧%d%%%s%s%s%s" % [
			idx, disp, stage, moisture_pct, dry_mark, wet_mark, pest_mark, ripe_mark,
		]
		_refresh_drop_zone_visual()


# 规划状态由 FarmPanel 维护，刷新视觉时回调过来
func set_planned(planned: String, seed_id: String = "") -> void:
	_planned = planned
	_planned_seed_id = seed_id
	match planned:
		"plant":
			var item: Item = Items.by_id(seed_id)
			var item_name: String = item.display_name if item != null and not item.display_name.is_empty() else seed_id
			_planned_label.text = tr("ui.farm.slot.plan_plant_format") % item_name
		"pest":
			_planned_label.text = tr("ui.farm.slot.plan_pest")
		"harvest":
			_planned_label.text = tr("ui.farm.slot.plan_harvest")
		"uproot":
			_planned_label.text = tr("ui.farm.slot.plan_uproot")
		_:
			_planned_label.text = ""
	_refresh_drop_zone_visual()


func _refresh_drop_zone_visual() -> void:
	if _drop_zone == null:
		return
	if _planned == "plant":
		var item: Item = Items.by_id(_planned_seed_id)
		var item_name: String = item.display_name if item != null and not item.display_name.is_empty() else _planned_seed_id
		_drop_label.text = item_name
		_drop_label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
		_drop_bg.color = Color(0.16, 0.32, 0.18, 0.85)
		_drop_zone.modulate = Color(1, 1, 1, 1)
	elif _occupied:
		_drop_label.text = tr("ui.farm.slot.occupied")
		_drop_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
		_drop_bg.color = Color(0.10, 0.10, 0.12, 0.5)
		_drop_zone.modulate = Color(1, 1, 1, 0.7)
	else:
		_drop_label.text = tr("ui.farm.slot.drop_plantable")
		_drop_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.78))
		_drop_bg.color = Color(0.16, 0.20, 0.18, 0.6)
		_drop_zone.modulate = Color(1, 1, 1, 1)


func set_selected(selected: bool) -> void:
	if _check.button_pressed != selected:
		_check.set_pressed_no_signal(selected)


func is_selected() -> bool:
	return _check.button_pressed


func is_occupied() -> bool:
	return _occupied


func has_pest() -> bool:
	return _has_pest


func is_ripe() -> bool:
	return _ripe
