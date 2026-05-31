@tool
class_name GridRenderer
extends MeshInstance3D

# 把 MapGrid 画成线框（每 cell 一条线，主网格每 N cell 一条粗线）。
# 编辑器内 + 运行时都能显示，可单独关。

@export var grid: MapGrid:
	set(v):
		if grid != null and grid.changed.is_connected(_rebuild):
			grid.changed.disconnect(_rebuild)
		grid = v
		if grid != null:
			grid.changed.connect(_rebuild)
		_rebuild()

@export var minor_color: Color = Color(1, 1, 1, 0.10)
@export var major_color: Color = Color(1, 1, 1, 0.30)
@export var major_every: int = 10
@export var y_offset: float = 0.02
@export var visible_in_runtime: bool = true


func _ready() -> void:
	_rebuild()
	if not Engine.is_editor_hint() and not visible_in_runtime:
		visible = false


func _rebuild() -> void:
	if grid == null:
		mesh = null
		return

	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = false

	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)

	var origin := grid.origin + Vector3(0, y_offset, 0)
	var w_world := float(grid.width) * grid.cell_size
	var d_world := float(grid.depth) * grid.cell_size

	# X 方向竖线（沿 Z 走）
	for x in range(grid.width + 1):
		var c := major_color if (x % major_every == 0) else minor_color
		im.surface_set_color(c)
		var x_world := float(x) * grid.cell_size
		im.surface_add_vertex(origin + Vector3(x_world, 0, 0))
		im.surface_add_vertex(origin + Vector3(x_world, 0, d_world))

	# Z 方向横线（沿 X 走）
	for z in range(grid.depth + 1):
		var c := major_color if (z % major_every == 0) else minor_color
		im.surface_set_color(c)
		var z_world := float(z) * grid.cell_size
		im.surface_add_vertex(origin + Vector3(0, 0, z_world))
		im.surface_add_vertex(origin + Vector3(w_world, 0, z_world))

	im.surface_end()
	mesh = im
