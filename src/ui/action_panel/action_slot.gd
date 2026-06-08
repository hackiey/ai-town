class_name ActionSlot
extends Control

# Workstation staging slot（client 视图，server 持权威）：
# - 显示 server 推过来的 staged_items[slot_index] 内容
# - 接受从 InventorySlot 拖来的 drag_data → 发 staging_request 信号给 ActionPanel
# - 左键点已 staged 的 slot → 发 unstaging_request 信号
# 所有真实搬运由 server 处理；client 只显示 + 提交意图。
#
# 设计：docs/architecture/crafting-interaction.md §2.2

signal staging_request(inv_slot: int, amount: int)   # 从背包拖来 → 通知 ActionPanel 发 RPC（amount<=0=全量）
signal unstaging_request(staged_idx: int, qty: int)  # 左键点 → 退还 1 件（原路）
signal split_request(staged_idx: int)                # 右键点 → 开分离面板（液体选目标/份数）

const SIZE := Vector2(96, 96)
const LABEL_HEIGHT := 18
const BG_INSET := 6  # 色块离槽位边缘的内边距

var slot_index: int = -1
var label_text: String = ""

# Server 推过来的 instance dict（含 quantity）；空 stack qty<=0 表示槽空
var _staged_data: Dictionary = {}

var _frame: Panel
var _label: Label
var _bg: ColorRect
var _icon: TextureRect
var _name_overlay: Label
var _qty_label: Label  # 右下角显示 stack qty


func _init() -> void:
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP

	_frame = Panel.new()
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)

	_label = Label.new()
	_label.position = Vector2(0, 2)
	_label.size = Vector2(SIZE.x, LABEL_HEIGHT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 11)
	_label.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)

	var bg_pos := Vector2(BG_INSET, LABEL_HEIGHT + 4)
	var bg_size := Vector2(SIZE.x - BG_INSET * 2, SIZE.y - LABEL_HEIGHT - BG_INSET - 4)

	_bg = ColorRect.new()
	_bg.position = bg_pos
	_bg.size = bg_size
	_bg.color = _empty_color()
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_icon = TextureRect.new()
	_icon.position = bg_pos
	_icon.size = bg_size
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.visible = false
	add_child(_icon)

	_name_overlay = Label.new()
	_name_overlay.position = bg_pos
	_name_overlay.size = bg_size
	_name_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_overlay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_overlay.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_overlay.add_theme_font_size_override("font_size", 13)
	_name_overlay.add_theme_color_override("font_color", Color(1, 1, 1))
	_name_overlay.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_name_overlay.add_theme_constant_override("outline_size", 4)
	_name_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_overlay.visible = false
	add_child(_name_overlay)

	_qty_label = Label.new()
	_qty_label.position = Vector2(SIZE.x - 28, SIZE.y - 22)
	_qty_label.size = Vector2(24, 18)
	_qty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_qty_label.add_theme_font_size_override("font_size", 14)
	_qty_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_qty_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_qty_label.add_theme_constant_override("outline_size", 3)
	_qty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_qty_label.visible = false
	add_child(_qty_label)


func configure(index: int, label: String) -> void:
	slot_index = index
	label_text = label
	_label.text = label
	display_empty()


func display_empty() -> void:
	_staged_data = {}
	_icon.texture = null
	_icon.visible = false
	_name_overlay.visible = false
	_name_overlay.text = ""
	_qty_label.visible = false
	_bg.color = _empty_color()
	tooltip_text = tr("ui.action_slot.tooltip.empty_format") % label_text


# 显示 server 推过来的 staged_items[slot_index]。空 dict 或 qty<=0 → empty
func display_staged(slot_data: Dictionary) -> void:
	var view := InventorySlotData.of(slot_data)
	if view.quantity() <= 0:
		display_empty()
		return
	_staged_data = slot_data.duplicate(true)
	var item := view.template()
	var name_for_tip := view.display_name()
	if item != null and item.icon != null:
		_icon.texture = item.icon
		_icon.modulate = item.tint
		_icon.visible = true
		_name_overlay.visible = false
		_bg.color = Color(0.06, 0.06, 0.08, 0.6)
	else:
		_icon.visible = false
		_icon.texture = null
		_bg.color = view.display_color(_color_for(view.id()))
		_name_overlay.text = name_for_tip
		_name_overlay.visible = true
	_qty_label.text = "×%d" % view.quantity()
	_qty_label.visible = view.quantity() > 1
	tooltip_text = _build_tooltip(view, item, name_for_tip)


