extends Node3D

# 唯一的 town 主场景脚本，server 和 client 共用同一份 scene。
# 按 RunMode 分支：
# - runtime: 起 ENet server、装 PlayerSpawner.spawn_function、peer_connected → spawn avatar
# - client:  连 server、本地 player avatar spawn 后绑相机
#
# 静态几何 / NPC 节点在两端 scene 树里完全一样（同路径），
# MultiplayerSynchronizer 直接用。NPC、Player 的物理只在 server 跑（脚本里 RunMode 守门）。

const DEFAULT_MAX_CLIENTS := 32
const PLAYER_SCENE := preload("res://src/characters/player/player.tscn")
const CHAT_BAR_SCENE := preload("res://src/ui/hud/chat_bar.tscn")
const INVENTORY_PANEL_SCENE := preload("res://src/ui/inventory/inventory_panel.tscn")
const CHARACTER_PANEL_SCENE := preload("res://src/ui/character/character_panel.tscn")
const STATUS_BARS_SCENE := preload("res://src/ui/hud/status_bars.tscn")
const TIME_HUD_SCENE := preload("res://src/ui/hud/time_hud.tscn")
const ACTION_PANEL_SCENE := preload("res://src/ui/action_panel/action_panel.tscn")
const CONTAINER_PANEL_SCENE := preload("res://src/ui/container/container_panel.tscn")
const FARM_PANEL_SCENE := preload("res://src/ui/farm/farm_panel.tscn")
const MAP_PANEL_SCENE := preload("res://src/ui/map/map_panel.tscn")
const HEAD_NAMEPLATE_LAYER_SCRIPT := preload("res://src/ui/head_nameplate_layer.gd")
const WORKSTATION_NAMEPLATE_LAYER_SCRIPT := preload("res://src/ui/workstation_nameplate_layer.gd")
const SHELF_NAMEPLATE_LAYER_SCRIPT := preload("res://src/ui/shelf_nameplate_layer.gd")
const FIELD_STATUS_BUBBLE_LAYER_SCRIPT := preload("res://src/ui/farm/field_status_bubble_layer.gd")
const NPC_HOVER_STATUS_SCRIPT := preload("res://src/ui/hud/npc_hover_status.gd")
const GROUND_ITEM_HOVER_STATUS_SCRIPT := preload("res://src/ui/hud/ground_item_hover_status.gd")
const NPC_CONTEXT_MENU_SCRIPT := preload("res://src/ui/hud/npc_context_menu.gd")
const AI_TAKEOVER_PANEL_SCRIPT := preload("res://src/ui/hud/ai_takeover_panel.gd")
const TRADE_PANEL_SCRIPT := preload("res://src/ui/trade/trade_panel.gd")
const WATER_DRAW_PANEL_SCRIPT := preload("res://src/ui/water_draw/water_draw_panel.gd")
const SPLIT_PANEL_SCRIPT := preload("res://src/ui/split/split_panel.gd")
const BREW_PANEL_SCRIPT := preload("res://src/ui/brewing/brew_panel.gd")
const INTERACTION_CONTROLLER_SCRIPT := preload("res://src/ui/hud/interaction_controller.gd")

@onready var _player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var _players_root: Node3D = $Players
@onready var _player_spawn: Marker3D = $PlayerSpawn
@onready var _crop_spawner: MultiplayerSpawner = $CropSpawner
@onready var _crops_root: Node3D = $Crops
@onready var _camera_rig: CameraRig = $CameraRig if has_node("CameraRig") else null

var _peer: ENetMultiplayerPeer
# client 端：本地 avatar spawn 完才能发 RPC，spawn 之前的输入直接丢。
var _local_player: Node = null
var _chat_bar: Node = null
var _inventory_panel: InventoryPanel = null
var _character_panel: Node = null  # CharacterPanel; 用 Node 避免 class_name cache 未刷新的 parse 错
var _status_bars: StatusBars = null
var _ai_takeover_panel: CanvasLayer = null  # AiTakeoverPanel; 用 Node 引用避免 class_name cache 问题
var _time_hud: TimeHud = null
var _action_panel: Node = null  # ActionPanel; 用 Node 避免 class_name cache 未刷新的 parse 错
var _container_panel: Node = null  # ContainerPanel; 同上理由用 Node 类型
var _water_draw_panel: Node = null  # WaterDrawPanel; 玩家专用打水面板
var _split_panel: Node = null  # SplitPanel; 统一分离/转移面板（倒液 + 份数）
var _brew_panel: Node = null  # BrewPanel; 玩家专用酿酒面板
var _interaction_controller: Node = null  # InteractionController; 统一鼠标指定 + E 路由
var _farm_panel: Node = null
var _head_nameplate_layer: CanvasLayer = null
var _workstation_nameplate_layer: CanvasLayer = null
var _shelf_nameplate_layer: CanvasLayer = null
var _field_status_bubble_layer: CanvasLayer = null
var _npc_hover_status: CanvasLayer = null
var _ground_item_hover_status: GroundItemHoverStatus = null
var _npc_context_menu: Node = null
var _trade_panel: Node = null
var _farm_proximity_active: Node = null  # client：当前最近 FarmGroup（≤ FARM_PROXIMITY_RADIUS）
var _farm_proximity_accum: float = 0.0
var _map_panel: MapPanel = null

