class_name ContainerNode
extends WorkstationNode

# 容器节点 = WorkstationNode 的子类型。继承 proximity / approach / lock。
# 额外语义：slot 库存（持久化在 Containers autoload + DB），交互模式 "container"
# 触发独立 inventory UI 而不是 ActionPanel slot grid。

# 容器同时进 "workstations"（让 backend perception / E-key 走统一通道）
# 和 "containers"（让 Containers autoload + ContainerPanel 用类型分支查找）。
func _runtime_groups() -> PackedStringArray:
	return PackedStringArray(["workstations", "containers"])


func effective_container_id() -> String:
	return world_object_id()


# 显示名查找顺序：container.<def_id>.name → 基类 workstation.<def_id>.name → def_id 兜底。
func effective_display_name() -> String:
	var cid := world_object_def_id()
	var key := "container.%s.name" % cid
	var localized := tr(key)
	if localized != key:
		return localized
	var ws_name := display_name
	if not ws_name.is_empty() and not ws_name.begins_with("workstation."):
		return ws_name
	return cid


func _refresh_labels() -> void:
	var title := get_node_or_null("Title") as Label3D
	if title != null:
		title.text = effective_display_name()
	var label := get_node_or_null("Prompt") as Label3D
	if label != null:
		var key := "ui.container.prompt_default"
		var prompt := tr(key)
		label.text = prompt if prompt != key and not prompt.is_empty() else "按 E 查看"


func matches_container_id(value: String) -> bool:
	return effective_container_id() == value.strip_edges()


# Shim：综合 group + 锁。等同基类 can_actually_use。
func can_be_opened_by(character: Node) -> bool:
	return can_actually_use(character)


func requires_key() -> bool:
	return is_locked()
