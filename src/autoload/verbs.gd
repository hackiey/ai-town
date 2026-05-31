extends Node

# Verb registry. 设计：docs/architecture/reaction-schema.md §2.2 / §10

const _DIR := "res://data/verbs"

var _by_id: Dictionary = {}   # id → Verb


func _init() -> void:
	var dir := DirAccess.open(_DIR)
	if dir == null:
		push_error("Verbs: 目录不存在 %s" % _DIR)
		assert(false)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".tres"):
			var path := "%s/%s" % [_DIR, name]
			var res := load(path)
			if not (res is Verb):
				push_error("Verbs: %s 不是 Verb 实例" % path)
				assert(false)
			else:
				var v: Verb = res
				if v.id == "":
					push_error("Verbs: %s 的 id 为空" % path)
					assert(false)
				if _by_id.has(v.id):
					push_error("Verbs: id 重复 %s" % v.id)
					assert(false)
				_by_id[v.id] = v
		name = dir.get_next()
	dir.list_dir_end()


func by_id(id: String) -> Verb:
	return _by_id.get(id)


func has_id(id: String) -> bool:
	return _by_id.has(id)


func all_ids() -> Array:
	return _by_id.keys()
