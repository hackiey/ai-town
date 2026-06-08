class_name SplitPanel
extends CanvasLayer

# 统一"分离/转移量"面板（client only）：所有物品共用。两种模式：
#  - targets（need_target=true，液体）：列出背包里能接收的液体容器，每行 容器+数字框(升)+[确认]。
#    用于：仓库桶→倒液、灶台液体→取出到指定容器。on_confirm(target_backpack_slot, amount)。
#  - single（need_target=false，离散/按量）：单个数字框(份/升) + [确认]。
#    用于：背包物→放入灶台/存入仓库、灶台/仓库→取出 N。on_confirm(amount)。
#
# 面板与具体 RPC 解耦——caller 用 spec.on_confirm 注入"确认后做什么"。单位仅影响文案
# （liter=升 / count=份；gram=克 预留）。源量由 caller 在 open 时给定 spec.max，确认后乐观递减，
# 服务端权威，下一帧 inventory 同步校正显示。

var _player: Node = null

var _mode: String = ""            # "targets" | "single"
var _unit: String = "count"       # "liter" | "count" | "gram"
var _content: String = ""         # 液体 id（targets 模式过滤/显示用）
var _quality: int = 100
var _remaining: int = 0           # 还可转移的量（确认后乐观递减）
var _exclude_slot: int = -1       # targets 模式排除的背包槽（源本身在背包时）
var _on_confirm: Callable = Callable()

var _root: Control
var _title: Label
var _rows_box: VBoxContainer
var _scroll: ScrollContainer
var _single_row: HBoxContainer
var _single_spin: SpinBox
var _single_label: Label
var _empty_label: Label
var _last_signature: String = ""


func _ready() -> void:
	layer = 12   # 高于 ContainerPanel(10)/ActionPanel(11)，叠在打开的面板之上
	_build_ui()
	_root.visible = false
	set_process(false)


func set_player(node: Node) -> void:
	_player = node


func is_open() -> bool:
	return _root != null and _root.visible


# spec: { unit, need_target, title, content, quality, max, exclude_slot, on_confirm }
func open(spec: Dictionary) -> void:
	_unit = str(spec.get("unit", "count"))
	_content = str(spec.get("content", ""))
	_quality = int(spec.get("quality", 100))
	_remaining = int(spec.get("max", 0))
	_exclude_slot = int(spec.get("exclude_slot", -1))
	_on_confirm = spec.get("on_confirm", Callable())
	_mode = "targets" if bool(spec.get("need_target", false)) else "single"
	if _remaining <= 0 or not _on_confirm.is_valid():
		return
	_title.text = str(spec.get("title", tr("ui.split.title")))
	_last_signature = ""
	if _mode == "targets":
		_scroll.visible = true
		_single_row.visible = false
		_rebuild_rows()
	else:
		_scroll.visible = false
		_single_row.visible = true
		_empty_label.visible = false
		_single_label.text = tr("ui.split.amount_label") % _unit_name()
		_single_spin.min_value = 1.0
		_single_spin.max_value = _remaining
		_single_spin.value = _remaining
	_root.visible = true
	set_process(_mode == "targets")


func close() -> void:
	_root.visible = false
	set_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _root.visible:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


func _process(_dt: float) -> void:
	if not _root.visible or _mode != "targets":
		return
	if _player == null or _remaining <= 0:
		_rebuild_rows()
		return
	var sig := _signature()
	if sig != _last_signature:
		_rebuild_rows()


# 候选目标 = 背包里可接收的液体容器（空 / 同 content、有空间），排除源槽。
func _eligible_targets() -> Array:
	var out: Array = []
	if _player == null:
		return out
	var inv: Array = _player.inventory
	for idx in inv.size():
		if idx == _exclude_slot:
			continue
		var view := InventorySlotData.of(inv[idx])
		if not view.has_tag("liquid_container"):
			continue
		var cont := view.as_container()
		if cont == null:
			continue
		if not (cont.is_empty() or cont.content_id() == _content):
			continue
		if cont.capacity() - cont.amount() <= 0.0:
			continue
		out.append(idx)
	return out


func _signature() -> String:
	var parts: Array[String] = ["src:%d" % _remaining]
	for idx in _eligible_targets():
		var cont := InventorySlotData.of(_player.inventory[idx]).as_container()
		parts.append("%d:%.1f/%.1f" % [idx, cont.amount(), cont.capacity()])
	return "|".join(parts)


func _rebuild_rows() -> void:
	_last_signature = _signature()
	for c in _rows_box.get_children():
		c.queue_free()
	var targets := _eligible_targets()
	for idx in targets:
		var slot: Dictionary = _player.inventory[idx]
		var view := InventorySlotData.of(slot)
		var cont := view.as_container()
		var room := int(floor(cont.capacity() - cont.amount()))
		var pourable := mini(room, _remaining)
		if pourable <= 0:
			continue
		_rows_box.add_child(_build_row(idx, slot, view, cont, pourable))
	_empty_label.visible = targets.is_empty() or _remaining <= 0


func _build_row(idx: int, slot: Dictionary, view: InventorySlotData, cont: ContainerAspect, pourable: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

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
	spin.max_value = pourable
	spin.step = 1.0
	spin.value = pourable
	spin.custom_minimum_size = Vector2(90, 0)
	row.add_child(spin)

	var btn := Button.new()
	btn.text = tr("ui.split.confirm")
	btn.pressed.connect(func() -> void: _confirm_target(idx, int(spin.value)))
	row.add_child(btn)
	return row


func _confirm_target(target_slot: int, amount: int) -> void:
	if amount <= 0 or not _on_confirm.is_valid():
		return
	_on_confirm.call(target_slot, amount)
	_remaining = maxi(0, _remaining - amount)
	_last_signature = ""
	if _remaining <= 0:
		close()


func _confirm_single() -> void:
	if not _on_confirm.is_valid():
		return
	var amount := int(_single_spin.value)
	if amount <= 0:
		return
	_on_confirm.call(amount)
	close()


func _unit_name() -> String:
	match _unit:
		"liter": return tr("ui.split.unit.liter")
		"gram": return tr("ui.split.unit.gram")
		"centi": return tr("ui.split.unit.centi")
		_: return tr("ui.split.unit.count")


# ─ UI ─────────────────────────────────────────────────────────────────

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

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(440, 240)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 6)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows_box)

	# single 模式：单数字框 + 确认
	_single_row = HBoxContainer.new()
	_single_row.add_theme_constant_override("separation", 10)
	_single_row.visible = false
	_single_label = Label.new()
	_single_row.add_child(_single_label)
	_single_spin = SpinBox.new()
	_single_spin.step = 1.0
	_single_spin.custom_minimum_size = Vector2(100, 0)
	_single_row.add_child(_single_spin)
	var single_btn := Button.new()
	single_btn.text = tr("ui.split.confirm")
	single_btn.pressed.connect(_confirm_single)
	_single_row.add_child(single_btn)
	vbox.add_child(_single_row)

	_empty_label = Label.new()
	_empty_label.text = tr("ui.liquid_pour.empty")
	_empty_label.visible = false
	vbox.add_child(_empty_label)

	var close_btn := Button.new()
	close_btn.text = tr("ui.water_draw.close")
	close_btn.pressed.connect(close)
	vbox.add_child(close_btn)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.05, 0.95)
	style.border_color = Color(0.85, 0.6, 0.38, 0.85)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(4)
	return style
