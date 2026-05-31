extends Node

var _flags: Dictionary = {}


func set_flag(key: StringName, value: Variant) -> void:
	var old = _flags.get(key)
	if old == value:
		return
	_flags[key] = value
	EventBus.flag_changed.emit(key, value)


func get_flag(key: StringName, default: Variant = null) -> Variant:
	return _flags.get(key, default)


func has_flag(key: StringName) -> bool:
	return _flags.has(key)


func get_bool(key: StringName) -> bool:
	return bool(_flags.get(key, false))


func get_int(key: StringName, default: int = 0) -> int:
	return int(_flags.get(key, default))


func increment(key: StringName, by: int = 1) -> int:
	var next := get_int(key) + by
	set_flag(key, next)
	return next


func erase(key: StringName) -> void:
	if _flags.erase(key):
		EventBus.flag_changed.emit(key, null)


func clear() -> void:
	_flags.clear()


func to_dict() -> Dictionary:
	return _flags.duplicate(true)


func from_dict(data: Dictionary) -> void:
	_flags = data.duplicate(true)
