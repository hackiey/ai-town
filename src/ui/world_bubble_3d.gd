class_name WorldBubble3D
extends Node3D

var font_size: int = 30
var pixel_size: float = 0.0034
var outline_size: int = 4
var max_units_per_line: float = 16.0
var max_lines: int = 3
var min_width: float = 0.58
var max_width: float = 2.2
var horizontal_padding: float = 0.16
var vertical_padding: float = 0.09
var line_height_factor: float = 1.18
var char_width_factor: float = 0.78
var tail_height: float = 0.12
var tail_width: float = 0.24
var corner_radius: float = 0.10
var bubble_color: Color = Color(0.08, 0.07, 0.06, 0.78)
var text_color: Color = Color(1.0, 1.0, 1.0, 1.0)
var outline_color: Color = Color(0.02, 0.02, 0.02, 0.92)

var _raw_text: String = ""
var _alpha: float = 1.0
var _background: MeshInstance3D = null
var _background_material: StandardMaterial3D = null
var _label: Label3D = null


func _ready() -> void:
	_ensure_nodes()
	_refresh()


func set_text(value: String) -> void:
	_raw_text = value.strip_edges()
	_refresh()


func set_alpha(value: float) -> void:
	_alpha = clampf(value, 0.0, 1.0)
	_apply_alpha()


func _ensure_nodes() -> void:
	if _background == null:
		_background = MeshInstance3D.new()
		_background.name = "BubbleBackground"
		_background.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_background_material = StandardMaterial3D.new()
		_background_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_background_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_background_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_background_material.no_depth_test = true
		_background_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_background_material.render_priority = -1
		_background.material_override = _background_material
		add_child(_background)
	if _label == null:
		_label = Label3D.new()
		_label.name = "BubbleText"
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.fixed_size = false
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.set("render_priority", 1)
		_label.set("outline_render_priority", 2)
		add_child(_label)
	_apply_alpha()


func _refresh() -> void:
	_ensure_nodes()
	var lines := _wrapped_lines(_raw_text)
	var wrapped_text := ""
	var max_units := 1.0
	for i in lines.size():
		var line := String(lines[i])
		if i > 0:
			wrapped_text += "\n"
		wrapped_text += line
		max_units = maxf(max_units, _measure_units(line))

	_label.text = wrapped_text
	_label.font_size = font_size
	_label.pixel_size = pixel_size
	_label.outline_size = outline_size

	var line_height := float(font_size) * pixel_size * line_height_factor
	var text_width := max_units * float(font_size) * pixel_size * char_width_factor
	var rect_width := clampf(text_width + horizontal_padding * 2.0, min_width, max_width)
	var rect_height := maxf(line_height, float(lines.size()) * line_height) + vertical_padding * 2.0
	var active_tail_width := minf(tail_width, rect_width * 0.35)
	var active_radius := minf(corner_radius, minf(rect_width, rect_height) * 0.5)
	_background.mesh = _make_bubble_mesh(rect_width, rect_height, active_tail_width, tail_height, active_radius)
	_label.position = Vector3(0.0, tail_height + rect_height * 0.5, 0.0)
	_apply_alpha()


func _apply_alpha() -> void:
	if _background_material != null:
		var bg := bubble_color
		bg.a *= _alpha
		_background_material.albedo_color = bg
	if _label != null:
		var fg := text_color
		fg.a *= _alpha
		_label.modulate = fg
		var stroke := outline_color
		stroke.a *= _alpha
		_label.outline_modulate = stroke


func _wrapped_lines(value: String) -> Array:
	var lines: Array = []
	var source := value if not value.is_empty() else " "
	for paragraph in source.split("\n", true):
		var paragraph_lines := _wrap_paragraph(String(paragraph))
		for line in paragraph_lines:
			lines.append(line)
	if lines.is_empty():
		lines.append("")
	if max_lines > 0 and lines.size() > max_lines:
		var truncated: Array = []
		for i in max_lines:
			truncated.append(lines[i])
		truncated[max_lines - 1] = _truncate_to_units(String(truncated[max_lines - 1]), max_units_per_line - 1.5) + "..."
		return truncated
	return lines


func _wrap_paragraph(paragraph: String) -> Array:
	if max_units_per_line <= 0.0:
		return [paragraph]
	var lines: Array = []
	var current := ""
	var current_units := 0.0
	for i in paragraph.length():
		var ch := paragraph.substr(i, 1)
		var units := _char_units(paragraph.unicode_at(i))
		if current_units + units > max_units_per_line and not current.is_empty():
			lines.append(current.strip_edges())
			current = ch
			current_units = units
		else:
			current += ch
			current_units += units
	if not current.is_empty() or paragraph.is_empty():
		lines.append(current.strip_edges())
	return lines


func _truncate_to_units(value: String, max_units: float) -> String:
	var result := ""
	var used := 0.0
	for i in value.length():
		var ch := value.substr(i, 1)
		var units := _char_units(value.unicode_at(i))
		if used + units > max_units:
			break
		result += ch
		used += units
	return result.strip_edges()


func _measure_units(value: String) -> float:
	var units := 0.0
	for i in value.length():
		units += _char_units(value.unicode_at(i))
	return units


func _char_units(code: int) -> float:
	if code == 32 or code == 9:
		return 0.35
	if code >= 33 and code <= 126:
		return 0.55
	return 1.0


func _make_bubble_mesh(rect_width: float, rect_height: float, active_tail_width: float, active_tail_height: float, radius: float) -> ArrayMesh:
	var left := -rect_width * 0.5
	var right := rect_width * 0.5
	var bottom := active_tail_height
	var top := active_tail_height + rect_height
	var points := PackedVector2Array()
	points.append(Vector2(0.0, 0.0))
	points.append(Vector2(active_tail_width * 0.5, bottom))
	points.append(Vector2(right - radius, bottom))
	_append_arc(points, Vector2(right - radius, bottom + radius), radius, -90.0, 0.0, 4)
	points.append(Vector2(right, top - radius))
	_append_arc(points, Vector2(right - radius, top - radius), radius, 0.0, 90.0, 4)
	points.append(Vector2(left + radius, top))
	_append_arc(points, Vector2(left + radius, top - radius), radius, 90.0, 180.0, 4)
	points.append(Vector2(left, bottom + radius))
	_append_arc(points, Vector2(left + radius, bottom + radius), radius, 180.0, 270.0, 4)
	points.append(Vector2(-active_tail_width * 0.5, bottom))

	var indices := Geometry2D.triangulate_polygon(points)
	var vertices := PackedVector3Array()
	for p in points:
		vertices.append(Vector3(p.x, p.y, 0.0))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _append_arc(points: PackedVector2Array, center: Vector2, radius: float, start_deg: float, end_deg: float, steps: int) -> void:
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var angle := deg_to_rad(lerpf(start_deg, end_deg, t))
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