const FARM_PROXIMITY_RADIUS := 4.0
const FARM_PROXIMITY_HYSTERESIS := 0.5  # 离开时多走 0.5m 才算 lost，防止边界抖动
const FARM_PROXIMITY_INTERVAL := 0.25


func _ready() -> void:
	# spawn_function 在 server 和 client 上都跑同样代码、同样 data —— owner_peer_id
	# / character_id 等"必须立刻知道"的字段走 data，不走 SceneReplicationConfig
	# （后者要等额外一轮同步）。
	_player_spawner.spawn_function = _spawn_player_from_data
	_crop_spawner.spawn_function = Crop.from_spawn_data
	$GroundItemSpawner.spawn_function = GroundItem.from_spawn_data

	if RunMode.is_runtime():
		_init_runtime()
	else:
		_init_client()


func _init_runtime() -> void:
	# headless 不渲染，留 CameraRig 也无害；删掉只是为了清理输出 + 防止误绑
	if _camera_rig != null:
		_camera_rig.queue_free()
		_camera_rig = null

	_peer = ENetMultiplayerPeer.new()
	# Auth 必须在 create_server 之前装好：client 一连上就触发 callback。
	# 注意：set_auth_callback / send_auth / complete_auth 是 SceneMultiplayer 上的方法，
	# 不在 ENetMultiplayerPeer 上。
	(multiplayer as SceneMultiplayer).set_auth_callback(_on_server_auth)
	var err := _peer.create_server(RunMode.port, DEFAULT_MAX_CLIENTS)
	if err != OK:
		push_error("[town] ENet create_server(:%d) failed: %d" % [RunMode.port, err])
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	# Slow tick：每 game-hour 推进 Crop 生长 / 矿脉恢复等小时级系统。
	GameClock.slow_tick.connect(_on_slow_tick)
	# 生理 tick：每 10 game-minutes 推进角色饱食 / 精力 / 体力 / 饥饿状态。
	GameClock.ten_minute_tick.connect(_on_ten_minute_tick)
	# Hydrate farm_plots → 用 CropSpawner 把上次停机时的作物 spawn 回来。FarmGroup
	# 的 moisture / pest 计数走 FarmGroup._ready 自取（farm_states cache）。
	_hydrate_persisted_crops()
	# Hydrate 地面物品（item_instances ownerKind='world'）→ 重启后掉在地上的东西仍在原位。
	_hydrate_persisted_ground_items()


# 从 Db.all_farm_plots() 取所有有作物的 plot，按 farm_id 找到 FarmGroup，按 plot_index
# 拿到 FarmSlot world_pos，调 CropSpawner.spawn → apply_persisted_state 覆盖字段。
func _hydrate_persisted_crops() -> void:
	var all_plots := Db.all_farm_plots()
	if all_plots.is_empty():
		return
	# farm_id → FarmGroup 索引（避免 N×M 重复扫场景）
	var farms_by_id: Dictionary = {}
	for n in get_tree().get_nodes_in_group("farm_groups"):
		if n is FarmGroup:
			farms_by_id[(n as FarmGroup).effective_farm_id()] = n
	for farm_id in all_plots.keys():
		var farm: FarmGroup = farms_by_id.get(farm_id, null) as FarmGroup
		if farm == null:
			push_warning("[town] hydrate: farm '%s' has saved plots but FarmGroup not in scene" % farm_id)
			continue
		var plots: Dictionary = all_plots[farm_id]
		for k in plots.keys():
			var plot_index := int(k)
			var fields: Dictionary = plots[k]
			var variety_id := str(fields.get("varietyId", ""))
			if variety_id.is_empty():
				continue
			var slot := farm.slot_by_index(plot_index)
			if slot == null:
				push_warning("[town] hydrate: farm '%s' plot %d has no slot" % [farm_id, plot_index])
				continue
			var crop := Crop.spawn(_crop_spawner, variety_id, slot.global_position)
			if crop == null:
				continue
			crop.apply_persisted_state(fields)


# 从 Db.all_ground_items() 取所有 ownerKind='world' 的 item_instances，调 spawner
# 在原位实例化 GroundItem。slot dict 已含全套 aspect（quality / freshness / durability），
# 捡起来跟丢之前一模一样。
func _hydrate_persisted_ground_items() -> void:
	for row in Db.all_ground_items():
		var id := str(row.get("id", ""))
		var pos: Vector3 = row.get("pos", Vector3.ZERO)
		var slot: Dictionary = row.get("slot", {})
		if id.is_empty() or slot.is_empty():
			continue
		GroundItemSpawner.hydrate_from_db(get_tree(), id, pos, slot)


