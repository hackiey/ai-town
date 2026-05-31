@tool
class_name MapGrid
extends Resource

# 世界 → 格子坐标系。原点 (origin) 是格子 (0,0) 在世界空间的角点。
# Y 轴不参与（地形高度后续单算）。

@export var origin: Vector3 = Vector3(-40.0, 0.0, -40.0)
@export var cell_size: float = 1.0
@export var width: int = 80   # X 方向 cell 数
@export var depth: int = 80   # Z 方向 cell 数


func cell_count() -> int:
	return width * depth


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < width and cell.y >= 0 and cell.y < depth


func world_to_cell(p: Vector3) -> Vector2i:
	var local := p - origin
	return Vector2i(int(floor(local.x / cell_size)), int(floor(local.z / cell_size)))


func cell_to_world_center(cell: Vector2i) -> Vector3:
	return origin + Vector3(
		(float(cell.x) + 0.5) * cell_size,
		0.0,
		(float(cell.y) + 0.5) * cell_size
	)


func cell_to_world_corner(cell: Vector2i) -> Vector3:
	return origin + Vector3(float(cell.x) * cell_size, 0.0, float(cell.y) * cell_size)


func cell_index(cell: Vector2i) -> int:
	return cell.y * width + cell.x
