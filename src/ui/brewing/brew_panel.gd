class_name BrewPanel
extends CanvasLayer

# 玩家专用"酿酒"面板（client only）。右键一个装着水的酿酒桶选"酿酒…"时，ContainerPanel
# 调 open(barrel_ref)。列出这个桶能酿的全部酒（配方来自 data/mechanics/crafting.lua 的
# 发酵反应表，经 ferment_recipes 查询），每行：成品酒 + 需要的原料/已有数量 + [酿造]。
# 点 → player.request_brew RPC（服务端权威，复用 BrewHandlers.run_brew，与 NPC 同一逻辑）。
#
# 选原料 = 选配方：每条发酵反应对应一种原料→一种酒。加新酒只改反应表，本面板自动列出。

const VESSEL_TAG := "brewing_vessel"
const BASE_LIQUID := "water"

var _player: Node = null

# 桶端缓存（open 时定）
var _cid: String = ""        # ""=背包；否则容器节点 id
var _slot: int = -1
var _liters: int = 0
var _label: String = ""

var _root: Control
var _rows_box: VBoxContainer
var _title: Label
var _empty_label: Label
var _last_signature: String = ""


func _ready() -> void:
	layer = 12   # 高于 ContainerPanel(10)/ActionPanel(11)，叠在打开的容器面板之上
	_build_ui()
	_root.visible = false
	set_process(false)


func set_player(node: Node) -> void:
	_player = node


func is_open() -> bool:
	return _root != null and _root.visible


# barrel_ref: {container_id, slot_index, liters, label}
func open(barrel_ref: Dictionary) -> void:
	_cid = str(barrel_ref.get("container_id", ""))
	_slot = int(barrel_ref.get("slot_index", -1))
	_liters = int(ceil(float(barrel_ref.get("liters", 0.0))))
	_label = str(barrel_ref.get("label", ""))
	if _slot < 0 or _liters <= 0:
		return
	_title.text = tr("ui.brewing.title_format") % [_label, _liters]
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
	if _player == null:
		close()
		return
	# 背包原料数量变化 → 重建（刷新"已有 M"与按钮可用性）。
	var sig := _signature()
	if sig != _last_signature:
		_rebuild_rows()


func _recipes() -> Array:
	var raw: Variant = MechanicHost.query("crafting", "ferment_recipes", [[VESSEL_TAG], BASE_LIQUID])
	if raw == null:
		return []
	var out: Array = []
	for row_v in LuaConv.to_array(raw):
		out.append(LuaConv.to_dict(row_v))
	return out


func _count(item_id: String) -> int:
	if _player == null or item_id.is_empty():
		return 0
	var n := 0
	for s in _player.inventory:
		if str((s as Dictionary).get("item_id", "")) == item_id:
			n += int((s as Dictionary).get("quantity", 0))
	return n


func _signature() -> String:
	var parts: Array[String] = []
	for rec in _recipes():
		var ing := str(rec.get("ingredient", ""))
		parts.append("%s:%d" % [ing, _count(ing)])
	return "|".join(parts)


func _rebuild_rows() -> void:
	_last_signature = _signature()
	for c in _rows_box.get_children():
		c.queue_free()
	var recipes := _recipes()
	for rec in recipes:
		_rows_box.add_child(_build_row(rec))
	_empty_label.visible = recipes.is_empty()


func _build_row(rec: Dictionary) -> HBoxContainer:
	var recipe_id := str(rec.get("id", ""))
	var output := str(rec.get("output", ""))
	var ingredient := str(rec.get("ingredient", ""))
	var per := maxi(1, int(rec.get("ingredient_per_liter", 1)))
	var need := _liters * per
	var owned := _count(ingredient)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(120, 0)
	name_label.text = _item_name(output)
	row.add_child(name_label)

	var need_label := Label.new()
	need_label.custom_minimum_size = Vector2(220, 0)
	need_label.text = tr("ui.brewing.row_format") % [need, _item_name(ingredient), owned]
	if owned < need:
		need_label.add_theme_color_override("font_color", Color(0.9, 0.5, 0.4))
	row.add_child(need_label)

	var btn := Button.new()
	btn.text = tr("ui.brewing.brew_button")
	btn.disabled = owned < need
	btn.pressed.connect(func() -> void: _brew(recipe_id))
	row.add_child(btn)
	return row


func _brew(recipe_id: String) -> void:
	if _player == null or _slot < 0 or recipe_id.is_empty():
		return
	if not _player.has_method("request_brew"):
		return
	_player.request_brew.rpc_id(1, _cid, _slot, recipe_id)
	close()


func _item_name(item_id: String) -> String:
	var key := "item.%s.name" % item_id
	var n := tr(key)
	return n if n != key else item_id


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
	panel.offset_left = -260.0
	panel.offset_top = -170.0
	panel.offset_right = 260.0
	panel.offset_bottom = 170.0
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
	scroll.custom_minimum_size = Vector2(480, 220)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 6)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)

	_empty_label = Label.new()
	_empty_label.text = tr("ui.brewing.empty")
	_empty_label.visible = false
	vbox.add_child(_empty_label)

	var close_btn := Button.new()
	close_btn.text = tr("ui.brewing.close")
	close_btn.pressed.connect(close)
	vbox.add_child(close_btn)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.05, 0.95)
	style.border_color = Color(0.78, 0.62, 0.32, 0.85)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(4)
	return style