func _on_slow_tick(total_hour: int) -> void:
	# 按 group 遍历：每类 entity 的 apply_hourly_tick 各自处理。
	for node in get_tree().get_nodes_in_group("farm_groups"):
		if node is FarmGroup:
			(node as FarmGroup).apply_hourly_tick(total_hour)
	for node in get_tree().get_nodes_in_group("crops"):
		if node is Crop:
			(node as Crop).apply_hourly_tick(total_hour)
	# Pest 由 FarmGroup 集中调度（按组上限），在 Crop tick 之后跑：
	# 这样 stage 已经推进到本 hour 的最新状态，再决定是否中虫
	for node in get_tree().get_nodes_in_group("farm_groups"):
		if node is FarmGroup:
			(node as FarmGroup).try_pest_tick(total_hour)


func _on_ten_minute_tick(total_minute: int) -> void:
	for node in get_tree().get_nodes_in_group("npcs"):
		if node is Character:
			(node as Character).apply_ten_minute_tick(total_minute)
	for node in get_tree().get_nodes_in_group("players"):
		if node is Character:
			(node as Character).apply_ten_minute_tick(total_minute)


func _init_client() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_disconnected)
	multiplayer.peer_authenticating.connect(_on_peer_authenticating)
	# 监听 spawn —— 自己的 avatar spawn 后绑相机
	_players_root.child_entered_tree.connect(_on_player_spawned)
	_players_root.child_exiting_tree.connect(_on_player_despawned)

	_peer = ENetMultiplayerPeer.new()
	(multiplayer as SceneMultiplayer).set_auth_callback(_on_client_auth)
	var err := _peer.create_client(RunMode.connect_host, RunMode.connect_port)
	if err != OK:
		push_error("[town] ENet create_client failed: %d" % err)
		return
	multiplayer.multiplayer_peer = _peer

	# 2D 头顶 UI：所有角色共享同一套屏幕空间 nameplate / bubble。
	_head_nameplate_layer = HEAD_NAMEPLATE_LAYER_SCRIPT.new()
	add_child(_head_nameplate_layer)
	_workstation_nameplate_layer = WORKSTATION_NAMEPLATE_LAYER_SCRIPT.new()
	add_child(_workstation_nameplate_layer)
	_shelf_nameplate_layer = SHELF_NAMEPLATE_LAYER_SCRIPT.new()
	add_child(_shelf_nameplate_layer)
	_field_status_bubble_layer = FIELD_STATUS_BUBBLE_LAYER_SCRIPT.new()
	add_child(_field_status_bubble_layer)
	_npc_hover_status = NPC_HOVER_STATUS_SCRIPT.new()
	add_child(_npc_hover_status)
	_ground_item_hover_status = GROUND_ITEM_HOVER_STATUS_SCRIPT.new()
	add_child(_ground_item_hover_status)

	# NPC 右键操作菜单（说话 / 提出交易）。CameraRig 拾取 NPC 后通过 EventBus 发信号。
	_npc_context_menu = NPC_CONTEXT_MENU_SCRIPT.new()
	add_child(_npc_context_menu)
	_npc_context_menu.talk_selected.connect(_on_npc_talk_selected)
	_npc_context_menu.trade_selected.connect(_on_npc_trade_selected)

	# HUD：聊天输入框。CanvasLayer 不参与 3D / multiplayer，本地挂上即可。
	_chat_bar = CHAT_BAR_SCENE.instantiate()
	add_child(_chat_bar)
	_chat_bar.command_submitted.connect(_on_chat_command)

	# 背包面板：B 键切换。绑定 player 要等本地 avatar spawn，见 _on_player_spawned。
	_inventory_panel = INVENTORY_PANEL_SCENE.instantiate()
	add_child(_inventory_panel)

	# 角色面板：C 键切换。只展示本地角色属性，不再混在背包面板里。
	_character_panel = CHARACTER_PANEL_SCENE.instantiate()
	add_child(_character_panel)

	# 状态条 HUD：HP / 体力 / 饱食 + active_statuses 标签。同样等本地 avatar spawn 后绑。
	_status_bars = STATUS_BARS_SCENE.instantiate()
	add_child(_status_bars)

	# 顶部时间栏：年月日 + 周几 + 时分。订阅 GameClock，自己刷新，不需要 player 绑定。
	_time_hud = TIME_HUD_SCENE.instantiate()
	add_child(_time_hud)

	# AI 托管开关 + 模型选择弹窗。绑定 player 要等本地 avatar spawn（见 _bind_local_player）。
	_ai_takeover_panel = AI_TAKEOVER_PANEL_SCRIPT.new()
	add_child(_ai_takeover_panel)

	# 工作站 ActionPanel：靠近 workstation Area3D + 按 E 触发；本地玩家未 spawn 时也无害（自己监听 EventBus）。
	_action_panel = ACTION_PANEL_SCENE.instantiate()
	add_child(_action_panel)

	# 容器面板：靠近 ContainerNode（containers group）+ 按 E 触发；和 ActionPanel 互斥（前者跳过容器）。
	_container_panel = CONTAINER_PANEL_SCENE.instantiate()
	add_child(_container_panel)

	# 农场 FarmPanel：靠近 FarmGroup（_check_farm_proximity 轮询）+ 按 E 打开。
	_farm_panel = FARM_PANEL_SCENE.instantiate()
	add_child(_farm_panel)

	# 取水面板（玩家专用）：InteractionController 在水井（infinite source）上按 E 时打开。
	_water_draw_panel = WATER_DRAW_PANEL_SCRIPT.new()
	add_child(_water_draw_panel)

	# 统一分离/转移面板（玩家专用）：背包↔仓库↔灶台 的部分量转移/倒液都用它。
	# 由 ContainerPanel / ActionPanel / InventoryPanel 在右键时打开（注入 on_confirm 回调）。
	_split_panel = SPLIT_PANEL_SCRIPT.new()
	add_child(_split_panel)
	if _container_panel != null and _container_panel.has_method("set_split_panel"):
		_container_panel.set_split_panel(_split_panel)
	if _action_panel != null and _action_panel.has_method("set_split_panel"):
		_action_panel.set_split_panel(_split_panel)
	if _inventory_panel != null and _inventory_panel.has_method("set_split_panel"):
		_inventory_panel.set_split_panel(_split_panel)
	# 背包上下文菜单需要知道当前打开的是灶台还是仓库 → 给 InventoryPanel 两个面板引用。
	if _inventory_panel != null and _inventory_panel.has_method("set_transfer_panels"):
		_inventory_panel.set_transfer_panels(_action_panel, _container_panel)

	# 酿酒面板（玩家专用）：右键装水的酿酒桶选"酿酒…"时由 ContainerPanel 打开。
	_brew_panel = BREW_PANEL_SCRIPT.new()
	add_child(_brew_panel)
	if _container_panel != null and _container_panel.has_method("set_brew_panel"):
		_container_panel.set_brew_panel(_brew_panel)

	# 统一"鼠标指定 + E"节点交互：路由 水井/容器/工作台 的 E，驱动世界提示标签的"单一悬停"显示。
	_interaction_controller = INTERACTION_CONTROLLER_SCRIPT.new()
	add_child(_interaction_controller)
	_interaction_controller.setup(_action_panel, _container_panel, _water_draw_panel, _ground_item_hover_status)

	# 货架已统一为容器：靠近 ShelfNode（containers group）由 ContainerPanel 接管，无独立货架面板。

	# 交易面板：右键 NPC → "提出交易" 时由 _on_npc_trade_selected 弹出。
	_trade_panel = TRADE_PANEL_SCRIPT.new()
	add_child(_trade_panel)

	# 玩家地图面板：列出全城地点，点击直接前往。与 NPC prompt 全城地图同源。
	_map_panel = MAP_PANEL_SCENE.instantiate()
	var map_layer := CanvasLayer.new()
	map_layer.name = "MapLayer"
	add_child(map_layer)
	map_layer.add_child(_map_panel)


