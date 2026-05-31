class_name CameraRig
extends Node3D

# 标准第三人称 orbit 相机。
#
# 设计原则（Cinemachine / SpringArmComponent 同款）：
# 1. **锚点 = 视觉稳定节点，不是物理身体**。set_target(target, anchor_source) 的
#    anchor_source 推荐顺序：
#      a. BoneAttachment3D（挂 spine/hip 骨）—— 动画插值天然平滑
#      b. Visual 子节点（带 _update_client_visual_smoothing 的兜底平滑）
#      c. 不传 → 用 target 自己（物理 CharacterBody3D，会有 floor_snap 微抖）
# 2. **Orbit 角度是独立状态**。_yaw 由鼠标右键 X 轴累加，_pitch 锁死在 pitch_degrees
#    （本游戏只允许左右环绕，俯视角由设计师固定）；相机朝向**直接由 yaw/pitch
#    算出 basis**，不用 look_at。look_at 会把位置噪声放大成角度噪声
#    （7m 远 × 2cm 抖 → 0.16° 旋转抖），自己出 basis 完全切断这条路径。
# 3. **帧率无关指数衰减**：`alpha = 1 - exp(-damping * delta)`；damping 单位 1/秒，
#    half_life ≈ 0.693 / damping。60fps 和 144fps 收敛速度完全一致。
# 4. **Per-axis damping**：XZ 快、Y 慢、yaw/pitch 不平滑（输入要立刻响应）。Y 慢
#    是吃地形起伏 / 跳跃 / step-up 等垂直噪声的标准答案。
# 5. **Distance 不对称 + dead-zone**：碰撞瞬时硬切防穿墙；空间打开慢慢拉回；
#    |cast - current| < dead_zone 完全忽略，吃掉 spring cast 的 cm 级噪声。
#
# 节点层级（在 town.tscn 里布好）：
#   CameraRig (Node3D)             ← 每帧把 transform 摆成"相机姿态 @ anchor"
#    ├── SpringArm3D                ← 仅 cast 用；local = identity，跟随 rig 旋转
#    └── Camera3D                   ← local position = (0, 0, _current_distance)
#                                     Camera 默认朝 -Z 看，正好看回 rig 原点 (=anchor)

@export var target_path: NodePath

# ── Anchor / orbit ──────────────────────────────────────────
## Anchor 在 anchor_source 上方的高度（米）。anchor_source 已经是头部骨骼时设 0。
@export var anchor_height: float = 1.28
## 想要的镜头距离（米）。
@export var desired_distance: float = 7.0
## 固定 pitch（度，正 = 俯视）。本相机只允许左右 orbit；上下角度由设计师锁死。
@export_range(-89.0, 89.0) var pitch_degrees: float = 38.0
## 右键拖拽灵敏度（弧度/像素）。
@export var orbit_sensitivity: float = 0.006

# ── 平滑（damping 单位 1/秒，值越大越快收敛）────────────────
## XZ 跟随。10 ≈ 70ms half-life。
@export var damping_xz: float = 10.0
## Y 跟随。低值 = 镜头不被地形微起伏带着抖。4 ≈ 170ms half-life。
@export var damping_y: float = 4.0
## 无碰撞时距离拉回的衰减。
@export var distance_return_damping: float = 5.0
## 距离变化死区（米）。|cast - current| < dead_zone 完全不动；吃 cm 级 cast 噪声。
@export var distance_dead_zone: float = 0.08

# ── SpringArm ───────────────────────────────────────────────
@export var spring_margin: float = 0.15
## Sphere cast 替代 raycast：sharp 法线（墙角/柱子）上 raycast 命中点抖，球体滑过去稳。
@export var spring_probe_radius: float = 0.25
@export_flags_3d_physics var collision_mask: int = 1

# ── 点地派 NPC ──────────────────────────────────────────────
@export var click_to_move: bool = true
## 左键射线只命中可点地面层，不含 layer 16（no-nav 地面）。
@export_flags_3d_physics var click_collision_mask: int = 9
## 第一命中在这些层就吞掉点击（用于 no-nav/no-click 地面，避免穿透到下层地形）。
@export_flags_3d_physics var click_blocking_mask: int = 16
@export var click_debug_log: bool = true

# ── NPC 右键菜单 ────────────────────────────────────────────
## NPC 身体所在的物理层（跟 NpcHoverStatus.NPC_COLLISION_MASK 同源）。
@export_flags_3d_physics var npc_pick_mask: int = 2

@onready var _spring: SpringArm3D = $SpringArm3D
@onready var _camera: Camera3D = $Camera3D

var _target: Node3D
var _anchor_source: Node3D
var _yaw: float = 0.0
var _pitch: float = 0.0
var _smoothed_anchor: Vector3 = Vector3.ZERO
var _current_distance: float = 0.0
var _orbiting: bool = false
# 右键按下时若命中 NPC，本次按下转交菜单，press/release 都不进入 orbit。
var _right_press_consumed_by_menu: bool = false


