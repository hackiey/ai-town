class_name MapPanel
extends VBoxContainer

# 玩家地图面板：列出全城地点（mapRegistration=global 的 site：25 个分区地点 + 水井），点击直接前往。
# 走 global_map_site_ids()——只含 global，不含工作台/容器/货架/田块（那些是 local，玩家走到所属
# 地点后就近交互）。与 NPC 的 move_to_location 全集（known_position_ids）区分；跟实时 perception
# （按距离过滤）解耦。
# 没访问权限的地点仍然列出，按钮标记 [私]，玩家点了由 server 端按归属拒。
# 顶部 toggle 按钮控制展开/收起。

@onready var _toggle_btn: Button = %ToggleButton
@onready var _body: PanelContainer = %Body
@onready var _list: VBoxContainer = %List

var _local_player: Node = null
var _world: TownWorld = null

const _REBUILD_DISTANCE_THRESHOLD := 1.0
var _last_rebuild_position: Vector3 = Vector3.INF


func _ready() -> void:
	_toggle_btn.pressed.connect(_on_toggle)
	_world = get_tree().get_first_node_in_group("town_world") as TownWorld
	# 等 TownWorld _ready 完成，site 索引才填好
	await get_tree().process_frame
	_rebuild()


func _process(_delta: float) -> void:
	# 实时跟踪：玩家走过 1m 就重算一次按钮列表（避免每帧重建）。
	# 面板收起时跳过 —— 节省开销，下次展开时强制 rebuild。
	if _local_player == null or _world == null or _body == null or not _body.visible:
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
	if _world == null or _local_player == null:
		return
	_last_rebuild_position = _local_player.global_position
	var ids := _world.global_map_site_ids()
	var player_groups: PackedStringArray = _local_player.groups if _local_player.get("groups") != null else PackedStringArray()
	var sorted: Array[String] = []
	for id in ids:
		sorted.append(str(id))
	sorted.sort()
	for id in sorted:
		var btn := Button.new()
		var alias := _world.location_alias(id)
		var label := alias if not alias.is_empty() else id
		var owner_group := _world.owner_group_for(id)
		# 标记带 owner_group 的地点；按钮仍会发请求，方便验证归属和导航。
		if not owner_group.is_empty() and not player_groups.has(owner_group):
			label = "[私] " + label
		btn.text = label
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_button_pressed.bind(id))
		_list.add_child(btn)


func _on_button_pressed(site_id: String) -> void:
	if _local_player == null or not _local_player.has_method("request_move_to_site"):
		push_warning("[MapPanel] no local player or RPC missing")
		return
	_local_player.request_move_to_site.rpc_id(1, site_id)
