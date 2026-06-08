@tool
class_name SiteMarker
extends Marker3D

# 世界对象的空间锚点。替代 ApproachMarker。
#
# 一个 SiteMarker 是 NPC 到达点（Marker3D 位置落在 navmesh 上，编辑器可拖），
# 只携带空间半径与可选 Approach。对象身份 / 归属 / 地图 / 能力由 WorldObjectIdentity 维护。
#
# 多锚点：一个 WorldObjectIdentity.object_id 可以注册多个 SiteMarker，形成同一个对象的
# 多个 anchor（6 口共享 "well" 的水井、市集东西入口），导航取离 actor 最近的那个。
#
# 半径字段无默认/兜底：5 个 base 预制件（location_marker / workstation / container / shelf /
# farm_group）显式填好，实例继承；缺值在 _ready fail-loud。
#
# @tool：编辑器里画半透明小球 + name Label3D，方便摆点；运行时 visual 由 site_visible
# 控制（waypoint 这种纯导航点设 false）。

const EDITOR_LABEL := "EditorLabel"
const EDITOR_VISUAL := "EditorVisual"
const APPROACH_CHILD := "Approach"
const _SPHERE_RADIUS := 0.25
const _SPHERE_COLOR := Color(0.3, 1.0, 0.4, 0.55)

# ── 范围（必填；半径无默认/兜底，5 个 base 预制件已显式填好，_ready 校验）────
# direct=0 合法,表示「不可直接交互」(纯地点)；其余三个必须 > 0。
@export_group("范围（必填）")
@export var arrival_radius: float = 0.0
@export var visible_near_radius: float = 0.0
@export var visible_far_radius: float = 0.0
@export var direct_interaction_radius: float = 0.0

# ── 进阶（绝大多数情况留空）────────────────────────────────────────
@export_group("进阶")
# 纯导航点（waypoint）：只提供位置给 LocationGraph 走廊规划，不是 site，不进 sites 表，
# 不需要范围/分区/地图字段 → 跳过 _ready 的 fail-loud 校验。
@export var nav_only: bool = false

# 运行时是否隐藏编辑器 visual / label（纯导航 waypoint 设 false）。
@export var show_visual_at_runtime: bool = false

var _editor_visual: MeshInstance3D


# 读任意实体的"可交互/拾取距离"= 它自己 SiteMarker 组件的 direct radius（逐对象，玩家/NPC 统一）。
# 节点本身是 SiteMarker（纯地点）或带名为 "SiteMarker" 的子组件（工作台/容器/物品/角色…）。
# 没有组件 = fail-loud + fail-closed：报错并返回 0（任何距离判定恒不通过）。一切定位实体都该挂组件。
static func interaction_radius_of(node: Node) -> float:
	var m: SiteMarker = null
	if node is SiteMarker:
		m = node as SiteMarker
	elif node != null:
		m = node.get_node_or_null("SiteMarker") as SiteMarker
	if m == null:
		push_error("[SiteMarker] 节点 %s 没有 SiteMarker 组件，无法判定可交互距离" % [node])
		return 0.0
	return m.eff_direct_interaction_radius()


# eff_* 直返字段（无默认/兜底；值由 5 个 base 预制件显式填、_ready 校验）。保留方法名给调用方。
func eff_visible_near_radius() -> float:
	return visible_near_radius


func eff_visible_far_radius() -> float:
	return visible_far_radius


func eff_direct_interaction_radius() -> float:
	return direct_interaction_radius


func eff_arrival_radius() -> float:
	return arrival_radius


# ── 自身位置 vs 寻路点 ────────────────────────────────────────────────
# 本组件自身的 global_position = 对象自身位置（= 可交互距离基准）。
# 寻路到达点 = 可选的 "Approach" Marker3D；只有大型对象（晾晒架/大柜子等）
# navmesh 上够不到本体时才放。没有就回退到自身位置（小物件直接走到跟前）。
#
# Approach 永远挂在 SiteMarker 自己下面（组件模型：SiteMarker 是位置组件，Approach
# 是它的可选子节点）。纯地点和机制节点（容器/工作台）一视同仁，designer 只在 SiteMarker
# 下拖一个 Approach 即可。
func _approach_node() -> Node3D:
	return get_node_or_null(APPROACH_CHILD) as Node3D


