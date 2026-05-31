class_name ShelfNameplateLayer
extends CanvasLayer

# 货架的 2D 屏幕空间 nameplate。同 WorkstationNameplateLayer 思路：
#   - 远处不显示（≤ NAME_VISIBLE_DISTANCE 才出名字）
#   - 玩家走进 Area3D 半径后再显示 "按 E 查看" 副标题
# 名字 + 按键提示都拼到货架 Title Label3D 的屏幕投影位置。
#
# 注意：prompt 显示走 shelf_proximity_changed 信号（玩家身体 vs Area3D）而不是
# camera-to-shelf 距离 —— 第三人称相机离玩家有距离，否则玩家贴脸了 prompt 还不出。

const SCREEN_MARGIN := 64.0
const NAME_VISIBLE_DISTANCE := 10.0
const ANCHOR_FALLBACK_Y := 1.2  # 与 shelf_node.tscn 里 Title 的 Y 对齐

var _widgets: Dictionary = {}
var _proximate_shelf_ids: Dictionary = {}  # instance_id → true，本地玩家当前在 Area3D 内的货架


func _ready() -> void:
	layer = 3
	process_mode = Node.PROCESS_MODE_ALWAYS
	EventBus.shelf_proximity_changed.connect(_on_proximity_changed)
	set_process(true)


func _on_proximity_changed(shelf: Node, entered: bool) -> void:
	if shelf == null:
		return
	var id := shelf.get_instance_id()
	if entered:
		_proximate_shelf_ids[id] = true
	else:
		_proximate_shelf_ids.erase(id)


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_hide_all()
		return

	var seen := {}
	for shelf in get_tree().get_nodes_in_group("shelves"):
		if not (shelf is Node3D and is_instance_valid(shelf)):
			continue
		var id := shelf.get_instance_id()
		seen[id] = true
		var widget: Dictionary = _widgets.get(id, {})
		if widget.is_empty():
			widget = _create_widget(shelf)
			_widgets[id] = widget
		_update_widget(widget, shelf, camera)

	for id in _widgets.keys():
		if not seen.has(id):
			_remove_widget(id)


func _create_widget(shelf: Node3D) -> Dictionary:
	var name_label := _build_label("ShelfName_%s" % shelf.name, 18, Color(1.0, 1.0, 0.85, 1.0))
	add_child(name_label)
	var prompt_label := _build_label("ShelfPrompt_%s" % shelf.name, 14, Color(0.9, 0.9, 0.7, 1.0))
	add_child(prompt_label)
	return {"name_label": name_label, "prompt_label": prompt_label}


func _build_label(node_name: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.015, 0.01, 0.92))
	label.add_theme_constant_override("outline_size", 3)
	label.visible = false
	return label


func _update_widget(widget: Dictionary, shelf: Node3D, camera: Camera3D) -> void:
	var name_label := widget["name_label"] as Label
	var prompt_label := widget["prompt_label"] as Label
	if not shelf.is_inside_tree():
		name_label.visible = false
		prompt_label.visible = false
		return

	var anchor := _anchor_position(shelf)
	if camera.is_position_behind(anchor):
		name_label.visible = false
		prompt_label.visible = false
		return

	var distance := camera.global_position.distance_to(anchor)
	if distance > NAME_VISIBLE_DISTANCE:
		name_label.visible = false
		prompt_label.visible = false
		return

	var screen_pos := camera.unproject_position(anchor)
	var viewport_size := get_viewport().get_visible_rect().size
	if screen_pos.x < -SCREEN_MARGIN or screen_pos.y < -SCREEN_MARGIN or screen_pos.x > viewport_size.x + SCREEN_MARGIN or screen_pos.y > viewport_size.y + SCREEN_MARGIN:
		name_label.visible = false
		prompt_label.visible = false
		return

	var display_name := String(shelf.display_name).strip_edges() if "display_name" in shelf else ""
	if display_name.is_empty():
		name_label.visible = false
		prompt_label.visible = false
		return

	name_label.text = display_name
	name_label.reset_size()
	var name_size := name_label.get_combined_minimum_size()
	name_label.position = screen_pos - Vector2(name_size.x * 0.5, name_size.y)
	name_label.visible = true

	if _proximate_shelf_ids.has(shelf.get_instance_id()):
		var prompt := String(shelf.prompt_text).strip_edges() if "prompt_text" in shelf else ""
		if prompt.is_empty():
			prompt_label.visible = false
		else:
			prompt_label.text = prompt
			prompt_label.reset_size()
			var prompt_size := prompt_label.get_combined_minimum_size()
			# 副标题贴在名字下方一行。
			prompt_label.position = screen_pos - Vector2(prompt_size.x * 0.5, 0.0)
			prompt_label.visible = true
	else:
		prompt_label.visible = false


func _anchor_position(shelf: Node3D) -> Vector3:
	var title := shelf.get_node_or_null("Title") as Node3D
	if title != null:
		return title.global_position
	return shelf.global_position + Vector3(0.0, ANCHOR_FALLBACK_Y, 0.0)


func _remove_widget(id: int) -> void:
	var widget: Dictionary = _widgets.get(id, {})
	for key in ["name_label", "prompt_label"]:
		var label := widget.get(key, null) as Node
		if label != null and is_instance_valid(label):
			label.queue_free()
	_widgets.erase(id)
	_proximate_shelf_ids.erase(id)


func _hide_all() -> void:
	for widget in _widgets.values():
		for key in ["name_label", "prompt_label"]:
			var label := widget.get(key, null) as CanvasItem
			if label != null and is_instance_valid(label):
				label.visible = false
