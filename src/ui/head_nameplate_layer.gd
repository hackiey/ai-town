class_name HeadNameplateLayer
extends CanvasLayer

const MAX_BUBBLE_WIDTH := 220.0
const WIDGET_SIDE_PADDING := 8.0
const SCREEN_MARGIN := 64.0
const SCREEN_Y_OFFSET := 14.0
# 头顶 UI 可见距离：远了就别堆屏幕；说话气泡也按这个走，因为靠近才听得到的"距离感"
# 在玩法上是一致的。10m 之外整个 widget hide。
const MAX_VISIBLE_DISTANCE := 20.0
const SPEAKER_NAME_COLOR_HEX := "b8410e"
const BUBBLE_STACK_GAP := 3.0
const OVERLAP_RESOLVE_PASSES := 4

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
	for character in _tracked_characters():
		var id := character.get_instance_id()
		seen[id] = true
		var widget: Dictionary = _widgets.get(id, {})
		if widget.is_empty():
			widget = _create_widget(character)
			_widgets[id] = widget
		_update_widget(widget, character, camera)

	for id in _widgets.keys():
		if not seen.has(id):
			_remove_widget(id)

	_resolve_bubble_overlaps()


func _tracked_characters() -> Array[Character]:
	# 跳过本地玩家自己——头顶 nameplate 在第三人称视角下离镜头近，物理 Y 微抖被屏幕
	# 放大成可见抽动，玩家本来就知道自己是谁，没必要看。其他玩家 / NPC 的名字保留。
	var out: Array[Character] = []
	for group_name in ["npcs", "players"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if not (node is Character and is_instance_valid(node)):
				continue
			if node is Player and (node as Player).character_id == Players.local_character_id:
				continue
			out.append(node as Character)
	return out


func _create_widget(character: Character) -> Dictionary:
	var root := VBoxContainer.new()
	root.name = "HeadNameplate_%s" % character.name
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	var bubble := PanelContainer.new()
	bubble.name = "Bubble"
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bubble.visible = false
	root.add_child(bubble)

	var bubble_label := RichTextLabel.new()
	bubble_label.name = "BubbleText"
	bubble_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bubble_label.bbcode_enabled = true
	bubble_label.fit_content = true
	bubble_label.scroll_active = false
	bubble_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	bubble_label.add_theme_font_size_override("normal_font_size", 16)
	bubble_label.add_theme_font_size_override("bold_font_size", 16)
	bubble_label.add_theme_color_override("default_color", Color(0.14, 0.11, 0.08, 1.0))
	bubble.add_child(bubble_label)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Color(1.0, 0.98, 0.90, 1.0))
	name_label.add_theme_color_override("font_outline_color", Color(0.02, 0.015, 0.01, 0.92))
	name_label.add_theme_constant_override("outline_size", 3)
	root.add_child(name_label)

	var subtitle_label := Label.new()
	subtitle_label.name = "Subtitle"
	subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_label.add_theme_font_size_override("font_size", 12)
	subtitle_label.add_theme_color_override("font_color", Color(1.0, 0.76, 0.25, 1.0))
	subtitle_label.add_theme_color_override("font_outline_color", Color(0.02, 0.015, 0.01, 0.9))
	subtitle_label.add_theme_constant_override("outline_size", 2)
	root.add_child(subtitle_label)

	return {
		"root": root,
		"bubble": bubble,
		"bubble_label": bubble_label,
		"name_label": name_label,
		"subtitle_label": subtitle_label,
	}


func _update_widget(widget: Dictionary, character: Character, camera: Camera3D) -> void:
	var root := widget["root"] as VBoxContainer
	if not character.is_inside_tree():
		root.visible = false
		return

	var anchor := character.head_ui_world_position()
	if camera.is_position_behind(anchor):
		root.visible = false
		return

	if camera.global_position.distance_to(anchor) > MAX_VISIBLE_DISTANCE:
		root.visible = false
		return

	var screen_pos := camera.unproject_position(anchor)
	var viewport_size := get_viewport().get_visible_rect().size
	if screen_pos.x < -SCREEN_MARGIN or screen_pos.y < -SCREEN_MARGIN or screen_pos.x > viewport_size.x + SCREEN_MARGIN or screen_pos.y > viewport_size.y + SCREEN_MARGIN:
		root.visible = false
		return

	_apply_identity(widget, character)
	_apply_bubble(widget, character, character.head_status().bubble_state())

	var min_size := root.get_combined_minimum_size() + Vector2(WIDGET_SIDE_PADDING * 2.0, 0.0)
	root.size = min_size
	root.position = screen_pos - Vector2(min_size.x * 0.5, min_size.y) + Vector2(0.0, SCREEN_Y_OFFSET)
	root.visible = true


func _apply_identity(widget: Dictionary, character: Character) -> void:
	var name_label := widget["name_label"] as Label
	var subtitle_label := widget["subtitle_label"] as Label
	name_label.text = character.head_ui_display_name()
	var subtitle := character.head_ui_subtitle()
	subtitle_label.text = subtitle
	subtitle_label.visible = not subtitle.is_empty()