func _on_peer_connected(peer_id: int) -> void:
	var cid := Players.character_id_of_peer(peer_id)
	if cid.is_empty():
		push_error("[town] peer_connected %d but no character_id registered (auth bug?)" % peer_id)
		_peer.disconnect_peer(peer_id, true)
		return
	# spawn(data) —— 内部 add_child 到 spawn_path，并把 data 同步给所有 client
	# 重跑 spawn_function。
	_player_spawner.spawn({
		"peer_id": peer_id,
		"character_id": cid,
		"display_name": Players.display_name_of_peer(peer_id),
		"spawn_pos": _player_spawn.global_position,
	})


func _on_peer_disconnected(peer_id: int) -> void:
	var cid := Players.character_id_of_peer(peer_id)
	if not cid.is_empty():
		var player := _players_root.get_node_or_null(cid)
		if player != null:
			player.queue_free()
	Players.unregister(peer_id)


# Server：client 发来 login name → 查/建账号 → 检查在线 → accept 或 reject。
# accept: register + complete_auth；reject: 把原因 send_auth 回去，再 disconnect。
# disconnect_peer(force=false) 走 ENet graceful，会先 flush 已 send 的 auth payload，
# 保证 client 收到拒绝原因。
func _on_server_auth(peer_id: int, data: PackedByteArray) -> void:
	var mp := multiplayer as SceneMultiplayer
	var login_name := data.get_string_from_utf8().strip_edges()
	if login_name.is_empty():
		mp.send_auth(peer_id, "登录失败：名字为空".to_utf8_buffer())
		_peer.disconnect_peer(peer_id, false)
		return
	var acc := Db.lookup_or_create_player_account(login_name)
	var cid: String = str(acc.get("characterId", ""))
	if cid.is_empty():
		mp.send_auth(peer_id, "登录失败：账号创建失败".to_utf8_buffer())
		_peer.disconnect_peer(peer_id, false)
		return
	if Players.is_character_online(cid):
		mp.send_auth(peer_id, ("登录失败：「%s」已在游戏中" % login_name).to_utf8_buffer())
		_peer.disconnect_peer(peer_id, false)
		return
	Players.register(peer_id, cid, login_name)
	mp.complete_auth(peer_id)


