extends Node

# Materials registry。启动时扫 data/materials/*.tres，校验是 Substance 实例 → 缓存按 id。
# 注：autoload 名（Materials）匹配 schema doc 用语；类名（Substance）因 Godot 引擎占用 Material。
# 设计：docs/architecture/reaction-schema.md §2.1 / §10

const _DIR := "res://data/materials"

var _by_id: Dictionary = {}    # id → Substance


func _init() -> void:
	var dir := DirAccess.open(_DIR)
	if dir == null:
		push_error("Materials: 目录不存在 %s" % _DIR)
		assert(false)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".tres"):
			var path := "%s/%s" % [_DIR, name]
			var res := load(path)
			if not (res is Substance):
				push_error("Materials: %s 不是 Substance 实例（实际：%s）" % [path, res])
				assert(false)
			else:
				var mat: Substance = res
				if mat.id == "":
					push_error("Materials: %s 的 id 为空" % path)
					assert(false)
				if _by_id.has(mat.id):
					push_error("Materials: id 重复 %s（来自 %s）" % [mat.id, path])
					assert(false)
				_by_id[mat.id] = mat
		name = dir.get_next()
	dir.list_dir_end()


func by_id(id: String) -> Substance:
	return _by_id.get(id)


func has_id(id: String) -> bool:
	return _by_id.has(id)


func all_ids() -> Array:
	return _by_id.keys()
