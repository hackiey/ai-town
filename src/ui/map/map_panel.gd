class_name MapPanel
extends VBoxContainer

# 玩家地图面板：只渲染 Character.map_site_sections() 给出的角色视角 site 数据。
# 全城地点和周围地点的判定收口在 Character/CharacterPerception；面板不直接扫 TownWorld，
# 避免玩家 UI 和 NPC perception 分叉。
# 没访问权限的地点仍然列出，按钮标记 [私]，玩家点了由 server 端按归属拒。
# 顶部 toggle 按钮控制展开/收起。

@onready var _toggle_btn: Button = %ToggleButton
@onready var _body: PanelContainer = %Body
@onready var _list: VBoxContainer = %List

var _local_player: Node = null

const _REBUILD_DISTANCE_THRESHOLD := 1.0
var _last_rebuild_position: Vector3 = Vector3.INF


func _ready() -> void:
	_toggle_btn.pressed.connect(_on_toggle)
	# 等 TownWorld / Character _ready 完成，site 索引和玩家绑定才稳定。
	await get_tree().process_frame
	_rebuild()


func _process(_delta: float) -> void:
	# 实时跟踪：玩家走过 1m 就重算一次按钮列表（避免每帧重建）。
	# 面板收起时跳过 —— 节省开销，下次展开时强制 rebuild。
	if _local_player == null or _body == null or not _body.visible:
		return
	var pos: Vector3 = _local_player.global_position
	if _last_rebuild_position.distance_to(pos) >= _REBUILD_DISTANCE_THRESHOLD:
		_rebuild()


func set_local_player(p: Node) -> void:
	_local_player = p
	if is_inside_tree():
		_rebuild()


func _on_toggle() -> void:
	_body.visible = not _body.visible
	_toggle_btn.text = tr("ui.map.toggle_open") if _body.visible else tr("ui.map.toggle")
	if _body.visible:
		_rebuild()


func _rebuild() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if _local_player == null or not _local_player.has_method("map_site_sections"):
		return
	_last_rebuild_position = _local_player.global_position
	var sections: Dictionary = _local_player.map_site_sections() as Dictionary
	_add_section(tr("ui.map.nearby"), sections.get("nearby", []))
	_add_section(tr("ui.map.global"), sections.get("global", []))


func _add_section(title: String, entries_v: Variant) -> void:
	if not (entries_v is Array):
		return
	var entries: Array = entries_v as Array
	if entries.is_empty():
		return
	var header := Label.new()
	header.text = title
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_list.add_child(header)
	for entry_v in entries:
		if not (entry_v is Dictionary):
			continue
		var entry: Dictionary = entry_v
		var site_id := str(entry.get("id", ""))
		if site_id.is_empty():
			continue
		var btn := Button.new()
		btn.text = _entry_label(entry)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_button_pressed.bind(site_id))
		_list.add_child(btn)


func _entry_label(entry: Dictionary) -> String:
	var label := str(entry.get("label", entry.get("id", "")))
	if bool(entry.get("inaccessible", false)):
		label = "[私] " + label
	var depth := int(entry.get("depth", 0))
	if depth > 0:
		label = "  " + label
	return label


func _on_button_pressed(site_id: String) -> void:
	if _local_player == null or not _local_player.has_method("request_move_to_site"):
		push_warning("[MapPanel] no local player or RPC missing")
		return
	_local_player.request_move_to_site.rpc_id(1, site_id)
