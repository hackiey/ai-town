@tool
class_name LocationMarker
extends Marker3D

# 一个 location 的 prefab 根：Marker3D + 视觉小球 + 名字 Label3D。
# Visual 既在编辑器也在运行时显示（替代 town_world 之前 runtime 叠的 DebugVisual）。
# @tool 让 EditorLabel 在编辑器里跟 name 同步；运行时 name 通常不变，sync 也无害。
# 仍然是 Marker3D，TownWorld._rebuild_anchor_index 自动识别为 location。

const EDITOR_LABEL := "EditorLabel"
const EDITOR_VISUAL := "EditorVisual"

# 留空 → 用 node name 作为 location id；
# 设了 → alias 到这个 id（多个 marker 同 id 会变成同一 location 的多个 anchor，
# get_nearest_position_world 自动挑最近的）。典型用法：market_square 有东西两个入口。
@export var location_id: String = ""

# 归属 group。控制 agent 能否看见此 location 作为可前往目的地。
# 解析规则（在 TownWorld._register_location_tree 里）：
#   ""        → 继承父 marker 的 effective owner_group；root 为空 = public
#   "public"  → 显式公用，覆盖父继承（让私有园子里的某个公共节点可见）
#   其他字符串 → 该 group 名（如 "greystone_farmstead"）
# 仅 "god" group 的 agent 不受过滤，看见所有 location（开发期玩家走这个）。
@export var owner_group: String = ""

# 运行时是否隐藏 EditorVisual/EditorLabel。waypoint 这种纯导航辅助点设 true，
# 编辑器里仍可见方便摆点。
@export var hide_at_runtime: bool = false


func _ready() -> void:
	_sync_label()
	if not renamed.is_connected(_sync_label):
		renamed.connect(_sync_label)
	if hide_at_runtime and not Engine.is_editor_hint():
		var visual := get_node_or_null(EDITOR_VISUAL) as Node3D
		if visual != null:
			visual.visible = false
		var label := get_node_or_null(EDITOR_LABEL) as Node3D
		if label != null:
			label.visible = false


func _sync_label() -> void:
	var label := get_node_or_null(EDITOR_LABEL) as Label3D
	if label != null:
		label.text = String(name)


func effective_id() -> String:
	return location_id if not location_id.is_empty() else String(name)
