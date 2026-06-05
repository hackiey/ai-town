class_name InventorySlot
extends PanelContainer

# 单个背包格子（client UI）：
# - 显示色块 icon + 数量 + tooltip
# - 右键非空格 → PopupMenu (使用 / 丢弃)，按选择 emit 信号
# - 左键拖拽非空格 → 拖到另一格 emit swap_requested
# 不发 RPC，全部 emit 给 InventoryPanel 集中处理。

signal use_requested(slot_index: int)
signal drop_requested(slot_index: int)
signal swap_requested(from_index: int, to_index: int)

const Money = preload("res://src/sim/characters/money.gd")
const SIZE := Vector2(64, 64)
const MENU_USE := 1
const MENU_DROP := 2

var slot_index: int = -1
var item_id: String = ""
var quantity: int = 0
var quality: int = 0
var _slot_data: Dictionary = {}  # 完整 instance dict（drag data 用）

# 显示分两层：底色块 _bg + 上面叠 _icon TextureRect。
# 有 Item.icon 时 _icon 显示纹理（modulate=Item.tint）；没有时 _icon 隐藏，_bg 显示哈希色块。
# 这样从 placeholder 到真 icon 的过渡是平滑的，不需要等所有 item 都有 icon 才能用。
# 没 icon 时 _name_overlay 在色块上显 display_name，不用 hover 也能认出物品。
# 设计：docs/architecture/crafting-interaction.md §2.4
var _bg: ColorRect
var _icon: TextureRect
var _name_overlay: Label
var _qty: Label
var _price: Label  # 货架场景下显示标价（slot dict 含 listing_price_centi 时自动渲染）
var _menu: PopupMenu


func _init() -> void:
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	_bg = ColorRect.new()
	_bg.color = _empty_color()
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_bg)

	_icon = TextureRect.new()
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.visible = false
	_bg.add_child(_icon)

	# 没 icon 时在色块上叠物品名（持久显示，不用 hover 也能认出）
	_name_overlay = Label.new()
	_name_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_name_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_overlay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_overlay.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_overlay.add_theme_font_size_override("font_size", 11)
	_name_overlay.add_theme_color_override("font_color", Color(1, 1, 1))
	_name_overlay.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_name_overlay.add_theme_constant_override("outline_size", 4)
	_name_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_overlay.visible = false
	_bg.add_child(_name_overlay)

	_qty = Label.new()
	_qty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_qty.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_qty.add_theme_color_override("font_color", Color(1, 1, 1))
	_qty.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_qty.add_theme_constant_override("outline_size", 4)
	_qty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_qty)

	# 货架标价用：slot dict 含 listing_price_centi（非 null）时自动显示在左下角；
	# 普通背包 / 容器 slot 该字段为 null，label 保持隐藏。
	_price = Label.new()
	_price.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_price.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_price.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_price.add_theme_font_size_override("font_size", 11)
	_price.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	_price.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_price.add_theme_constant_override("outline_size", 4)
	_price.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_price.visible = false
	add_child(_price)

	_menu = PopupMenu.new()
	_menu.add_item(tr("ui.inventory.menu.use"), MENU_USE)
	_menu.add_item(tr("ui.inventory.menu.drop"), MENU_DROP)
	add_child(_menu)


func _ready() -> void:
	_menu.id_pressed.connect(_on_menu_id_pressed)


