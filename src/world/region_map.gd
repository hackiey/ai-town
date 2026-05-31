@tool
class_name RegionMap
extends Resource

# 区域配置 + baked cell→region 索引数组。
# author 时改 grid / regions / rects 后点 Bake，cell_region 才更新。

@export var grid: MapGrid
@export var regions: Array[MapRegion] = []
@export var rects: Array[RegionRect] = []

# baked: 每个 cell 一个 int = regions 数组索引；-1 = 未分配。
# 大小 = grid.width * grid.depth。
@export_storage var cell_region: PackedInt32Array = PackedInt32Array()

@export_tool_button("Bake", "Reload") var bake_action = bake


func bake() -> void:
	if grid == null:
		push_error("[RegionMap.bake] grid is required")
		return
	var n := grid.cell_count()
	cell_region = PackedInt32Array()
	cell_region.resize(n)
	cell_region.fill(-1)

	var id_to_index := {}
	for i in regions.size():
		id_to_index[regions[i].id] = i

	for r in rects:
		if not id_to_index.has(r.region_id):
			push_warning("[RegionMap.bake] rect refers to unknown region_id: %s" % r.region_id)
			continue
		var idx: int = id_to_index[r.region_id]
		var x0: int = max(0, r.min.x)
		var y0: int = max(0, r.min.y)
		var x1: int = min(grid.width - 1, r.max.x)
		var y1: int = min(grid.depth - 1, r.max.y)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				cell_region[y * grid.width + x] = idx

	emit_changed()
	print("[RegionMap.bake] %d cells assigned across %d regions, %d rects" % [
		_count_assigned(), regions.size(), rects.size()
	])


func region_at_cell(cell: Vector2i) -> MapRegion:
	if grid == null or not grid.in_bounds(cell):
		return null
	if cell_region.size() != grid.cell_count():
		return null
	var idx := cell_region[cell.y * grid.width + cell.x]
	if idx < 0 or idx >= regions.size():
		return null
	return regions[idx]


func region_at_world(p: Vector3) -> MapRegion:
	if grid == null:
		return null
	return region_at_cell(grid.world_to_cell(p))


func _count_assigned() -> int:
	var c := 0
	for v in cell_region:
		if v >= 0:
			c += 1
	return c
