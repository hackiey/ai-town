@tool
class_name RegionRenderer
extends MeshInstance3D

# 把 RegionMap.cell_region 画成半透明色块。每个 cell 一个 quad，颜色 = region.color。
# 未分配 cell 不画。编辑器 + 运行时都显示，可单独关。

@export var region_map: RegionMap:
	set(v):
		if region_map != null and region_map.changed.is_connected(_rebuild):
			region_map.changed.disconnect(_rebuild)
		region_map = v
		if region_map != null:
			region_map.changed.connect(_rebuild)
		_rebuild()

@export_range(0.0, 1.0) var alpha: float = 0.25
@export var y_offset: float = 0.01
@export var visible_in_runtime: bool = true


func _ready() -> void:
	_rebuild()
	if not Engine.is_editor_hint() and not visible_in_runtime:
		visible = false


func _rebuild() -> void:
	if region_map == null or region_map.grid == null:
		mesh = null
		return
	var grid := region_map.grid
	if region_map.cell_region.size() != grid.cell_count():
		mesh = null
		return

	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)

	var cs := grid.cell_size
	var origin := grid.origin + Vector3(0, y_offset, 0)

	for z in grid.depth:
		for x in grid.width:
			var idx := region_map.cell_region[z * grid.width + x]
			if idx < 0 or idx >= region_map.regions.size():
				continue
			var col := region_map.regions[idx].color
			col.a = alpha
			im.surface_set_color(col)

			var p0 := origin + Vector3(float(x) * cs, 0, float(z) * cs)
			var p1 := p0 + Vector3(cs, 0, 0)
			var p2 := p0 + Vector3(cs, 0, cs)
			var p3 := p0 + Vector3(0, 0, cs)

			# 两个三角形（CCW from above）
			im.surface_add_vertex(p0); im.surface_add_vertex(p2); im.surface_add_vertex(p1)
			im.surface_add_vertex(p0); im.surface_add_vertex(p3); im.surface_add_vertex(p2)

	im.surface_end()
	mesh = im
