@tool
class_name RegionRect
extends Resource

# 把一片矩形 cell 范围归给某 region。min/max 包含端点（cell 坐标）。
# 如果多个 rect 覆盖同一 cell，后写入的覆盖先前的（bake 顺序）。

@export var region_id: String = ""
@export var min: Vector2i = Vector2i.ZERO
@export var max: Vector2i = Vector2i.ZERO
