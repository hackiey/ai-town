extends Node

# Shape registry. 设计：docs/architecture/reaction-schema.md §9.3 / §10

const _DIR := "res://data/shapes"

var _by_type: Dictionary = {}   # type → Shape


func _init() -> void:
	var dir := DirAccess.open(_DIR)
	if dir == null:
		push_error("Shapes: 目录不存在 %s" % _DIR)
		assert(false)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".tres"):
			var path := "%s/%s" % [_DIR, name]
			var res := load(path)
			if not (res is Shape):
				push_error("Shapes: %s 不是 Shape 实例" % path)
				assert(false)
			else:
				var s: Shape = res
				if s.type == "":
					push_error("Shapes: %s 的 type 为空" % path)
					assert(false)
				if _by_type.has(s.type):
					push_error("Shapes: type 重复 %s" % s.type)
					assert(false)
				_by_type[s.type] = s
		name = dir.get_next()
	dir.list_dir_end()


func by_type(type: String) -> Shape:
	return _by_type.get(type)


func has_type(type: String) -> bool:
	return _by_type.has(type)


func all_types() -> Array:
	return _by_type.keys()
