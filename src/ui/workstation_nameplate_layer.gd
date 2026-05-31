class_name WorkstationNameplateLayer
extends CanvasLayer

# 工作站名字的 2D 屏幕空间 nameplate。原本 .tscn 自带 Label3D Title 永远可见，
# 太远的时候屏幕被名字糊满；改成跟 HeadNameplateLayer 一样按距离裁剪。
# Title Label3D 在 workstation_node 里被改成永久 hidden（编辑器视图里仍然显示，
# 帮助摆放）；runtime 全部走这层。

const SCREEN_MARGIN := 64.0
const SCREEN_Y_OFFSET := 0.0
const MAX_VISIBLE_DISTANCE := 10.0
const ANCHOR_FALLBACK_Y := 2.1  # 与 workstation_node.tscn 里 Title 的 Y 对齐

var _widgets: Dictionary = {}


func _ready() -> void:
	layer = 3
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_hide_all()
		return

	var seen := {}
	for ws in get_tree().get_nodes_in_group("workstations"):
		if not (ws is Node3D and is_instance_valid(ws)):
			continue
		var id := ws.get_instance_id()
		seen[id] = true
		var widget: Dictionary = _widgets.get(id, {})
		if widget.is_empty():
			widget = _create_widget(ws)
			_widgets[id] = widget
		_update_widget(widget, ws, camera)

	for id in _widgets.keys():
		if not seen.has(id):
			_remove_widget(id)


func _create_widget(ws: Node3D) -> Dictionary:
	var label := Label.new()
	label.name = "WorkstationName_%s" % ws.name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.85, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.015, 0.01, 0.92))
	label.add_theme_constant_override("outline_size", 3)
	add_child(label)
	return {"label": label}


func _update_widget(widget: Dictionary, ws: Node3D, camera: Camera3D) -> void:
	var label := widget["label"] as Label
	if not ws.is_inside_tree():
		label.visible = false
		return

	var anchor := _anchor_position(ws)
	if camera.is_position_behind(anchor):
		label.visible = false
		return

	if camera.global_position.distance_to(anchor) > MAX_VISIBLE_DISTANCE:
		label.visible = false
		return

	var screen_pos := camera.unproject_position(anchor)
	var viewport_size := get_viewport().get_visible_rect().size
	if screen_pos.x < -SCREEN_MARGIN or screen_pos.y < -SCREEN_MARGIN or screen_pos.x > viewport_size.x + SCREEN_MARGIN or screen_pos.y > viewport_size.y + SCREEN_MARGIN:
		label.visible = false
		return

	var display_name := String(ws.display_name).strip_edges() if "display_name" in ws else ""
	if display_name.is_empty():
		label.visible = false
		return

	label.text = display_name
	label.reset_size()
	var size := label.get_combined_minimum_size()
	label.position = screen_pos - Vector2(size.x * 0.5, size.y) + Vector2(0.0, SCREEN_Y_OFFSET)
	label.visible = true


func _anchor_position(ws: Node3D) -> Vector3:
	var title := ws.get_node_or_null("Title") as Node3D
	if title != null:
		return title.global_position
	return ws.global_position + Vector3(0.0, ANCHOR_FALLBACK_Y, 0.0)


func _remove_widget(id: int) -> void:
	var widget: Dictionary = _widgets.get(id, {})
	var label := widget.get("label", null) as Node
	if label != null and is_instance_valid(label):
		label.queue_free()
	_widgets.erase(id)


func _hide_all() -> void:
	for widget in _widgets.values():
		var label := widget.get("label", null) as CanvasItem
		if label != null and is_instance_valid(label):
			label.visible = false