func _ready() -> void:
	_pitch = deg_to_rad(pitch_degrees)
	_current_distance = desired_distance

	# project.godot 全局开了 common/physics_interpolation。该机制要求 transform 写在
	# _physics_process（60Hz），渲染帧之间引擎自己插值。本 rig 反过来：所有平滑都在
	# _process 里按渲染帧 delta 做（指数衰减），每帧手动 set global_transform。两条
	# 路同时跑时，引擎会把 render-frame 写入当成"两个 physics tick 之间的中间状态"
	# 反过来再插一遍，高刷显示器上表现为环绕镜头不丝滑/采样滞后。rig + spring + camera
	# 全部 opt out，让我们的手动平滑成为唯一插值源。
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_spring.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	# Spring / Camera 都让出 transform 控制权给 rig：spring 用 rig 的 basis 做 cast，
	# camera 沿 rig local +Z（=rig basis.z = "相机身后"方向）摆 distance。
	_spring.transform = Transform3D.IDENTITY
	_spring.spring_length = desired_distance
	_spring.margin = spring_margin
	_spring.collision_mask = collision_mask
	if spring_probe_radius > 0.0:
		var sphere := SphereShape3D.new()
		sphere.radius = spring_probe_radius
		_spring.shape = sphere

	_camera.transform = Transform3D.IDENTITY
	_camera.position = Vector3(0.0, 0.0, _current_distance)

	if not target_path.is_empty():
		var t := get_node_or_null(target_path) as Node3D
		if t != null:
			set_target(t)


# town.gd 在本地 player avatar spawn 后调用。
# anchor_source = 视觉稳定节点（见文件头注释推荐顺序）。不传则退回 target 自己。
func set_target(node: Node3D, anchor_source: Node3D = null) -> void:
	if node == null:
		_target = null
		_anchor_source = null
		return
	if not node.is_inside_tree():
		return
	_target = node
	_anchor_source = anchor_source if anchor_source != null and anchor_source.is_inside_tree() else node
	# 排除 target 自己的 collision，不然 cast 一启动就撞 target → length=0 → 相机卡身体里。
	if _target is CollisionObject3D:
		_spring.add_excluded_object((_target as CollisionObject3D).get_rid())
	var anchor := _raw_anchor()
	_smoothed_anchor = anchor
	_apply_rig_transform(anchor)
	reset_physics_interpolation()


func _process(delta: float) -> void:
	if _target == null:
		return

	# Distance（先读再写）。SpringArm 的 cast 在它自己 _process 跑，我们读的是
	# 上一帧 transform 下的命中长度——1 帧延迟肉眼不可见，比手动 cast_motion 干净。
	var cast_length := _spring.get_hit_length()
	if cast_length < _current_distance - distance_dead_zone:
		_current_distance = cast_length                                    # 硬切防穿墙
	elif cast_length > _current_distance + distance_dead_zone:
		_current_distance = _decay(_current_distance, cast_length,
				distance_return_damping, delta)                            # 慢拉回
	# else: 落在死区里，cast cm 级噪声完全忽略

	# Anchor per-axis 平滑（XZ / Y 分开）
	var target_anchor := _raw_anchor()
	_smoothed_anchor.x = _decay(_smoothed_anchor.x, target_anchor.x, damping_xz, delta)
	_smoothed_anchor.z = _decay(_smoothed_anchor.z, target_anchor.z, damping_xz, delta)
	_smoothed_anchor.y = _decay(_smoothed_anchor.y, target_anchor.y, damping_y,  delta)

	_apply_rig_transform(_smoothed_anchor)
	_camera.position = Vector3(0.0, 0.0, _current_distance)
	_spring.spring_length = desired_distance


# rig transform 表达 "相机姿态在 anchor 处"。Camera3D 沿 local +Z 摆 distance 米
# = anchor 身后 distance 米；Camera 默认朝 -Z 看，正好对回 anchor。
func _apply_rig_transform(anchor: Vector3) -> void:
	global_transform = Transform3D(_camera_basis(), anchor)


func _camera_basis() -> Basis:
	# yaw 绕 Y，pitch 锁死。pitch 取负是因为正 pitch_degrees 我们想表示"俯视"
	# （相机在上方往下看），而 Basis(RIGHT, +x) 是 anchor 抬头方向。
	return Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, -_pitch)


# anchor_source 一般是 Visual / BoneAttachment：transform 在物理 tick 离散更新，
# 靠 Godot physics_interpolation 在渲染帧之间插值。
func _raw_anchor() -> Vector3:
	return _anchor_source.get_global_transform_interpolated().origin + Vector3(0.0, anchor_height, 0.0)


# 帧率无关指数衰减：alpha = 1 - exp(-damping*delta)
# half_life ≈ 0.693 / damping（秒）
static func _decay(current: float, target: float, damping: float, delta: float) -> float:
	if damping <= 0.0:
		return target
	return lerpf(current, target, 1.0 - exp(-damping * delta))


