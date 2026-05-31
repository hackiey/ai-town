@tool
class_name FarmSlot
extends Marker3D

# 一格农田。设计时静态摆放在 town.tscn 里，server / client 同路径，0 同步成本。
# slot 不维护 occupied 引用：server 在 plant / harvest 时按 slot.global_position
# 周围 OCCUPIED_RADIUS 半径查 "crops" group 即可判定占用。这样省去同步状态。
#
# 视觉只是 debug marker：编辑器里永远显示，debug build 运行时默认显示，release build
# 默认隐藏。正式上线前不需要删除 slot，只要保持 release 隐藏即可。

const OCCUPIED_RADIUS := 0.4
const DEBUG_VISUAL := "DebugVisual"
const DEBUG_LABEL := "DebugLabel"

@export var visible_in_debug_builds := true:
	set(value):
		visible_in_debug_builds = value
		_apply_debug_visibility()

@export var visible_in_release_builds := false:
	set(value):
		visible_in_release_builds = value
		_apply_debug_visibility()

@export var show_debug_label := true:
	set(value):
		show_debug_label = value
		_apply_debug_visibility()

var _field_marker_visible := true


func _ready() -> void:
	if not Engine.is_editor_hint():
		add_to_group("farm_slots")
	_sync_label()
	_apply_debug_visibility()
	if not renamed.is_connected(_sync_label):
		renamed.connect(_sync_label)


func set_field_marker_visible(value: bool) -> void:
	_field_marker_visible = value
	_apply_debug_visibility()


func _sync_label() -> void:
	var label := get_node_or_null(DEBUG_LABEL) as Label3D
	if label != null:
		label.text = String(name)


func _apply_debug_visibility() -> void:
	var show_marker := _should_show_debug_marker()
	var visual := get_node_or_null(DEBUG_VISUAL) as MeshInstance3D
	if visual != null:
		visual.visible = show_marker
	var label := get_node_or_null(DEBUG_LABEL) as Label3D
	if label != null:
		label.visible = show_marker and show_debug_label


func _should_show_debug_marker() -> bool:
	if Engine.is_editor_hint():
		return true
	if not _field_marker_visible:
		return false
	return visible_in_debug_builds if OS.is_debug_build() else visible_in_release_builds


# Server 端调：周围 OCCUPIED_RADIUS 内是否已有 Crop。两端 group 都填，
# 但 plant/harvest 业务只在 server 走，client 拿到的判定值不重要。
func is_occupied() -> bool:
	for node in get_tree().get_nodes_in_group("crops"):
		if node is Node3D:
			if (node as Node3D).global_position.distance_to(global_position) <= OCCUPIED_RADIUS:
				return true
	return false
