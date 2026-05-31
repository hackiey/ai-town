class_name NpcHoverStatus
extends CanvasLayer

# Client-only hover panel for public NPC vitals. The NPC body itself is picked
# with a short physics ray from the current camera through the mouse cursor.

const NPC_COLLISION_MASK := 2
const RAY_LENGTH := 1000.0
const TOOLTIP_OFFSET := Vector2(18.0, 18.0)
const SCREEN_PADDING := 12.0

var _panel: PanelContainer = null
var _title: Label = null
var _condition_label: Label = null
var _rows: Dictionary = {}
var _hovered: Character = null


func _ready() -> void:
	layer = 9
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	set_process(true)


func _process(_delta: float) -> void:
	_hovered = _pick_hovered_npc()
	if _hovered == null:
		_panel.visible = false
		return
	_render(_hovered)
	_place_panel()
	_panel.visible = true


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "NpcHoverPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 7)
	margin.add_child(vbox)

	_title = Label.new()
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48, 1.0))
	_title.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	_title.add_theme_constant_override("shadow_offset_x", 1)
	_title.add_theme_constant_override("shadow_offset_y", 1)
	vbox.add_child(_title)

	var grid := GridContainer.new()
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 5)
	vbox.add_child(grid)

	_add_meter_row(grid, "hp", Color(0.86, 0.22, 0.22, 1.0))
	_add_meter_row(grid, "stamina", Color(0.22, 0.72, 0.34, 1.0))
	_add_meter_row(grid, "hunger", Color(0.91, 0.64, 0.22, 1.0))
	_add_meter_row(grid, "rest", Color(0.34, 0.56, 0.96, 1.0))

	_condition_label = Label.new()
	_condition_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_condition_label.add_theme_font_size_override("font_size", 12)
	_condition_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.42, 1.0))
	_condition_label.visible = false
	vbox.add_child(_condition_label)


func _add_meter_row(parent: GridContainer, attribute_id: String, color: Color) -> void:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.custom_minimum_size = Vector2(36.0, 0.0)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84, 1.0))
	parent.add_child(label)

	var bar := ProgressBar.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.custom_minimum_size = Vector2(104.0, 10.0)
	bar.show_percentage = false
	bar.add_theme_stylebox_override("background", _bar_background_style())
	bar.add_theme_stylebox_override("fill", _bar_fill_style(color))
	parent.add_child(bar)

	var value := Label.new()
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value.custom_minimum_size = Vector2(64.0, 0.0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_font_size_override("font_size", 12)
	value.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84, 1.0))
	parent.add_child(value)

	_rows[attribute_id] = {
		"label": label,
		"bar": bar,
		"value": value,
	}


func _pick_hovered_npc() -> Character:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		return null

	var mouse_pos := viewport.get_mouse_position()
	if not viewport.get_visible_rect().has_point(mouse_pos):
		return null

	var world := camera.get_world_3d()
	if world == null:
		return null

	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * RAY_LENGTH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = NPC_COLLISION_MASK
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null

	var node: Node = hit.get("collider", null) as Node
	while node != null:
		if node is Character and node.is_in_group("npcs"):
			return node as Character
		node = node.get_parent()
	return null


func _render(character: Character) -> void:
	_title.text = tr("ui.npc_hover.title_format") % character.head_ui_display_name()
	_set_meter("hp", character.hp, character.max_hp)
	_set_meter("stamina", character.stamina, character.snapshots().effective_stamina_max())
	_set_meter("hunger", character.hunger, character.max_hunger)
	_set_meter("rest", character.rest, character.max_rest)

	var conditions := _condition_labels(character)
	_condition_label.visible = conditions.size() > 0
	_condition_label.text = "  ".join(conditions)


func _set_meter(attribute_id: String, current: float, max_value: float) -> void:
	var row: Dictionary = _rows.get(attribute_id, {})
	if row.is_empty():
		return
	var label := row["label"] as Label
	var bar := row["bar"] as ProgressBar
	var value := row["value"] as Label
	var safe_max := maxf(max_value, 1.0)
	label.text = tr("attribute.%s.name" % attribute_id)
	bar.max_value = safe_max
	bar.value = clampf(current, 0.0, safe_max)
	value.text = "%.0f / %.0f" % [current, max_value]


func _condition_labels(character: Character) -> Array[String]:
	var labels: Array[String] = []
	if not character.alive:
		labels.append(tr("ui.status.condition.dead"))
	if character.burning:
		labels.append(tr("ui.status.condition.burning"))
	for condition_v in character.active_conditions:
		if not (condition_v is Dictionary):
			continue
		var condition: Dictionary = condition_v as Dictionary
		var condition_type := str(condition.get("type", ""))
		if condition_type.is_empty():
			continue
		var key := "ui.status.condition.%s" % condition_type
		var localized := tr(key)
		labels.append(localized if localized != key else condition_type)
	return labels


func _place_panel() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var mouse_pos := get_viewport().get_mouse_position()
	var panel_size := _panel.get_combined_minimum_size()
	_panel.size = panel_size

	var pos := mouse_pos + TOOLTIP_OFFSET
	if pos.x + panel_size.x > viewport_size.x - SCREEN_PADDING:
		pos.x = mouse_pos.x - panel_size.x - TOOLTIP_OFFSET.x
	if pos.y + panel_size.y > viewport_size.y - SCREEN_PADDING:
		pos.y = mouse_pos.y - panel_size.y - TOOLTIP_OFFSET.y

	var max_x := maxf(SCREEN_PADDING, viewport_size.x - panel_size.x - SCREEN_PADDING)
	var max_y := maxf(SCREEN_PADDING, viewport_size.y - panel_size.y - SCREEN_PADDING)
	_panel.position = Vector2(
		clampf(pos.x, SCREEN_PADDING, max_x),
		clampf(pos.y, SCREEN_PADDING, max_y)
	)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.045, 0.035, 0.92)
	style.border_color = Color(0.88, 0.70, 0.38, 0.72)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	return style


func _bar_background_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.42)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style


func _bar_fill_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style
