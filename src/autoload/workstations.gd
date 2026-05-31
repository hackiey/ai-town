extends Node

# Workstation registry（Resource 类型，不是场景里的 Node3D）。
# 设计：docs/architecture/reaction-schema.md §2.2 / §10
# 区别于 src/sim/workstations/workstation_node.gd（场景实例）。

const _DIR := "res://data/workstations"

var _by_id: Dictionary = {}   # id → Workstation


func _init() -> void:
	var dir := DirAccess.open(_DIR)
	if dir == null:
		push_error("Workstations: 目录不存在 %s" % _DIR)
		assert(false)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".tres"):
			var path := "%s/%s" % [_DIR, name]
			var res := load(path)
			if not (res is Workstation):
				push_error("Workstations: %s 不是 Workstation 实例" % path)
				assert(false)
			else:
				var w: Workstation = res
				if w.id == "":
					push_error("Workstations: %s 的 id 为空" % path)
					assert(false)
				if _by_id.has(w.id):
					push_error("Workstations: id 重复 %s" % w.id)
					assert(false)
				_by_id[w.id] = w
		name = dir.get_next()
	dir.list_dir_end()


func by_id(id: String) -> Workstation:
	return _by_id.get(id)


func has_id(id: String) -> bool:
	return _by_id.has(id)


func all_ids() -> Array:
	return _by_id.keys()
