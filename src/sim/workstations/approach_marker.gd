@tool
class_name ApproachMarker
extends Marker3D

# 工作台 NPC 接近点的可视化 marker。@tool 模式下在编辑器里给自己挂一个半透明小球
# 方便拖动定位；运行时（非 editor）不生成任何 visual，零开销。
# 临时 visual 节点 owner=null，不会被序列化进 .tscn。

const _SPHERE_RADIUS := 0.25
const _SPHERE_COLOR := Color(0.3, 1.0, 0.4, 0.55)

var _editor_visual: MeshInstance3D


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return
	if _editor_visual != null and is_instance_valid(_editor_visual):
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _SPHERE_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var sphere := SphereMesh.new()
	sphere.radius = _SPHERE_RADIUS
	sphere.height = _SPHERE_RADIUS * 2.0
	_editor_visual = MeshInstance3D.new()
	_editor_visual.mesh = sphere
	_editor_visual.material_override = mat
	add_child(_editor_visual)
	# 不 set_owner —— Godot 只序列化 owner 指向场景根的子节点，留 null 就不写入 .tscn。


func _exit_tree() -> void:
	if _editor_visual != null and is_instance_valid(_editor_visual):
		_editor_visual.queue_free()
		_editor_visual = null
