class_name CharacterActionCatalog
extends RefCounted

const ACTIONS := [
	{"id": "idle", "name": "待机", "fps": 1.0, "sequence": [1], "effect": "none", "native": true, "description": "使用素材原生待机帧。"},
	{"id": "walk", "name": "行走", "fps": 7.0, "sequence": [0, 1, 2, 1], "effect": "none", "native": true, "description": "使用素材原生左右步循环。"},
	{"id": "guard", "name": "警戒", "fps": 3.5, "sequence": [1, 0, 1, 2], "effect": "guard", "native": false, "description": "原地换重心，表现巡逻或站岗。"},
	{"id": "forge", "name": "锻造", "fps": 5.0, "sequence": [1, 2, 1, 0], "effect": "forge", "native": false, "description": "快速俯身与摆动，表现敲打和制作。"},
	{"id": "gather", "name": "采集", "fps": 4.0, "sequence": [1, 0, 1, 2], "effect": "gather", "native": false, "description": "俯身循环，表现采摘、搜寻或整理。"},
	{"id": "attack", "name": "攻击", "fps": 8.0, "sequence": [1, 2, 1, 0], "effect": "attack", "native": false, "description": "沿朝向短促突进；当前素材没有独立攻击帧。"},
	{"id": "cast", "name": "施法", "fps": 4.5, "sequence": [1, 0, 1, 2], "effect": "cast", "native": false, "description": "发光脉冲与姿态循环；当前素材没有独立施法帧。"},
	{"id": "brew", "name": "炼制", "fps": 3.5, "sequence": [1, 0, 1, 2], "effect": "brew", "native": false, "description": "小幅摆动，表现调配药剂或烹制。"},
	{"id": "pray", "name": "祈祷", "fps": 2.0, "sequence": [1], "effect": "pray", "native": false, "description": "缓慢呼吸与暖色脉冲。"},
	{"id": "trade", "name": "交易", "fps": 3.0, "sequence": [1, 0, 1, 2], "effect": "trade", "native": false, "description": "轻微点头，表现招呼与交易。"},
	{"id": "perform", "name": "表演", "fps": 6.0, "sequence": [0, 1, 2, 1], "effect": "perform", "native": false, "description": "跳动和摇摆，表现演奏或舞台动作。"},
	{"id": "talk", "name": "交谈", "fps": 2.5, "sequence": [1, 0, 1, 2], "effect": "talk", "native": false, "description": "轻微上下移动，表现对话。"},
]

const DIRECTIONS := [
	{"id": "down", "name": "正面", "row": 0},
	{"id": "left", "name": "左侧", "row": 1},
	{"id": "right", "name": "右侧", "row": 2},
	{"id": "up", "name": "背面", "row": 3},
]


static func actions() -> Array:
	return ACTIONS.duplicate(true)


static func action(action_id: String) -> Dictionary:
	for action_value in ACTIONS:
		if str(action_value.get("id", "")) == action_id:
			return action_value.duplicate(true)
	return ACTIONS[0].duplicate(true)


static func has_action(action_id: String) -> bool:
	for action_value in ACTIONS:
		if str(action_value.get("id", "")) == action_id:
			return true
	return false


static func normalize_action(action_id: String, fallback := "idle") -> String:
	if has_action(action_id):
		return action_id
	return fallback if has_action(fallback) else "idle"


static func normalize_actions(actions_value: Variant, default_action := "idle") -> Array:
	var normalized: Array = []
	if actions_value is Array:
		for action_id_value in actions_value:
			var action_id := str(action_id_value)
			if has_action(action_id) and not action_id in normalized:
				normalized.append(action_id)
	if normalized.is_empty():
		for action_value in ACTIONS:
			normalized.append(str(action_value.get("id", "")))
	var normalized_default := normalize_action(default_action)
	if not normalized_default in normalized:
		normalized.append(normalized_default)
	return normalized


static func directions() -> Array:
	return DIRECTIONS.duplicate(true)


static func normalize_direction(direction_id: String) -> String:
	for direction_value in DIRECTIONS:
		if str(direction_value.get("id", "")) == direction_id:
			return direction_id
	return "down"


static func direction_row(direction_id: String) -> int:
	var normalized := normalize_direction(direction_id)
	for direction_value in DIRECTIONS:
		if str(direction_value.get("id", "")) == normalized:
			return int(direction_value.get("row", 0))
	return 0


static func direction_id(row: int) -> String:
	var normalized_row := clampi(row, 0, DIRECTIONS.size() - 1)
	return str(DIRECTIONS[normalized_row].get("id", "down"))