# Client：peer_authenticating 是 Godot 在 ENet 连接建立后、peer_connected 之前发的
# 信号，用来给 auth 流程发数据。此处 peer_id 必为 1（server），把 login name 推过去。
func _on_peer_authenticating(peer_id: int) -> void:
	var mp := multiplayer as SceneMultiplayer
	mp.send_auth(peer_id, Players.pending_login_name.to_utf8_buffer())
	mp.complete_auth(peer_id)


# Client：server 拒绝时会 send_auth(error_bytes) 后 disconnect，这里把原因记下来，
# connection_failed 时切回 login 显示。accept 路径 server 不发数据，本 callback 不触发。
func _on_client_auth(_peer_id: int, data: PackedByteArray) -> void:
	Players.last_login_error = data.get_string_from_utf8()


func _on_connected() -> void:
	pass


func _on_connection_failed() -> void:
	_return_to_login("连接失败")


func _on_disconnected() -> void:
	_return_to_login("与服务器断开")


var _returning_to_login: bool = false


func _return_to_login(default_reason: String) -> void:
	# 多个失败信号（connection_failed / server_disconnected / 内部错误）可能同时
	# 触发，scene 切换需要 deferred frame 才生效，期间防止重入。
	if _returning_to_login:
		return
	_returning_to_login = true
	multiplayer.multiplayer_peer = null
	if Players.last_login_error.is_empty():
		Players.last_login_error = default_reason
	Players.local_character_id = ""
	get_tree().change_scene_to_file("res://src/ui/main_menu/login.tscn")


func _on_player_spawned(node: Node) -> void:
	var owner_peer: int = node.get("owner_peer_id") if node != null else 0
	var is_me := owner_peer == multiplayer.get_unique_id()
	if is_me:
		Players.local_character_id = str(node.get("character_id"))
		_bind_local_player.call_deferred(node)


func _bind_local_player(node: Node) -> void:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return
	var owner_peer: int = node.get("owner_peer_id")
	if owner_peer != multiplayer.get_unique_id():
		return
	# 只把相机绑到自己 avatar。其他玩家也会触发这个 callback，但 is_me=false 跳过。
	# 传 Visual 当 pivot_source：camera 跟视觉模型而不是物理 capsule，让同步/step
	# 的小跳动被 Visual 自己的 client smoothing 平滑掉。
	if node is Node3D and _camera_rig != null:
		var visual_node := node.get_node_or_null("Visual") as Node3D
		if visual_node != null and not visual_node.is_inside_tree():
			visual_node = null
		_camera_rig.set_target(node, visual_node)
	_local_player = node
	if _inventory_panel != null:
		_inventory_panel.set_player(node)
	if _character_panel != null:
		_character_panel.set_player(node)
	if _status_bars != null:
		_status_bars.set_player(node)
	if _ai_takeover_panel != null:
		_ai_takeover_panel.set_player(node)
	if _action_panel != null:
		_action_panel.set_player(node)
	if _container_panel != null:
		_container_panel.set_player(node)
	if _water_draw_panel != null:
		_water_draw_panel.set_player(node)
	if _split_panel != null:
		_split_panel.set_player(node)
	if _brew_panel != null:
		_brew_panel.set_player(node)
	if _interaction_controller != null:
		_interaction_controller.set_player(node)
	if _ground_item_hover_status != null:
		_ground_item_hover_status.set_player(node)
	if _farm_panel != null:
		_farm_panel.set_player(node)
	if _trade_panel != null:
		_trade_panel.set_player(node)
	if _field_status_bubble_layer != null:
		_field_status_bubble_layer.set_player(node)
	if _map_panel != null:
		_map_panel.set_local_player(node)


func _on_player_despawned(node: Node) -> void:
	# 我的 avatar 没了 → 解绑相机，避免相机 follow 一个释放中的节点
	if _camera_rig != null and _camera_rig.get("_target") == node:
		_camera_rig.set_target(null)
	if _local_player == node:
		_local_player = null
		if _inventory_panel != null:
			_inventory_panel.set_player(null)
		if _character_panel != null:
			_character_panel.set_player(null)
		if _status_bars != null:
			_status_bars.set_player(null)
		if _ai_takeover_panel != null:
			_ai_takeover_panel.set_player(null)
		if _action_panel != null:
			_action_panel.set_player(null)
		if _container_panel != null:
			_container_panel.set_player(null)
		if _farm_panel != null:
			_farm_panel.set_player(null)
		if _trade_panel != null:
			_trade_panel.set_player(null)
		if _field_status_bubble_layer != null:
			_field_status_bubble_layer.set_player(null)


# Client _process：定时算 local player 与最近 FarmGroup 的距离，触发 EventBus.farm_proximity_changed。
# 不轮 server——server 有 NPC 但 NPC 自己懂农场（context snapshot 提供）。
# 只在本地 player avatar 已绑定后跑；用 hysteresis 防边界抖动。
func _process(delta: float) -> void:
	if _local_player == null:
		return
	_farm_proximity_accum += delta
	if _farm_proximity_accum < FARM_PROXIMITY_INTERVAL:
		return
	_farm_proximity_accum = 0.0
	_check_farm_proximity()