func has_approach() -> bool:
	return _approach_node() != null


func approach_position() -> Vector3:
	var n := _approach_node()
	return n.global_position if n != null else global_position


# 距离判定（纯几何；跨 space 遮挡由 SiteRegistry/SpaceVolume 叠加，不在这里判）。
func is_visible_to(from: Vector3) -> bool:
	return global_position.distance_to(from) <= eff_visible_far_radius()


func visibility_band(from: Vector3) -> String:
	var d := global_position.distance_to(from)
	if d <= eff_direct_interaction_radius() and eff_direct_interaction_radius() > 0.0:
		return "direct"
	if d <= eff_visible_near_radius():
		return "near"
	if d <= eff_visible_far_radius():
		return "far"
	return ""


func is_directly_interactable(from: Vector3) -> bool:
	var r := eff_direct_interaction_radius()
	return r > 0.0 and global_position.distance_to(from) <= r


# 到达 = 走到了寻路目标（approach_position，可选 Approach 子节点，没有则回退自身），
# 不是相对本体 global_position。运行时实际到达走 NavigationAgent 对 approach_position 量，
# 此处与之同基准。
func is_arrived(from: Vector3) -> bool:
	return approach_position().distance_to(from) <= eff_arrival_radius()


func _ready() -> void:
	_sync_label()
	if not renamed.is_connected(_sync_label):
		renamed.connect(_sync_label)
	if not show_visual_at_runtime and not Engine.is_editor_hint():
		# 运行时隐藏编辑器辅助（小球 + label）。waypoint 这种纯导航点保持隐藏；
		# 需要运行时显示的（location debug 球）在节点上设 show_visual_at_runtime=true。
		var visual := get_node_or_null(EDITOR_VISUAL) as Node3D
		if visual != null:
			visual.visible = false
		var label := get_node_or_null(EDITOR_LABEL) as Node3D
		if label != null:
			label.visible = false
	if not Engine.is_editor_hint():
		_validate_fields()
		_validate_approach()


# fail-loud：每个 site 的范围/地图字段必须显式填好（无默认/兜底），缺了立刻暴露。
# 纯导航点 waypoint 不是 site，跳过。
func _validate_fields() -> void:
	if nav_only:
		return
	if visible_near_radius <= 0.0 or visible_far_radius <= 0.0 or arrival_radius <= 0.0:
		push_error("[SiteMarker %s] 范围未填：near=%.2f far=%.2f arrival=%.2f（必须 > 0；在预制件 base 上填）" % [_debug_id(), visible_near_radius, visible_far_radius, arrival_radius])
	if direct_interaction_radius < 0.0:
		push_error("[SiteMarker %s] direct_interaction_radius=%.2f 不能为负（0=不可直接交互）" % [_debug_id(), direct_interaction_radius])


# fail-loud：有 Approach 子节点但落在本对象可交互距离外，NPC 走到了也算不上靠近 → 立刻暴露。
# 用本对象自己的 direct 半径（逐对象）；direct=0（纯地点不可交互）跳过。
func _validate_approach() -> void:
	var n := _approach_node()
	if n == null:
		return
	var r := eff_direct_interaction_radius()
	if r <= 0.0:
		return
	var d := global_position.distance_to(n.global_position)
	if d > r:
		push_error("[SiteMarker %s] Approach 距自身 %.2fm 超出可交互半径 %.2fm；NPC 到达后无法交互，把 Approach 拖近。" % [_debug_id(), d, r])


func _debug_id() -> String:
	var identity := WorldObjectIdentity.for_node(self)
	if identity != null and not identity.effective_object_id().is_empty():
		return identity.effective_object_id()
	return String(name)


func _sync_label() -> void:
	var label := get_node_or_null(EDITOR_LABEL) as Label3D
	if label != null:
		label.text = String(name)


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
	# 不 set_owner —— 留 null 就不会序列化进 .tscn。


func _exit_tree() -> void:
	if _editor_visual != null and is_instance_valid(_editor_visual):
		_editor_visual.queue_free()
		_editor_visual = null
