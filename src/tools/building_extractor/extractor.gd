@tool
class_name BuildingExtractor
extends Node

# 从一个 demo 场景里把所有名字以 node_prefix 开头的顶层 Node3D 子节点
# 各自打包为独立 PackedScene 文件（一栋 = 一个 .tscn），方便复用。
#
# 典型用例：FK 的 Demo_Layout_Houses_With_Interiors.tscn → 30 栋可进房 prefab。
#
# 注意：每个 prefab 的 root transform 会被清零（identity），子节点保持原 local 坐标。
# 也就是 prefab 的"原点"位于 demo 中艺术家放置该 group 的 pivot 处。

@export var source_demo: PackedScene
@export_dir var output_dir: String = "res://assets/buildings"
@export var node_prefix: String = "Preset_"
@export var lowercase_output: bool = true

@export_tool_button("Extract", "Save") var extract_action = extract


func extract() -> void:
	if source_demo == null:
		push_error("[BuildingExtractor] source_demo is required"); return
	if output_dir.is_empty():
		push_error("[BuildingExtractor] output_dir is required"); return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))

	var inst := source_demo.instantiate()
	if inst == null:
		push_error("[BuildingExtractor] failed to instantiate source_demo"); return

	var ok := 0
	var skipped := 0

	# 复制一份子节点列表（边遍历边 reparent 会乱）
	var candidates: Array = []
	for child in inst.get_children():
		if child is Node3D and child.name.begins_with(node_prefix):
			candidates.append(child)

	for child in candidates:
		var bare_name: String = String(child.name).substr(node_prefix.length())
		if bare_name.is_empty():
			push_warning("[BuildingExtractor] empty name after prefix strip on %s, skipped" % child.name)
			skipped += 1
			continue
		var file_name := bare_name.to_lower() if lowercase_output else bare_name
		var out_path := "%s/%s.tscn" % [output_dir.rstrip("/"), file_name]

		# 把 child 从 inst 摘下来，作为独立 root；递归把 owner 设成 child（pack 必须）
		inst.remove_child(child)
		(child as Node3D).transform = Transform3D.IDENTITY
		_reassign_owners(child, child)

		var packed := PackedScene.new()
		var pack_err := packed.pack(child)
		if pack_err != OK:
			push_error("[BuildingExtractor] pack failed for %s: %d" % [child.name, pack_err])
			child.queue_free()
			skipped += 1
			continue

		var save_err := ResourceSaver.save(packed, out_path)
		if save_err != OK:
			push_error("[BuildingExtractor] save failed for %s -> %s: %d" % [child.name, out_path, save_err])
			child.queue_free()
			skipped += 1
			continue

		print("[BuildingExtractor] %s -> %s (%d nodes)" % [child.name, out_path, _count_descendants(child) + 1])
		child.queue_free()
		ok += 1

	inst.queue_free()
	print("[BuildingExtractor] done: %d extracted, %d skipped" % [ok, skipped])

	# 触发编辑器 FileSystem 刷新（@tool 上下文里 EditorInterface 可用）
	if Engine.is_editor_hint():
		var ep := Engine.get_singleton("EditorInterface")
		if ep != null and ep.has_method("get_resource_filesystem"):
			ep.get_resource_filesystem().scan()


# 递归把 sub-tree 里所有节点的 owner 设成 new_root（pack 的硬性要求：
# 只有 owner == 根的节点会被 pack 包含进去）。
# 关键：碰到 instance 子节点（scene_file_path 非空）时停止递归——
# instance 的内部节点（MeshCollider、CollisionShape3D 等）是 prefab 自带的，
# 不能当成"我新加的节点"再 pack 一遍，否则加载时跟 instance 自带的撞名。
static func _reassign_owners(node: Node, new_root: Node) -> void:
	for child in node.get_children():
		child.owner = new_root
		if child.scene_file_path.is_empty():
			_reassign_owners(child, new_root)


static func _count_descendants(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		n += 1 + _count_descendants(child)
	return n
