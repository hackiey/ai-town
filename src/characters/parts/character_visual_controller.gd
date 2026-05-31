class_name CharacterVisualController
extends RefCounted

# 视觉模型平滑：每帧把渲染 Visual node 按指数衰减跟到逻辑根节点位置。
#
# 为什么必须平滑：
# - Server / host：step-assist 瞬时抬腿 + floor_snap 紧贴起伏地形会让根节点 Y 高频跳，
#   名字和相机直接读根节点位置就跟着抖。
# - Client puppet：MultiplayerSynchronizer 包到达时机不是渲染帧等距，根节点也会跳。
#
# 平滑策略：逻辑根节点仍权威（交互距离 / 同步状态不受污染），渲染、相机、nameplate
# 都跟 _client_visual_node 走。Per-axis 衰减：XZ 跟玩家走位紧，Y 慢吃地形噪声。
#
# 调用：NPC / Player 每帧 _physics_process 末尾调 update_smoothing(visual_node, delta)。
# 字段读 character.client_visual_damping_xz/y / max_offset（@export）。

var _character: Character
var _client_visual_node: Node3D = null
var _client_visual_base_transform: Transform3D = Transform3D.IDENTITY


func _init(owner: Character) -> void:
	_character = owner


func active_visual_node() -> Node3D:
	return _client_visual_node


func update_smoothing(visual_node: Node3D, delta: float) -> void:
	if visual_node == null:
		return
	# 用 is_instance_valid 而不是 `!=` 跟可能为 null 的 typed Object 比较：
	# Godot 4 在 typed Object 变量持 null 时跟非 null Object 做 `!=` 会触发
	# "Invalid operands 'float' and 'Object'" 报错（null Variant 内部转 float）。
	if not is_instance_valid(_client_visual_node) or _client_visual_node.get_instance_id() != visual_node.get_instance_id():
		_client_visual_node = visual_node
		_client_visual_base_transform = visual_node.transform
		# Keep the smoothed render model in world space. If it remains parented to the
		# synced root transform, root rotation updates rotate the smoothing offset and
		# show up as high-frequency jitter while characters move.
		visual_node.set_as_top_level(true)
		visual_node.global_transform = _character.global_transform * _client_visual_base_transform
		visual_node.reset_physics_interpolation()
	var target_transform := _character.global_transform * _client_visual_base_transform
	var target := target_transform.origin
	var current := visual_node.global_position
	var alpha_xz := _exp_decay_alpha(_character.client_visual_damping_xz, delta)
	var alpha_y  := _exp_decay_alpha(_character.client_visual_damping_y,  delta)
	var next := Vector3(
		lerpf(current.x, target.x, alpha_xz),
		lerpf(current.y, target.y, alpha_y),
		lerpf(current.z, target.z, alpha_xz),
	)
	# Max offset clamp：step-assist 等大跳变后 Visual 不能落后超过 max_offset，
	# 否则视觉模型跟交互距离脱节（攻击/对话判定都看 root，模型在视觉上太远会穿帮）。
	var offset := next - target
	var max_offset := maxf(_character.client_visual_max_offset, 0.0)
	if max_offset > 0.0 and offset.length_squared() > max_offset * max_offset:
		next = target + offset.normalized() * max_offset
	target_transform.origin = next
	visual_node.global_transform = target_transform


# alpha = 1 - exp(-damping * delta)，damping ≤ 0 退化为瞬时（无平滑）。
static func _exp_decay_alpha(damping: float, delta: float) -> float:
	if damping <= 0.0:
		return 1.0
	return 1.0 - exp(-damping * delta)
