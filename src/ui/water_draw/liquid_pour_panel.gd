class_name LiquidPourPanel
extends CanvasLayer

# 玩家专用"倒液体"面板（client only）。在容器面板/背包里右键一个装着液体的容器选"倒出液体…"时，
# ContainerPanel 调 open(source_ref)。列出背包里能接收的液体容器（空的或同种液体、还有空间），
# 每行：容器 + 数字框（默认=把目标倒满所需）+ [倒入]。点 → player.request_pour_liquid RPC。
#
# 源(source)可来自背包或仓库节点（container_id=""=背包）；目标只列背包容器。
# 复用 LiquidOps.transfer_between_slots（服务端权威），与 NPC 同一原语。

var _player: Node = null

# 源端缓存（open 时定，倒出后乐观递减 _src_amount）
var _src_cid: String = ""        # ""=背包；否则容器节点 id
var _src_slot: int = -1
var _src_content: String = ""
var _src_amount: float = 0.0
var _src_label: String = ""

var _root: Control
var _rows_box: VBoxContainer
var _title: Label
var _empty_label: Label
var _last_signature: String = ""


func _ready() -> void:
	layer = 12   # 必须高于 ContainerPanel(10)/ActionPanel(11)——倒液体面板叠在打开的容器面板之上
	_build_ui()
	_root.visible = false
	set_process(false)


func set_player(node: Node) -> void:
	_player = node


func is_open() -> bool:
	return _root != null and _root.visible


# source_ref: {container_id, slot_index, content, quality, amount, label}
func open(source_ref: Dictionary) -> void:
	_src_cid = str(source_ref.get("container_id", ""))
	_src_slot = int(source_ref.get("slot_index", -1))
	_src_content = str(source_ref.get("content", ""))
	_src_amount = float(source_ref.get("amount", 0.0))
	_src_label = str(source_ref.get("label", ""))
	if _src_slot < 0 or _src_amount <= 0.0 or _src_content.is_empty():
		return
	_title.text = tr("ui.liquid_pour.title_format") % [_src_label, _content_name(_src_content)]
	_last_signature = ""
	_rebuild_rows()
	_root.visible = true
	set_process(true)


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
	if not _root.visible:
		return
	if _player == null or _src_amount <= 0.0:
		_rebuild_rows()  # 源倒空 → 显示空提示
		return
	var sig := _signature()
	if sig != _last_signature:
		_rebuild_rows()


# 候选目标 = 背包里可接收的液体容器（空 / 同 content、有空间），排除源（若源也在背包同槽）。
func _eligible_targets() -> Array:
	var out: Array = []
	if _player == null:
		return out
	var inv: Array = _player.inventory
	for idx in inv.size():
		if _src_cid == "" and idx == _src_slot:
			continue
		var view := InventorySlotData.of(inv[idx])
		if not view.has_tag("liquid_container"):
			continue
		var cont := view.as_container()
		if cont == null:
			continue
		if not (cont.is_empty() or cont.content_id() == _src_content):
			continue
		if cont.capacity() - cont.amount() <= 0.0:
			continue
		out.append(idx)
	return out


func _signature() -> String:
	var parts: Array[String] = ["src:%.1f" % _src_amount]
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
		var room := cont.capacity() - cont.amount()
		var pourable := minf(room, _src_amount)
		if pourable <= 0.0:
			continue
		_rows_box.add_child(_build_row(idx, slot, view, cont, pourable))
	_empty_label.visible = targets.is_empty() or _src_amount <= 0.0


func _build_row(idx: int, slot: Dictionary, view: InventorySlotData, cont: ContainerAspect, pourable: float) -> HBoxContainer:
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
	spin.value = pourable   # 默认把目标倒满所需（受源剩余限制）
	spin.custom_minimum_size = Vector2(90, 0)
	row.add_child(spin)

	var btn := Button.new()
	btn.text = tr("ui.liquid_pour.pour_button")
	btn.pressed.connect(func() -> void: _pour(idx, int(spin.value)))
	row.add_child(btn)
	return row


func _pour(dest_backpack_slot: int, amount: int) -> void:
	if _player == null or amount <= 0 or _src_slot < 0:
		return
	if not _player.has_method("request_pour_liquid"):
		return
	# 目标恒在背包（container_id=""）；源可能是背包或仓库节点。
	_player.request_pour_liquid.rpc_id(1, _src_cid, _src_slot, "", dest_backpack_slot, float(amount))
	# 乐观递减源剩余，立即重建（服务端最终权威，下一帧 inventory 同步会校正目标显示）。
	_src_amount = maxf(0.0, _src_amount - float(amount))
	_last_signature = ""


func _content_name(content: String) -> String:
	var key := "item.%s.name" % content
	var n := tr(key)
	return n if n != key else content


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

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(440, 240)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 6)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)

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
