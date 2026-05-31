class_name ContainerNode
extends WorkstationNode

# 容器节点 = WorkstationNode 的子类型。继承 proximity / approach / owner_group / lock。
# 额外语义：slot 库存（持久化在 Containers autoload + DB），交互模式 "container"
# 触发独立 inventory UI 而不是 ActionPanel slot grid。
#
# 迁移期：`container_id` / `key_item_id` / `container_name` / `interaction_radius`
# 是兼容旧 .tscn 字段的 setter shim，会自动同步到基类的对应字段。新写法直接
# 用 workstation_id / lock_item_id / i18n display_name。

@export_range(1, 999, 1) var slot_count: int = 12

# 被动转换 tag 集合。每个 tag 代表 Containers.tick_passive 一种被动机制：
#   "drying"     → 槽内 item.dries_into 累计 drying_age_hours，到阈值 swap（drying.lua）
#   （未来加 "fermenting" / "smoking" 等就在这里追加）
# 普通容器留空 = 不触发任何被动机制（背包水果不会"自动变种子"）。
# 见 data/mechanics/drying.lua。
@export var passive_tags: PackedStringArray = PackedStringArray()


func has_passive_tag(tag: String) -> bool:
	return passive_tags.has(tag)

# === 兼容旧字段 ===
# 老 .tscn 实例可能仍设这些字段；setter 把值同步到基类对应字段，让后续代码统一读基类即可。
@export var container_id: String = "":
	set(value):
		container_id = value
		var v := value.strip_edges()
		if not v.is_empty() and workstation_id.strip_edges().is_empty():
			workstation_id = v

@export var key_item_id: String = "":
	set(value):
		key_item_id = value
		var v := value.strip_edges()
		if not v.is_empty() and lock_item_id.strip_edges().is_empty():
			lock_item_id = v

@export var container_name: String = ""


# 容器同时进 "workstations"（让 backend perception / E-key 走统一通道）
# 和 "containers"（让 Containers autoload + ContainerPanel 用类型分支查找）。
func _runtime_groups() -> PackedStringArray:
	return PackedStringArray(["workstations", "containers"])


func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	if Containers != null and Containers.has_method("register_container"):
		Containers.register_container(self)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if Containers != null and Containers.has_method("unregister_container"):
		Containers.unregister_container(self)


func effective_container_id() -> String:
	var wid := workstation_id.strip_edges()
	if not wid.is_empty():
		return wid
	var cid := container_id.strip_edges()
	return cid if not cid.is_empty() else name


# 显示名查找顺序：手动 container_name → container.<id>.name（旧 i18n 命名空间）
# → 基类 workstation.<id>.name → id 兜底。两个 i18n 命名空间并存为迁移期妥协。
func effective_display_name() -> String:
	var custom := container_name.strip_edges()
	if not custom.is_empty():
		return custom
	var cid := effective_container_id()
	var key := "container.%s.name" % cid
	var localized := tr(key)
	if localized != key:
		return localized
	var ws_name := display_name
	if not ws_name.is_empty() and not ws_name.begins_with("workstation."):
		return ws_name
	return cid


func matches_container_id(value: String) -> bool:
	return effective_container_id() == value.strip_edges()


# Shim：综合 group + 锁。等同基类 can_actually_use。
func can_be_opened_by(character: Node) -> bool:
	return can_actually_use(character)


func requires_key() -> bool:
	return is_locked()