func _unhandled_input(event: InputEvent) -> void:
	if _target == null:
		return

	# 右键按住进入 orbit；松开退出。例外：press 时鼠标下有 NPC → 转交菜单，
	# press/release 这一对都不进 orbit。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			var npc := _pick_npc_under(mb.position)
			if npc != null:
				_right_press_consumed_by_menu = true
				EventBus.npc_context_menu_requested.emit(npc, mb.position)
				get_viewport().set_input_as_handled()
				return
			_orbiting = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		# release
		if _right_press_consumed_by_menu:
			_right_press_consumed_by_menu = false
			get_viewport().set_input_as_handled()
			return
		_orbiting = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	# Orbit 只接受水平方向：yaw 跟手累加，pitch 锁死在 pitch_degrees。
	if _orbiting and event is InputEventMouseMotion:
		_yaw -= (event as InputEventMouseMotion).relative.x * orbit_sensitivity
		return

	if not click_to_move:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	# 点地派 NPC：射线打地面，把点喊给本地 player avatar 的 RPC。
	var mouse_pos: Vector2 = event.position
	var origin := _camera.project_ray_origin(mouse_pos)
	var dir := _camera.project_ray_normal(mouse_pos)
	var space := get_world_3d().direct_space_state
	var exclude := [_target.get_rid()] if _target is CollisionObject3D else []
	var first_query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 500.0)
	first_query.collision_mask = click_collision_mask | click_blocking_mask
	first_query.exclude = exclude
	var first_hit := space.intersect_ray(first_query)
	if click_debug_log:
		var any_query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 500.0)
		any_query.collision_mask = 0xFFFFFFFF
		any_query.exclude = exclude
		print("[CameraRig click] any-layer hit: %s" % _describe_ray_hit(space.intersect_ray(any_query)))
		print("[CameraRig click] first relevant hit mask=%d: %s" % [first_query.collision_mask, _describe_ray_hit(first_hit)])
	if _hit_has_layer(first_hit, click_blocking_mask):
		if click_debug_log:
			print("[CameraRig click] blocked by click_blocking_mask=%d" % click_blocking_mask)
		return
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 500.0)
	query.collision_mask = click_collision_mask
	query.exclude = exclude
	var hit := space.intersect_ray(query)
	if click_debug_log:
		print("[CameraRig click] filtered hit mask=%d: %s" % [click_collision_mask, _describe_ray_hit(hit)])
	if hit.is_empty():
		return
	var hit_pos := hit.position as Vector3
	# 玩家点地面 → 喊给 godot server："我想去这里"。Server 校验、跑 nav、
	# 用 MultiplayerSynchronizer 把新位置回推给所有 client。完全不经过 backend。
	if not _target.has_method("request_move_to"):
		push_warning("[CameraRig] target lacks request_move_to RPC")
		return
	_target.request_move_to.rpc_id(1, hit_pos, _ray_hit_info(hit))


# 鼠标位置往世界打射线，命中 NPC 身体 → 顺着父链找 Character in "npcs" 组。
# 参考 NpcHoverStatus._pick_hovered_npc 同款实现。
func _pick_npc_under(mouse_pos: Vector2) -> Character:
	var world := get_world_3d()
	if world == null:
		return null
	var origin := _camera.project_ray_origin(mouse_pos)
	var dir := _camera.project_ray_normal(mouse_pos)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	query.collision_mask = npc_pick_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var node: Node = hit.get("collider", null) as Node
	while node != null:
		if node is Character and node.is_in_group("npcs"):
			return node as Character
		node = node.get_parent()
	return null


func _describe_ray_hit(hit: Dictionary) -> String:
	if hit.is_empty():
		return "<none>"
	var collider: Object = hit.get("collider") as Object
	var collider_text := str(collider)
	var layer := -1
	if collider is Node:
		collider_text = (collider as Node).get_path()
	if collider is CollisionObject3D:
		layer = (collider as CollisionObject3D).collision_layer
	return "%s layer=%d pos=%s" % [collider_text, layer, str(hit.get("position", Vector3.ZERO))]


func _hit_has_layer(hit: Dictionary, mask: int) -> bool:
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider") as Object
	if not (collider is CollisionObject3D):
		return false
	return (((collider as CollisionObject3D).collision_layer) & mask) != 0


func _ray_hit_info(hit: Dictionary) -> Dictionary:
	if hit.is_empty():
		return {"hit": false}
	var collider: Object = hit.get("collider") as Object
	var collider_path := str(collider)
	var layer := -1
	if collider is Node:
		collider_path = str((collider as Node).get_path())
	if collider is CollisionObject3D:
		layer = (collider as CollisionObject3D).collision_layer
	var position: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
	return {
		"hit": true,
		"path": collider_path,
		"layer": layer,
		"position": position,
	}