# 接受完整 instance dict（item_id/quality/shape_type/materials/tags/properties/quantity）。
# 兼容空 slot（id 空 or qty 0）。所有 slot 字段读取走 InventorySlotData。
func set_slot(index: int, slot_data: Dictionary) -> void:
	slot_index = index
	_slot_data = slot_data.duplicate(true)
	var view := InventorySlotData.of(slot_data)
	item_id = view.id()
	quantity = view.quantity()
	quality = view.quality()
	if view.is_empty():
		_bg.color = _empty_color()
		_icon.visible = false
		_icon.texture = null
		_name_overlay.visible = false
		_name_overlay.text = ""
		_qty.text = ""
		_price.visible = false
		_price.text = ""
		tooltip_text = ""
		_set_quality_border(0)
		return
	var item := view.template()
	var name_for_tip := view.display_name()
	if item != null and item.icon != null:
		_icon.texture = item.icon
		_icon.modulate = item.tint
		_icon.visible = true
		_name_overlay.visible = false
		_bg.color = _empty_color()
	else:
		_icon.visible = false
		_icon.texture = null
		_bg.color = view.display_color(_color_for(view.id()))
		_name_overlay.text = name_for_tip
		_name_overlay.visible = true
	_qty.text = str(quantity) if quantity > 1 else ""
	# 货架槽位带 listing_price_centi（centi 整数标价）；普通背包/容器 dict 该字段为 null，
	# price label 自动隐藏。货架已统一为容器（slot aspect），不再有独立 listing 投影。
	var price_v: Variant = slot_data.get("listing_price_centi", null)
	var price_centi := int(price_v) if price_v != null else -1
	if price_centi >= 0:
		_price.text = Money.format_silver_from_centi(price_centi)
		_price.visible = true
	else:
		_price.visible = false
		_price.text = ""
	tooltip_text = _build_tooltip(view, item, name_for_tip)
	_set_quality_border(quality)


# Tooltip 文本由 ItemTooltipFormatter 单一来源生成，跟 ground_item_hover_status 共享。
# 见 src/ui/inventory/item_tooltip_formatter.gd。
func _build_tooltip(view: InventorySlotData, item: Item, name_for_tip: String) -> String:
	return ItemTooltipFormatter.format(view, item, name_for_tip)


# 边框颜色按品质 4 桶；颜色表来自 QualityTier 单一来源。空槽透明。
func _set_quality_border(q: int) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.12, 0.85)
	sb.border_color = QualityTier.color(q)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	add_theme_stylebox_override("panel", sb)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	if item_id.is_empty() or quantity <= 0:
		return
	# 嵌入式 PopupMenu 的 position 用 viewport 坐标。CanvasLayer 下 Control 的
	# get_global_mouse_position 就是 viewport 坐标，正好对得上。
	_menu.position = Vector2i(get_global_mouse_position())
	_menu.popup()
	accept_event()


# 左键拖动时 Godot 自动调；返回非 null 表示开始 drag。右键不会触发。
func _get_drag_data(_at_position: Vector2) -> Variant:
	if item_id.is_empty() or quantity <= 0:
		return null
	var item: Item = Items.by_id(item_id)
	var preview_size := SIZE - Vector2(8, 8)
	if item != null and item.icon != null:
		var tex := TextureRect.new()
		tex.texture = item.icon
		tex.modulate = item.tint
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.custom_minimum_size = preview_size
		tex.size = preview_size
		set_drag_preview(tex)
	else:
		var preview := ColorRect.new()
		preview.color = _color_for(item_id)
		preview.custom_minimum_size = preview_size
		preview.size = preview_size
		set_drag_preview(preview)
	# 完整 instance dict 一并带过去，让 ActionPanel slot tooltip 能显示 quality/materials
	var payload := _slot_data.duplicate(true)
	payload["from_slot"] = slot_index
	return payload


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("from_slot") and int(data["from_slot"]) != slot_index


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	swap_requested.emit(int(data["from_slot"]), slot_index)


func _on_menu_id_pressed(id: int) -> void:
	if id == MENU_USE:
		use_requested.emit(slot_index)
	elif id == MENU_DROP:
		drop_requested.emit(slot_index)


func _color_for(id: String) -> Color:
	var h := absi(id.hash())
	var hue := float(h % 360) / 360.0
	return Color.from_hsv(hue, 0.55, 0.85)


func _empty_color() -> Color:
	return Color(0.12, 0.12, 0.14, 0.6)
