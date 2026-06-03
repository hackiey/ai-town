class_name ShelfNode
extends Node3D

const _DEFAULT_DISPLAY_NAME := "货架"
const _DEFAULT_PROMPT_TEXT := "按 E 查看"

@export var shelf_id: String = ""
# 货架归属走 group（对齐容器的 owner_group 访问模型）：owner_group 组内成员都能 update_shelf
# 上架/补货、把货架上自己的 listing 拿去 offer/赠送；非组员只能看货/购买。
# 空 = 没人能管理（不是公共货架）。组成员真值在 SQLite character_groups，由 Db.can_access 裁决。
@export var owner_group: String = ""
@export var location_id: String = ""
@export var shelf_name: String = ""
@export_range(1, 64, 1) var slot_count: int = 8
@export_range(0.5, 12.0, 0.1) var interaction_radius: float = 3.0

# 货架陈列 = 运行时内存权威（server 端由 Shelves 维护，DB 只做写穿持久化）。**不直接同步**：
# client 显示走「玩家正在查看的那一页」（Player.view_slots，owner-private 同步，见 player.gd）。
# 每条 = {listing_id, slot_index, owner_character_id, price_centi, slot}（同 Db.list_shelf_listings 行）。
var listings: Array[Dictionary] = []

# 2D ShelfNameplateLayer 按 property 读取，无需关心 i18n 路径。
var display_name: String:
	get: return effective_display_name()
	set(_value): pass

var prompt_text: String:
	get: return _translated_or_fallback("ui.shelf.prompt_default", _DEFAULT_PROMPT_TEXT)
	set(_value): pass


func _enter_tree() -> void:
	# Synty 货架 prefab 自带 StaticBody3D —— 进 navmesh 组，烘焙时 NPC 自动绕开。
	add_to_group("navmesh")
	if Engine.is_editor_hint():
		call_deferred("_refresh_labels")


func _ready() -> void:
	add_to_group("shelves")
	if Engine.is_editor_hint():
		_refresh_labels()
		return
	_refresh_labels()
	# Title Label3D 编辑器里可见（帮摆放），runtime 由 ShelfNameplateLayer 接管 2D 渲染。
	var title := get_node_or_null("Title") as Label3D
	if title != null:
		title.visible = false
	# Area3D 由 shelf_node.tscn 提供，半径对齐 interaction_radius；本地玩家进/出 →
	# EventBus.shelf_proximity_changed，由 ShelfPanel 监听决定 E 键能开哪块货架。
	# 同 workstation_node 模式（_on_body_entered/_exited）。
	var area := get_node_or_null("Area3D") as Area3D
	if area != null:
		area.body_entered.connect(_on_body_entered)
		area.body_exited.connect(_on_body_exited)
	if Shelves != null and Shelves.has_method("register_shelf"):
		Shelves.register_shelf(self)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if Shelves != null and Shelves.has_method("unregister_shelf"):
		Shelves.unregister_shelf(self)


func _on_body_entered(body: Node) -> void:
	if not _is_local_player(body):
		return
	EventBus.shelf_proximity_changed.emit(self, true)


func _on_body_exited(body: Node) -> void:
	if not _is_local_player(body):
		return
	EventBus.shelf_proximity_changed.emit(self, false)


# 只对本地玩家响应——server 端 Players.local_character_id 始终为空，自然过滤掉
# headless 进程；多人时其他 player 的 spawned avatar 也不会触发本地 UI。
func _is_local_player(body: Node) -> bool:
	if not body.is_in_group("players"):
		return false
	var cid := str(body.get("character_id"))
	return not cid.is_empty() and cid == Players.local_character_id


# NPC 寻路 / "directlyInteractable" 距离判定的 anchor。带 mesh 的 shelf .tscn 里
# 提供 Approach Marker3D；未提供时 fallback 到 self —— 兼容尚未升级的老节点。
func get_approach_node() -> Node3D:
	var marker := get_node_or_null("Approach") as Node3D
	return marker if marker != null else self


func effective_shelf_id() -> String:
	return shelf_id.strip_edges() if not shelf_id.strip_edges().is_empty() else name


func effective_location_id() -> String:
	return location_id.strip_edges() if not location_id.strip_edges().is_empty() else effective_shelf_id()


func effective_display_name() -> String:
	var custom := shelf_name.strip_edges()
	if not custom.is_empty():
		return custom
	var loc_id := effective_location_id()
	var localized := tr("location.%s.name" % loc_id)
	if localized != "location.%s.name" % loc_id:
		return localized
	return _translated_or_fallback("ui.shelf.label_default", _DEFAULT_DISPLAY_NAME)


func matches_shelf_id(value: String) -> bool:
	return effective_shelf_id() == value.strip_edges()


# 货架管理权限：owner_group 组内成员（god 永远通过，见 Db.can_access）。update_shelf 上架 /
# 把货架货拿去卖都走这道判定（owned_snapshots_for + Shelves.update_shelf）。空 group = 没人能管理。
func is_managed_by(character_id: String) -> bool:
	var cid := character_id.strip_edges()
	var group := owner_group.strip_edges()
	if cid.is_empty() or group.is_empty():
		return false
	if Db == null or not Db.has_method("can_access"):
		return false
	return Db.can_access(cid, group)


func _refresh_labels() -> void:
	var title := get_node_or_null("Title") as Label3D
	if title != null:
		title.text = display_name


func _translated_or_fallback(key: String, fallback: String) -> String:
	var value := tr(key).strip_edges()
	return value if not value.is_empty() and value != key else fallback
