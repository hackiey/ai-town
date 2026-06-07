class_name InteractionController
extends CanvasLayer

# 统一"鼠标悬停 + E"节点交互（client only）。和地面物品 / NPC 完全一致的范式：每帧用相机射线
# 穿过鼠标光标去挑节点（workstation / 容器 / 货架 / 水井），命中谁就提示谁、E 就作用于谁——
# 这样附近多个可交互对象时天然用鼠标指定，不靠"最后进入者赢"。
#
# 节点的可被射线命中：三个基础场景（workstation_node / container_node / shelf_node）的 proximity
# Area3D 放在 pick 层（layer 6 = mask 32），射线 collide_with_areas 命中它即可。世界空间的 "Prompt"
# Label3D 显隐由本控制器独占驱动（基类不再按 proximity 自行显示），保证同一时刻只有悬停的那个亮。
#
# 地面物品 / NPC 仍各自走自己的 raycast HUD；本控制器在地面物品被悬停时让位（不抢 E）。
# E 入口在本类唯一收敛——ActionPanel / ContainerPanel 不再自己抢 E。
#
# 见 plan: 玩家侧水井打水 UI + 鼠标指定 E 交互目标。

const PICK_MASK := 32          # workstation/container/shelf 的 proximity Area3D 所在 pick 层（layer 6）
const RAY_LENGTH := 1000.0
const REACH := 3.0             # 玩家与节点的最大交互距离（与 Containers.INTERACTION_RADIUS 一致；server 再裁）

var _player: Node = null
var _action_panel: Node = null
var _container_panel: Node = null
var _water_panel: Node = null
var _ground_item_hover: Node = null

var _hovered: Node = null      # 当前悬停的可交互节点
var _shown: Node = null        # 当前 Prompt 亮着的节点（用于切换时熄灭上一个）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


# town.gd 在 _init_client 注入三个面板 + 地面物品 HUD 引用。
func setup(action_panel: Node, container_panel: Node, water_panel: Node, ground_item_hover: Node) -> void:
	_action_panel = action_panel
	_container_panel = container_panel
	_water_panel = water_panel
	_ground_item_hover = ground_item_hover


func set_player(node: Node) -> void:
	_player = node


func _process(_dt: float) -> void:
	var target: Node = null
	if not (_is_any_panel_open() or _ground_item_hovered()):
		target = _raycast_node()
		if target != null and not _within_reach(target):
			target = null
	_hovered = target
	# 只让悬停目标的世界 Prompt 亮着（切换时熄灭上一个）。
	if _shown != _hovered:
		_set_prompt_visible(_shown, false)
		_set_prompt_visible(_hovered, true)
		_shown = _hovered


# 相机射线穿过鼠标 → 命中的可交互节点（沿父链找 WorkstationNode）。无则 null。
func _raycast_node() -> Node:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		return null
	var mouse := viewport.get_mouse_position()
	if not viewport.get_visible_rect().has_point(mouse):
		return null
	var world := camera.get_world_3d()
	if world == null:
		return null
	var from := camera.project_ray_origin(mouse)
	var to := from + camera.project_ray_normal(mouse) * RAY_LENGTH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = PICK_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var node: Node = hit.get("collider", null) as Node
	while node != null:
		if node is WorkstationNode:
			return node
		node = node.get_parent()
	return null


func _within_reach(node: Node) -> bool:
	if not (_player is Node3D) or not (node is Node3D):
		return false
	return (_player as Node3D).global_position.distance_to((node as Node3D).global_position) <= REACH


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or key.physical_keycode != KEY_E:
		return
	if _is_any_panel_open() or _ground_item_hovered():
		return
	if _hovered == null or _player == null:
		return
	_route(_hovered)
	get_viewport().set_input_as_handled()


func _route(node: Node) -> void:
	if not _can_use(node):
		_notify_denied(node)
		return
	if node.has_method("is_infinite_source") and node.is_infinite_source():
		if _water_panel != null:
			_water_panel.open(node)
	elif node is ContainerNode:
		if _container_panel != null:
			_container_panel.open(node)
	elif _action_panel != null:
		_action_panel.open(node)


# 交互入口沿用节点自己的可用性判断；工作台 owner_group 不作为硬使用门槛。
func _can_use(node: Node) -> bool:
	if _player == null:
		return false
	if node.has_method("can_actually_use"):
		return node.can_actually_use(_player)
	if node.has_method("can_be_used_by"):
		return node.can_be_used_by(_player)
	return true


func _notify_denied(node: Node) -> void:
	var nm := String(node.display_name) if node.get("display_name") != null else String(node.name)
	EventBus.notification_posted.emit(tr("ui.container.msg_no_access") % nm, "warn")


func _is_any_panel_open() -> bool:
	for p in [_action_panel, _container_panel, _water_panel]:
		if p != null and p.has_method("is_open") and p.is_open():
			return true
	return false


func _ground_item_hovered() -> bool:
	return _ground_item_hover != null and _ground_item_hover.has_method("current_target") \
		and _ground_item_hover.current_target() != null


func _set_prompt_visible(node: Node, visible: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	var label := node.get_node_or_null("Prompt") as Label3D
	if label != null:
		label.visible = visible
