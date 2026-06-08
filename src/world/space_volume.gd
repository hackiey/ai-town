@tool
class_name SpaceVolume
extends Area3D

# 室内 / 室外空间分区。用来判断视觉 / 听觉 / 交互是否跨空间传播。
#
# 第一版规则（固定、简单，不做门窗 / 弱传播 / Portal）：
#   同一个 space_id              → 按距离判断
#   不同 space_id，双方都 outdoor → 按距离判断
#   不同 space_id，任一方 indoor  → 不可见、不可听
#
# SpaceVolume 挂在「地点 SiteMarker」下作为子节点：这块体积 = 那个地点的 space，
# space 标识 = 所属 WorldObjectIdentity.object_id。室外很大不框，
# 没被任何体积框住的点 = town_outdoor（唯一兜底）。
# TownWorld boot 时收集所有 SpaceVolume，按 contains_point() 给 site / actor / 地上物品
# 归属 space。遮挡判断是 Godot 权威，backend 不复算。

const FALLBACK_SPACE_ID := "town_outdoor"

@export_enum("outdoor", "indoor") var environment: String = "indoor"

# 第一版：indoor 默认两个都 true，outdoor 都 false。留 export 以便个别 space 调。
@export var blocks_vision_to_other_spaces: bool = true
@export var blocks_speech_to_other_spaces: bool = true

# 可选：覆盖本空间内 site 的默认可见半径（留 <= 0 = 不覆盖）。
@export var default_visible_near_radius: float = 0.0
@export var default_visible_far_radius: float = 0.0


# space 标识 = 所属 WorldObjectIdentity.object_id（这块体积属于那个地点）。
# 没挂在 SiteMarker 下 = 配置错误，fail-loud。
func effective_space_id() -> String:
	var parent := get_parent() as SiteMarker
	if parent == null:
		push_error("[SpaceVolume %s] 必须挂在地点 SiteMarker 之下（space=该地点 object_id）" % [name])
		return FALLBACK_SPACE_ID
	var identity := WorldObjectIdentity.for_node(parent)
	if identity == null or identity.effective_object_id().is_empty():
		push_error("[SpaceVolume %s] 所属地点缺 WorldObjectIdentity.object_id" % [name])
		return FALLBACK_SPACE_ID
	return identity.effective_object_id()


func is_indoor() -> bool:
	return environment == "indoor"


# 点是否落在本 volume 的任一 CollisionShape 内。用本地坐标 + Shape3D 近似（box/sphere）。
func contains_point(world_point: Vector3) -> bool:
	for child in get_children():
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var local := cs.global_transform.affine_inverse() * world_point
		var shape := cs.shape
		if shape is BoxShape3D:
			var ext: Vector3 = (shape as BoxShape3D).size * 0.5
			if abs(local.x) <= ext.x and abs(local.y) <= ext.y and abs(local.z) <= ext.z:
				return true
		elif shape is SphereShape3D:
			if local.length() <= (shape as SphereShape3D).radius:
				return true
		elif shape is CylinderShape3D:
			var cyl := shape as CylinderShape3D
			if abs(local.y) <= cyl.height * 0.5 and Vector2(local.x, local.z).length() <= cyl.radius:
				return true
	return false


func to_space_record() -> Dictionary:
	return {
		"id": effective_space_id(),
		"environment": environment,
		"blocksVisionToOtherSpaces": blocks_vision_to_other_spaces,
		"blocksSpeechToOtherSpaces": blocks_speech_to_other_spaces,
		"defaultVisibleNearRadius": default_visible_near_radius,
		"defaultVisibleFarRadius": default_visible_far_radius,
	}


# ─── 跨空间传播规则（静态，operate on space record dicts）───────────────
# channel: "vision" | "speech"。两个 space 任一为 null 时按 outdoor 兜底。
static func can_propagate(from_space: Dictionary, to_space: Dictionary, channel: String) -> bool:
	var from_id: String = String(from_space.get("id", FALLBACK_SPACE_ID))
	var to_id: String = String(to_space.get("id", FALLBACK_SPACE_ID))
	if from_id == to_id:
		return true
	var block_key := "blocksVisionToOtherSpaces" if channel == "vision" else "blocksSpeechToOtherSpaces"
	# 任一方声明遮挡该 channel，或任一方为 indoor，则不跨空间传播。
	if bool(from_space.get(block_key, true)) or bool(to_space.get(block_key, true)):
		return false
	if String(from_space.get("environment", "indoor")) == "indoor":
		return false
	if String(to_space.get("environment", "indoor")) == "indoor":
		return false
	return true
