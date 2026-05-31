@tool
class_name MapRegion
extends Resource

@export var id: String = ""
@export var display_name: String = ""
@export var color: Color = Color(1, 1, 1, 0.25)
@export var parent_id: String = ""   # 树结构占位；v1 全部 leaf
