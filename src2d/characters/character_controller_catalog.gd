class_name CharacterControllerCatalog
extends RefCounted

const TYPE_NONE := "none"
const TYPE_PLAYER := "player"
const TYPE_AI := "ai"

const BEHAVIOR_IDLE := "idle"
const BEHAVIOR_WANDER := "wander"

const MIN_MOVE_SPEED := 30.0
const MAX_MOVE_SPEED := 480.0
const DEFAULT_PLAYER_SPEED := 220.0
const DEFAULT_AI_SPEED := 90.0
const MIN_WANDER_RADIUS := 1.0
const MAX_WANDER_RADIUS := 24.0
const DEFAULT_WANDER_RADIUS := 4.0

const CONTROLLERS := [
	{
		"id": TYPE_NONE,
		"name": "静态人物",
		"description": "只播放配置的动作，不读取输入也不主动移动。",
	},
	{
		"id": TYPE_PLAYER,
		"name": "Player Controller",
		"description": "由方向键或 WASD 控制；一个地图只能有一个玩家人物。",
	},
	{
		"id": TYPE_AI,
		"name": "AI Controller",
		"description": "由运行时行为控制，可原地活动或在出生点附近漫游。",
	},
]

const AI_BEHAVIORS := [
	{"id": BEHAVIOR_IDLE, "name": "原地活动"},
	{"id": BEHAVIOR_WANDER, "name": "区域漫游"},
]


static func controllers() -> Array:
	return CONTROLLERS.duplicate(true)


static func ai_behaviors() -> Array:
	return AI_BEHAVIORS.duplicate(true)


static func controller(controller_type: String) -> Dictionary:
	var normalized := normalize_type(controller_type)
	for value in CONTROLLERS:
		if str(value.get("id", "")) == normalized:
			return value.duplicate(true)
	return CONTROLLERS[0].duplicate(true)


static func normalize_type(value: String) -> String:
	return value if value in [TYPE_NONE, TYPE_PLAYER, TYPE_AI] else TYPE_NONE


static func normalize_ai_behavior(value: String) -> String:
	return value if value in [BEHAVIOR_IDLE, BEHAVIOR_WANDER] else BEHAVIOR_IDLE


static func default_move_speed(controller_type: String) -> float:
	return DEFAULT_PLAYER_SPEED if normalize_type(controller_type) == TYPE_PLAYER else DEFAULT_AI_SPEED


static func normalize_controller(value: Variant) -> Dictionary:
	var source: Dictionary = value if value is Dictionary else {}
	var controller_type := normalize_type(str(source.get("type", value if value is String else TYPE_NONE)))
	return {
		"type": controller_type,
		"move_speed": clampf(float(source.get("move_speed", default_move_speed(controller_type))), MIN_MOVE_SPEED, MAX_MOVE_SPEED),
		"behavior": normalize_ai_behavior(str(source.get("behavior", BEHAVIOR_IDLE))),
		"wander_radius": clampf(float(source.get("wander_radius", DEFAULT_WANDER_RADIUS)), MIN_WANDER_RADIUS, MAX_WANDER_RADIUS),
	}