func _check_farm_proximity() -> void:
	var player_pos: Vector3 = (_local_player as Node3D).global_position
	var nearest: Node = null
	var nearest_d := 9999.0
	for n in get_tree().get_nodes_in_group("farm_groups"):
		if not n is Node3D:
			continue
		# 用 FarmGroup 所有 slot 的几何中心，而不是 group 节点自身。
		var center := _farm_center_of(n)
		var d := player_pos.distance_to(center)
		if d < nearest_d:
			nearest_d = d
			nearest = n
	if nearest != null and nearest_d <= FARM_PROXIMITY_RADIUS:
		if nearest != _farm_proximity_active:
			# 切换到新农场：先 lost 旧的，再 entered 新的
			if _farm_proximity_active != null:
				EventBus.farm_proximity_changed.emit(_farm_proximity_active, false)
			_farm_proximity_active = nearest
			EventBus.farm_proximity_changed.emit(nearest, true)
	elif _farm_proximity_active != null:
		# 离开当前农场（带 hysteresis）
		var d_active := player_pos.distance_to(_farm_center_of(_farm_proximity_active))
		if d_active > FARM_PROXIMITY_RADIUS + FARM_PROXIMITY_HYSTERESIS:
			EventBus.farm_proximity_changed.emit(_farm_proximity_active, false)
			_farm_proximity_active = null


# FarmGroup 的交互中心 = 所有 slot 世界坐标的平均值；没 slot 就退到 group 节点本身。
func _farm_center_of(farm: Node) -> Vector3:
	if farm.has_method("slots"):
		var ss: Array = farm.slots()
		if not ss.is_empty():
			var sum := Vector3.ZERO
			var count := 0
			for slot in ss:
				if slot is Node3D:
					sum += (slot as Node3D).global_position
					count += 1
			if count > 0:
				return sum / float(count)
	return (farm as Node3D).global_position


const COMMAND_PREFIX := "/command"


