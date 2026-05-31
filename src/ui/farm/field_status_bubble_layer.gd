class_name FieldStatusBubbleLayer
extends CanvasLayer

const MIN_BUBBLE_WIDTH := 112.0
const MAX_BUBBLE_WIDTH := 240.0
const LABEL_HORIZONTAL_PADDING := 22.0
const SCREEN_MARGIN := 64.0
const SCREEN_EDGE_PADDING := 8.0
const SCREEN_Y_OFFSET := 10.0

var _widgets: Dictionary = {}
var _player: Node3D = null


func _ready() -> void:
	layer = 2
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func set_player(player: Node) -> void:
	_player = player as Node3D
	if _player == null:
		_hide_all()


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null or _player == null or not is_instance_valid(_player) or not _player.is_inside_tree():
		_hide_all()
		return

	var seen := {}
	for crop in _tracked_crops():
		if crop.global_position.distance_to(_player.global_position) > Crop.LABEL_VISIBLE_RANGE:
			continue
		var text := crop.field_status_text().strip_edges()
		if text.is_empty():
			continue
		var anchor := crop.field_status_anchor()
		if camera.is_position_behind(anchor):
			continue
		var screen_pos := camera.unproject_position(anchor)
		if not _is_on_screen(screen_pos):
			continue

		var id := crop.get_instance_id()
		seen[id] = true
		var widget: Dictionary = _widgets.get(id, {})
		if widget.is_empty():
			widget = _create_widget(crop)
			_widgets[id] = widget
		_update_widget(widget, text, screen_pos)

	for id in _widgets.keys():
		if not seen.has(id):
			_remove_widget(id)


func _tracked_crops() -> Array[Crop]:
	var out: Array[Crop] = []
	for node in get_tree().get_nodes_in_group("crops"):
		if node is Crop and is_instance_valid(node):
			out.append(node as Crop)
	return out


func _is_on_screen(screen_pos: Vector2) -> bool:
	var viewport_size := get_viewport().get_visible_rect().size
	return screen_pos.x >= -SCREEN_MARGIN \
		and screen_pos.y >= -SCREEN_MARGIN \
		and screen_pos.x <= viewport_size.x + SCREEN_MARGIN \
		and screen_pos.y <= viewport_size.y + SCREEN_MARGIN


func _create_widget(crop: Crop) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "FieldStatusBubble_%s" % crop.name
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _bubble_style())
	panel.visible = false
	add_child(panel)

	var label := Label.new()
	label.name = "Text"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.94, 1.0, 0.88, 0.96))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.72))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	panel.add_child(label)

	return {
		"panel": panel,
		"label": label,
		"ready": false,
	}


func _update_widget(widget: Dictionary, text: String, screen_pos: Vector2) -> void:
	var panel := widget["panel"] as PanelContainer
	var label := widget["label"] as Label
	if widget.get("last_text", "") != text:
		widget["last_text"] = text
		label.text = text
		var lines := text.count("\n") + 1
		var w := clampf(_measure_text_width(text) + LABEL_HORIZONTAL_PADDING, MIN_BUBBLE_WIDTH, MAX_BUBBLE_WIDTH)
		var h := float(lines) * 18.0 + 12.0
		var size := Vector2(w, h)
		widget["size"] = size
		panel.custom_minimum_size = size
		panel.size = size

	var bubble_size: Vector2 = widget.get("size", panel.size)
	var viewport_size := get_viewport().get_visible_rect().size
	var max_x := maxf(SCREEN_EDGE_PADDING, viewport_size.x - bubble_size.x - SCREEN_EDGE_PADDING)
	var max_y := maxf(SCREEN_EDGE_PADDING, viewport_size.y - bubble_size.y - SCREEN_EDGE_PADDING)
	var pos := screen_pos - Vector2(bubble_size.x * 0.5, bubble_size.y + SCREEN_Y_OFFSET)
	panel.position = Vector2(
		clampf(pos.x, SCREEN_EDGE_PADDING, max_x),
		clampf(pos.y, SCREEN_EDGE_PADDING, max_y)
	)
	if widget.get("ready", false):
		panel.visible = true
	else:
		widget["ready"] = true


func _measure_text_width(text: String) -> float:
	var max_width := 0.0
	for raw_line in text.split("\n", true):
		var line := String(raw_line)
		var width := 0.0
		for i in line.length():
			var code := line.unicode_at(i)
			width += 7.0 if code >= 33 and code <= 126 else 14.0
		max_width = maxf(max_width, width)
	return max_width


func _bubble_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.055, 0.035, 0.18)
	style.border_color = Color(0.68, 0.92, 0.48, 0.32)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 13
	style.corner_radius_top_right = 13
	style.corner_radius_bottom_left = 13
	style.corner_radius_bottom_right = 13
	style.set_content_margin(SIDE_LEFT, 11.0)
	style.set_content_margin(SIDE_RIGHT, 11.0)
	style.set_content_margin(SIDE_TOP, 6.0)
	style.set_content_margin(SIDE_BOTTOM, 6.0)
	return style


func _remove_widget(id: int) -> void:
	var widget: Dictionary = _widgets.get(id, {})
	var panel := widget.get("panel", null) as Node
	if panel != null and is_instance_valid(panel):
		panel.queue_free()
	_widgets.erase(id)


func _hide_all() -> void:
	for widget in _widgets.values():
		var panel := widget.get("panel", null) as CanvasItem
		if panel != null and is_instance_valid(panel):
			panel.visible = false