func _build_tooltip(view: InventorySlotData, item: Item, name_for_tip: String) -> String:
	var lines: Array = []
	lines.append(tr("ui.action_slot.tooltip.label_format") % label_text)
	var kind := item.kind if item != null else ""
	if not kind.is_empty():
		lines.append("[%s] %s" % [kind, name_for_tip])
	else:
		lines.append(name_for_tip)
	lines.append(tr("ui.action_slot.tooltip.quantity_format") % view.quantity())
	var q := view.quality()
	if q > 0:
		lines.append(tr("ui.action_slot.tooltip.quality_format") % q)
	# 容量 / 鲜度 / 耐久 aspect 行，UI 端就地渲染（不依赖已删除的
	# Item.instance_description_lines / preview_effects / format_effects_line）。
	_append_aspect_lines(lines, view)
	var shape_id := view.shape_type()
	if not shape_id.is_empty():
		var shape_def: Shape = Shapes.by_type(shape_id)
		var shape_name: String = shape_def.display_name if shape_def != null else shape_id
		lines.append(tr("ui.tooltip.shape_format") % shape_name)
	var mats := view.materials()
	if not mats.is_empty():
		var mat_lines: Array = []
		for part in mats.keys():
			var mat_id: String = String(mats[part])
			var mat: Substance = Materials.by_id(mat_id)
			var mat_name: String = mat.display_name if mat != null else mat_id
			mat_lines.append("  · %s = %s" % [part, mat_name])
		lines.append(tr("ui.tooltip.materials"))
		lines.append_array(mat_lines)
	var tags := view.tags()
	if tags.size() > 0:
		lines.append(tr("ui.tooltip.tags_format") % ", ".join(tags))
	# 功效：读 item.base_effects（Phase 1 fallback；Phase 2 改读 view.displayed_effects）
	_append_effects_line(lines, item)
	lines.append("")
	lines.append(tr("ui.action_slot.tooltip.return_hint"))
	return "\n".join(lines)


static func _append_aspect_lines(lines: Array, view: InventorySlotData) -> void:
	var container := view.as_container()
	if container != null and container.capacity() > 0.0:
		var cap_text := _format_amount(container.capacity())
		if container.is_empty():
			lines.append("容量：空 0/%s" % cap_text)
		else:
			var content_name := container.content_id()
			var mat: Substance = Materials.by_id(container.content_id())
			if mat != null and not mat.display_name.is_empty():
				content_name = mat.display_name
			lines.append("容量：%s %s/%s" % [content_name, _format_amount(container.amount()), cap_text])
	var perishable := view.as_perishable()
	if perishable != null:
		if perishable.is_rotten():
			lines.append("鲜度：已腐烂")
		else:
			lines.append("鲜度：%s" % PerishableAspect.tier_name(perishable.tier()))
	var dura := view.as_durability()
	if dura != null:
		lines.append("耐久：%d/%d" % [dura.value(), dura.max_value()])


static func _append_effects_line(lines: Array, item: Item) -> void:
	if item == null or item.base_effects.is_empty():
		return
	var parts: Array[String] = []
	for k in item.base_effects.keys():
		var amount := float(item.base_effects[k])
		var label := _localized_effect_label(String(k))
		var sign := "+" if amount >= 0.0 else ""
		var num := ("%.1f" % amount) if absf(amount - roundf(amount)) > 0.05 else str(int(roundf(amount)))
		parts.append("%s %s%s" % [label, sign, num])
	lines.append(TranslationServer.translate("ui.tooltip.effects_format") % ", ".join(parts))


static func _localized_effect_label(name: String) -> String:
	match name:
		"hunger": return TranslationServer.translate("attribute.hunger.name")
		"stamina": return TranslationServer.translate("attribute.stamina.name")
		"health", "hp": return TranslationServer.translate("attribute.hp.name")
		"rest": return TranslationServer.translate("attribute.rest.name")
		"sickness": return TranslationServer.translate("attribute.sickness.name")
		_:
			if name.begins_with("symptom."):
				return _symptom_label(name.substr("symptom.".length()))
			if name.begins_with("disease."):
				return TranslationServer.translate("ui.tooltip.treat_disease_format") % _disease_label(name.substr("disease.".length()))
			return name


static func _disease_label(disease_id: String) -> String:
	var key := "disease.%s.name" % disease_id
	var translated := str(TranslationServer.translate(key))
	return disease_id if translated == key else translated


static func _symptom_label(symptom_id: String) -> String:
	var key := "symptom.%s.name" % symptom_id
	var translated := str(TranslationServer.translate(key))
	return symptom_id if translated == key else translated


static func _format_amount(value: float) -> String:
	if absf(value - roundf(value)) < 0.05:
		return str(int(roundf(value)))
	return "%.1f" % value


func is_empty() -> bool:
	return int(_staged_data.get("quantity", 0)) <= 0


# 接受 InventorySlot._get_drag_data 的 dict（含 from_slot）。
# 不直接修改本地状态——发出 signal 让 ActionPanel 调 server RPC，server 推回更新本 slot。
func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("from_slot")


func _drop_data(_pos: Vector2, data: Variant) -> void:
	var inv_slot := int((data as Dictionary).get("from_slot", -1))
	if inv_slot < 0:
		return
	# 拖拽 = 全量（amount<=0 由 server 解释为整堆/整桶）
	staging_request.emit(inv_slot, 0)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or is_empty():
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		unstaging_request.emit(slot_index, 1)   # 左键 = 快速退回 1（原路）
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		split_request.emit(slot_index)           # 右键 = 开分离面板
		accept_event()


func _color_for(id: String) -> Color:
	var h := absi(id.hash())
	var hue := float(h % 360) / 360.0
	return Color.from_hsv(hue, 0.55, 0.85)


func _empty_color() -> Color:
	return Color(0.12, 0.12, 0.14, 0.6)