# 输入框文本分流：
# - "/eat <slot>"      → 玩家吃 inventory 第 slot 槽（debug 测试 simulation 食物循环）
# - "/plant <item_id>" → 在面前 spawn Crop（消耗 1 份可种植物）
# - "/harvest"         → 收割正前方最近 ripe Crop
# - "/farmplan <farm_id> <op>[,<op>...]" → 走 NPC plan_farm_work 同条队列路径（dev 用，复现 walking 卡死）
# - "/timewarp <mult>" → 改 GameClock.time_scale（debug，加速验证 slow tick）
# - "/god"             → 切自己 god group 成员资格（本地 Db 直写，不走 backend）
# - "/command <内容>"  → 走 player.command，让 backend agent 解析后下发 action
# - 其他               → 当成对附近喊话（say_to world_event）
# slash 命令统一走本地 avatar 的 owner-RPC 到 server。
func _on_chat_command(text: String, directed_target_id: String = "") -> void:
	if _local_player == null:
		_notify("角色还在生成，命令已忽略：%s" % text, "warn")
		return
	var trimmed := text.strip_edges()

	# 定向模式（右键 NPC → 说话）下，非 slash 文本走 say_to(target=...)，
	# 让对方听众明确。slash 命令仍按原路径处理，方便边定向边发 /eat 之类。
	if not directed_target_id.is_empty() and not trimmed.begins_with("/"):
		if not _local_player.has_method("request_say_to_npc"):
			_notify("本地角色缺 request_say_to_npc 方法", "error")
			return
		_local_player.request_say_to_npc.rpc_id(1, directed_target_id, trimmed)
		return

	if trimmed.begins_with("/eat "):
		var slot_str := trimmed.substr(5).strip_edges()
		if slot_str.is_empty() or not slot_str.is_valid_int():
			_notify("用法：/eat <slot_index>", "warn")
			return
		_local_player.request_eat_food.rpc_id(1, int(slot_str))
		return

	if trimmed.begins_with("/plant "):
		var item_id := trimmed.substr(7).strip_edges()
		if item_id.is_empty():
			_notify("用法：/plant <item_id>", "warn")
			return
		_local_player.request_plant_seed.rpc_id(1, item_id)
		return

	if trimmed == "/harvest":
		_local_player.request_harvest_crop.rpc_id(1)
		return

	if trimmed == "/water":
		_local_player.request_water_crop.rpc_id(1)
		return

	if trimmed == "/pest":
		_local_player.request_remove_pest.rpc_id(1)
		return

	if trimmed.begins_with("/farmtest"):
		var seed_arg := trimmed.substr(9).strip_edges()
		if seed_arg.is_empty():
			seed_arg = "tomato_seed"
		_local_player.request_farm_test.rpc_id(1, seed_arg)
		return

	# /farmplan <farm_id> <op>[,<op>...] → 走 request_queue_farm_actions，
	# 与 NPC plan_farm_work 完全同一条 farm_action_runner 路径（walking→working→apply），
	# 方便 dev 在指定田上复现 NPC 卡死。op 语法：
	#   water                        # 整田浇水
	#   plant:<slot>:<seed_id>       # 在 slot 种 seed
	#   harvest:<slot>               # 收 slot
	#   pest:<slot> / uproot:<slot>
	# 例：/farmplan millward_field_1 water
	#     /farmplan greystone_field_2 plant:0:tomato_seed,plant:1:tomato_seed,water
	if trimmed.begins_with("/farmplan "):
		var rest_plan := trimmed.substr(10).strip_edges()
		var sp := rest_plan.find(" ")
		if sp <= 0:
			_notify("用法：/farmplan <farm_id> <op>[,<op>...]", "warn")
			return
		var farm_arg := rest_plan.substr(0, sp).strip_edges()
		var ops_arg := rest_plan.substr(sp + 1).strip_edges()
		if farm_arg.is_empty() or ops_arg.is_empty():
			_notify("用法：/farmplan <farm_id> <op>[,<op>...]", "warn")
			return
		var ops_out: Array = []
		for tok in ops_arg.split(","):
			var op_str := String(tok).strip_edges()
			if op_str.is_empty():
				continue
			var parts: PackedStringArray = op_str.split(":")
			var kind := parts[0]
			match kind:
				"water":
					ops_out.append({"kind": "water"})
				"plant":
					if parts.size() < 3:
						_notify("plant 需要 plant:<slot>:<seed_id>，跳过 '%s'" % op_str, "warn")
						continue
					ops_out.append({"kind": "plant", "slot_index": int(parts[1]), "seed_id": parts[2]})
				"harvest", "pest", "uproot":
					if parts.size() < 2:
						_notify("%s 需要 %s:<slot>，跳过 '%s'" % [kind, kind, op_str], "warn")
						continue
					ops_out.append({"kind": kind, "slot_index": int(parts[1])})
				_:
					_notify("未知 op 类型 '%s'，跳过" % kind, "warn")
		if ops_out.is_empty():
			_notify("/farmplan 没有有效 op", "warn")
			return
		_local_player.request_queue_farm_actions.rpc_id(1, farm_arg, ops_out)
		return

	if trimmed.begins_with("/timewarp "):
		var mult_str := trimmed.substr(10).strip_edges()
		if mult_str.is_empty() or not mult_str.is_valid_float():
			_notify("用法：/timewarp <multiplier>", "warn")
			return
		_local_player.request_timewarp.rpc_id(1, float(mult_str))
		return

	if trimmed == "/god":
		_local_player.request_god_toggle.rpc_id(1)
		return

	# /cast <mech_name> [arg1 arg2 ...] → 把当前角色当 caster，调 mechanic 的 on_cast hook。
	# args 全是 string，lua 自己 tonumber/parse。例：/cast deafen 5 6 (radius=5 hours=6)
	if trimmed.begins_with("/cast"):
		var rest_cast := trimmed.substr(5).strip_edges()
		if rest_cast.is_empty():
			_notify("用法：/cast <mech_name> [args...]", "warn")
			return
		var parts_cast := rest_cast.split(" ", false)
		var mech := parts_cast[0]
		var spell_args: PackedStringArray = []
		for i in range(1, parts_cast.size()):
			spell_args.append(parts_cast[i])
		_local_player.request_cast_spell.rpc_id(1, mech, spell_args)
		return

	if trimmed.begins_with("/give "):
		var parts := trimmed.substr(6).strip_edges().split(" ", false)
		if parts.size() < 1:
			_notify("用法：/give <item_id> [qty=1] [quality=100]", "warn")
			return
		var qty := int(parts[1]) if parts.size() >= 2 and parts[1].is_valid_int() else 1
		var qual := int(parts[2]) if parts.size() >= 3 and parts[2].is_valid_int() else 100
		_local_player.request_give.rpc_id(1, parts[0], qty, qual)
		return

	# /pack <name> → 给一组预定义的原料，方便玩 craft 全链。
	#   /pack raw     → 全套原矿/燃料/木/麻/亚麻种/麦/水/盐/蛋/肉/果（够走完所有 craft 链）
	#   /pack craft   → 已加工件 + 绑定材料（绕过 forge/anvil 直接工作台 combine）
	#   /pack food    → 食物链原料（wheat 路径 + 盐 + 水）
	#   /pack bronze  → 青铜链原料（copper_ore + tin_ore + charcoal）
	if trimmed.begins_with("/pack"):
		var rest := trimmed.substr(5).strip_edges()
		var pack: Array = []
		match rest:
			"", "raw":
				pack = [
					["iron_ore", 5], ["copper_ore", 3], ["tin_ore", 3], ["charcoal", 8],
					["wood", 5], ["flax_bundle", 6], ["flax_seed", 5], ["wheat", 5], ["wood_bucket", 1],
					["raw_meat", 3], ["egg", 3], ["berry", 5], ["salt", 3],
				]
			"craft":
				pack = [
					["iron_blade", 1], ["iron_pick_head", 1], ["iron_axe_head", 1],
					["wood_shaft", 3], ["rope", 3],
				]
			"food":
				pack = [
					["wheat", 3], ["wood_bucket", 1], ["salt", 3],
					["raw_meat", 2], ["egg", 2], ["berry", 5],
				]
			"bronze":
				pack = [
					["copper_ore", 3], ["tin_ore", 3], ["charcoal", 4],
				]
			_:
				_notify("用法：/pack [raw|craft|food|bronze]", "warn")
				return
		for entry in pack:
			_local_player.request_give.rpc_id(1, String(entry[0]), int(entry[1]), 100)
		_notify("/pack %s：已下发 %d 类材料" % [rest if rest != "" else "raw", pack.size()], "info")
		return

	if trimmed.begins_with(COMMAND_PREFIX):
		var body := trimmed.substr(COMMAND_PREFIX.length()).strip_edges()
		if body.is_empty():
			_notify("/command 后面要带内容", "warn")
			return
		if not _local_player.has_method("submit_player_command"):
			_notify("本地角色缺 submit_player_command 方法", "error")
			return
		_local_player.submit_player_command.rpc_id(1, body)
		_notify("已提交给 AI：%s" % body, "info")
		return

	if not _local_player.has_method("say_text"):
		_notify("本地角色缺 say_text 方法", "error")
		return
	_local_player.say_text.rpc_id(1, trimmed)


