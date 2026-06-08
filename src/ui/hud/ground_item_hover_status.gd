class_name GroundItemHoverStatus
extends CanvasLayer

# Client-only hover panel for ground items. The GroundItem body is picked with a
# physics ray from the current camera through the mouse cursor. 跟 NpcHoverStatus
# 同款实现，只是 collision_mask 改成 ground items 层（layer 3 = bit value 4）。
#
# 提示内容：ItemTooltipFormatter 标准 tooltip + 末行 "[E] 拾取"。

const GROUND_ITEM_COLLISION_MASK := 4
const RAY_LENGTH := 1000.0
const TOOLTIP_OFFSET := Vector2(18.0, 18.0)
const SCREEN_PADDING := 12.0
# 拾取距离不另设常量：读地面物品自己 SiteMarker 的可交互半径（与 server/NPC 同源，不分叉）。

var _panel: PanelContainer = null
var _tooltip_label: Label = null
var _prompt_label: Label = null
var _hovered: GroundItem = null
var _player: Node = null


func _ready() -> void:
	layer = 9
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	set_process(true)


func _process(_delta: float) -> void:
	_hovered = _pick_hovered_ground_item()
	if _hovered == null:
		_panel.visible = false
		return
	_render(_hovered)
	_place_panel()
	_panel.visible = true


# 当前 hover 的 GroundItem（玩家 pickup 输入处理读这个；没 hover 返回 null）。
func current_target() -> GroundItem:
	return _hovered if (_hovered != null and is_instance_valid(_hovered)) else null


# town.gd 在 local player avatar spawn 后调，用于 E 键拾取 RPC。
func set_player(node: Node) -> void:
	_player = node


# 拾取触发：hover 中 + player 在场 + 距离 ≤ 该物品 SiteMarker 的可交互半径，按 E。
# 跟 farm_panel / container_panel / action_panel 一样在 HUD 自己捕获 E，避免 player.gd
# 长成 mega-input dispatcher。
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.physical_keycode != KEY_E:
		return
	var target := current_target()
	if target == null or _player == null:
		return
	if not (_player is Node3D):
		return
	var p3d: Node3D = _player
	if p3d.global_position.distance_to(target.global_position) > SiteMarker.interaction_radius_of(target):
		return
	if not _player.has_method("request_pickup_item"):
		push_warning("[GroundItemHoverStatus] player lacks request_pickup_item RPC")
		return
	_player.request_pickup_item.rpc_id(1, target.get_path())
	get_viewport().set_input_as_handled()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "GroundItemHoverPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	_tooltip_label = Label.new()
	_tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_label.add_theme_font_size_override("font_size", 13)
	_tooltip_label.add_theme_color_override("font_color", Color(0.94, 0.92, 0.84, 1.0))
	vbox.add_child(_tooltip_label)

	_prompt_label = Label.new()
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_label.add_theme_font_size_override("font_size", 12)
	_prompt_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.42, 1.0))
	_prompt_label.text = "[E] 拾取"
	vbox.add_child(_prompt_label)


func _pick_hovered_ground_item() -> GroundItem:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		return null

	var mouse_pos := viewport.get_mouse_position()
	if not viewport.get_visible_rect().has_point(mouse_pos):
		return null

	var world := camera.get_world_3d()
	if world == null:
		return null

	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * RAY_LENGTH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = GROUND_ITEM_COLLISION_MASK
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null

	var node: Node = hit.get("collider", null) as Node
	while node != null:
		if node is GroundItem:
			return node as GroundItem
		node = node.get_parent()
	return null


func _render(gi: GroundItem) -> void:
	var view := InventorySlotData.of(gi.slot_data)
	var item: Item = Items.by_id(gi.item_id)
	var name_for_tip := view.display_name()
	_tooltip_label.text = ItemTooltipFormatter.format(view, item, name_for_tip)


func _place_panel() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var mouse_pos := get_viewport().get_mouse_position()
	var panel_size := _panel.get_combined_minimum_size()
	_panel.size = panel_size

	var pos := mouse_pos + TOOLTIP_OFFSET
	if pos.x + panel_size.x > viewport_size.x - SCREEN_PADDING:
		pos.x = mouse_pos.x - panel_size.x - TOOLTIP_OFFSET.x
	if pos.y + panel_size.y > viewport_size.y - SCREEN_PADDING:
		pos.y = mouse_pos.y - panel_size.y - TOOLTIP_OFFSET.y

	var max_x := maxf(SCREEN_PADDING, viewport_size.x - panel_size.x - SCREEN_PADDING)
	var max_y := maxf(SCREEN_PADDING, viewport_size.y - panel_size.y - SCREEN_PADDING)
	_panel.position = Vector2(
		clampf(pos.x, SCREEN_PADDING, max_x),
		clampf(pos.y, SCREEN_PADDING, max_y)
	)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.045, 0.035, 0.92)
	style.border_color = Color(0.88, 0.70, 0.38, 0.72)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	return style