func _apply_bubble(widget: Dictionary, character: Character, state: Dictionary) -> void:
	var bubble := widget["bubble"] as PanelContainer
	var bubble_label := widget["bubble_label"] as RichTextLabel
	if not bool(state.get("visible", false)):
		bubble.visible = false
		return

	var text := str(state.get("text", "")).strip_edges()
	if text.is_empty():
		bubble.visible = false
		return

	var mode := str(state.get("mode", ""))
	var display_bbcode: String
	var measure_text: String
	if mode == "speech":
		var speaker := character.head_ui_display_name()
		display_bbcode = "[color=#%s]%s:[/color] %s" % [
			SPEAKER_NAME_COLOR_HEX,
			_escape_bbcode(speaker),
			_escape_bbcode(text),
		]
		measure_text = "%s: %s" % [speaker, text]
	else:
		display_bbcode = "[center]%s[/center]" % _escape_bbcode(text)
		measure_text = text

	var width := clampf(_measure_ui_width(measure_text) + 32.0, 64.0, MAX_BUBBLE_WIDTH)
	bubble.custom_minimum_size = Vector2(width, 0.0)
	bubble_label.custom_minimum_size = Vector2(width - 24.0, 0.0)
	bubble_label.text = display_bbcode
	bubble.add_theme_stylebox_override("panel", _bubble_style(mode))
	bubble.modulate.a = clampf(float(state.get("alpha", 1.0)), 0.0, 1.0)
	bubble.visible = true


func _escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")


func _measure_ui_width(text: String) -> float:
	var width := 0.0
	for i in text.length():
		var code := text.unicode_at(i)
		width += 8.0 if code >= 33 and code <= 126 else 16.0
	return width


func _bubble_style(mode: String) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	match mode:
		"thinking":
			style.bg_color = Color(1.0, 0.97, 0.86, 0.94)
		"override":
			style.bg_color = Color(0.96, 1.0, 0.94, 0.94)
		_:
			style.bg_color = Color(1.0, 0.98, 0.92, 0.94)
	style.corner_radius_top_left = 14
	style.corner_radius_top_right = 14
	style.corner_radius_bottom_left = 14
	style.corner_radius_bottom_right = 14
	style.set_content_margin(SIDE_LEFT, 12.0)
	style.set_content_margin(SIDE_RIGHT, 12.0)
	style.set_content_margin(SIDE_TOP, 7.0)
	style.set_content_margin(SIDE_BOTTOM, 7.0)
	return style


func _resolve_bubble_overlaps() -> void:
	# 多个 NPC 挤一起时，气泡会相互覆盖。每帧布局后跑几轮 pairwise 推挤：
	# 重叠就把"下面"那个气泡（连同 widget）整体上推，几趟之内收敛。
	var entries: Array = []
	for widget in _widgets.values():
		var root := widget.get("root", null) as Control
		var bubble := widget.get("bubble", null) as Control
		if root == null or not is_instance_valid(root) or not root.visible:
			continue
		if bubble == null or not is_instance_valid(bubble) or not bubble.visible:
			continue
		entries.append({"root": root, "bubble": bubble})

	if entries.size() < 2:
		return

	for _pass in OVERLAP_RESOLVE_PASSES:
		var moved := false
		for i in entries.size():
			for j in range(i + 1, entries.size()):
				var ra := _bubble_global_rect(entries[i])
				var rb := _bubble_global_rect(entries[j])
				if not ra.intersects(rb):
					continue
				# 把 bottom 更靠下（screen-Y 更大）的那个推到另一个上面
				var a_bottom := ra.position.y + ra.size.y
				var b_bottom := rb.position.y + rb.size.y
				var lower: Dictionary
				var upper_rect: Rect2
				var lower_rect: Rect2
				if a_bottom >= b_bottom:
					lower = entries[i]
					upper_rect = rb
					lower_rect = ra
				else:
					lower = entries[j]
					upper_rect = ra
					lower_rect = rb
				var shift_up := (lower_rect.position.y + lower_rect.size.y) - upper_rect.position.y + BUBBLE_STACK_GAP
				if shift_up > 0.0:
					(lower["root"] as Control).position.y -= shift_up
					moved = true
		if not moved:
			break


func _bubble_global_rect(entry: Dictionary) -> Rect2:
	var bubble := entry["bubble"] as Control
	return Rect2(bubble.global_position, bubble.size)


func _remove_widget(id: int) -> void:
	var widget: Dictionary = _widgets.get(id, {})
	var root := widget.get("root", null) as Node
	if root != null and is_instance_valid(root):
		root.queue_free()
	_widgets.erase(id)


func _hide_all() -> void:
	for widget in _widgets.values():
		var root := widget.get("root", null) as CanvasItem
		if root != null and is_instance_valid(root):
			root.visible = false