func _notify(text: String, level: String = "info") -> void:
	# chat_bar 走 EventBus，这里也直接 emit 一致；chat_bar 还没 spawn 时也无害。
	EventBus.notification_posted.emit(text, level)


# ────────────────────────── NPC 右键菜单 handlers ──────────────────────────
# 两个动作都先让玩家走近 NPC（standoff 距离），UI 不阻塞等到达——服务端的
# emit_say (near 校验) / offer_trade (mech 内距离判定) 各自处理"过远"情形。

func _on_npc_talk_selected(npc: Node) -> void:
	if _local_player == null or npc == null or not is_instance_valid(npc):
		return
	_walk_player_near(npc)
	if _chat_bar == null or not _chat_bar.has_method("set_directed_target"):
		return
	var target_id: String = str(npc.call("backend_character_id")) if npc.has_method("backend_character_id") else ""
	var display: String = str(npc.call("head_ui_display_name")) if npc.has_method("head_ui_display_name") else String(npc.name)
	if target_id.strip_edges().is_empty():
		_notify("NPC 缺少 character id，无法定向说话", "warn")
		return
	_chat_bar.set_directed_target(target_id, display)


func _on_npc_trade_selected(npc: Node) -> void:
	if _local_player == null or npc == null or not is_instance_valid(npc):
		return
	_walk_player_near(npc)
	if _trade_panel == null or not _trade_panel.has_method("open"):
		return
	var target_id: String = str(npc.call("backend_character_id")) if npc.has_method("backend_character_id") else ""
	var display: String = str(npc.call("head_ui_display_name")) if npc.has_method("head_ui_display_name") else String(npc.name)
	if target_id.strip_edges().is_empty():
		_notify("NPC 缺少 character id，无法发起交易", "warn")
		return
	_trade_panel.open(_local_player, target_id, display)


# 朝 NPC 走，但停在 standoff 米外（不要踩到 NPC 身上）。复用 Player.request_move_to。
func _walk_player_near(npc: Node, standoff: float = 1.4) -> void:
	if _local_player == null or not (npc is Node3D):
		return
	if not _local_player.has_method("request_move_to"):
		return
	var from := (_local_player as Node3D).global_position
	var to := (npc as Node3D).global_position
	var dir := from - to
	dir.y = 0.0
	var step := dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	_local_player.request_move_to.rpc_id(1, to + step * standoff, {})


# Server 和 client 都执行；owner_peer_id / character_id 走 data 在两端立刻可用。
# Node name 用 character_id 而不是 peer_id —— 稳定、跨重连复用、_on_peer_disconnected
# 通过 Players.character_id_of_peer 反查直接找到节点。
func _spawn_player_from_data(data: Variant) -> Node:
	var d: Dictionary = data as Dictionary
	var peer_id: int = int(d.get("peer_id", 1))
	var character_id: String = str(d.get("character_id", ""))
	var display_name: String = str(d.get("display_name", "")).strip_edges()
	var spawn_pos: Vector3 = d.get("spawn_pos", Vector3.ZERO)
	var player := PLAYER_SCENE.instantiate()
	player.name = character_id
	player.owner_peer_id = peer_id
	player.character_id = character_id
	# character_name 用于 head nameplate + backend displayName（_player_display_name 读它）；
	# 必须在 _ready 之前赋值，否则 BackendRuntimeClient.register_player 拿到的还是 player_xxx。
	if not display_name.is_empty():
		player.character_name = display_name
	player.position = spawn_pos
	return player
