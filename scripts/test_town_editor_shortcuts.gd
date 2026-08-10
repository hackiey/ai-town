extends Node

const EDITOR_SCENE := preload("res://src2d/editor/town_editor.tscn")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_PRESET_LIBRARY := preload("res://src2d/data/character_preset_library.gd")

var _editor: Node


func _ready() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	_editor = EDITOR_SCENE.instantiate()
	get_tree().root.add_child(_editor)
	await get_tree().process_frame
	await get_tree().process_frame
	if not _test_asset_hierarchy():
		return
	if not _test_render_layers():
		return
	if not _test_command_undo():
		return
	if not _test_input_boundaries():
		return
	if not await _test_scroll_focus_boundaries():
		return
	if not _test_zoom_inputs():
		return
	print("[TownEditorShortcutsTest] PASS")
	get_tree().quit(0)


func _test_asset_hierarchy() -> bool:
	var primary_tabs: TabBar = _editor.get("_asset_primary_tabs")
	var secondary_flow: HFlowContainer = _editor.get("_asset_secondary_flow")
	if primary_tabs == null or secondary_flow == null:
		return _fail("两级素材分类控件不存在")
	var instance_panel: PanelContainer = _editor.get("_instance_panel")
	var editor_tabs: TabContainer = _editor.get("_editor_tabs")
	if instance_panel == null or instance_panel != _editor.get_node_or_null("EditorUI/Root/InstanceEditorPanel"):
		return _fail("右侧独立实例编辑面板不存在")
	if editor_tabs == null or editor_tabs.is_ancestor_of(instance_panel):
		return _fail("实例编辑面板仍然嵌在左侧旧面板中")
	var instance_panel_rect := instance_panel.get_global_rect()
	if instance_panel_rect.get_center().x <= get_viewport().get_visible_rect().get_center().x:
		return _fail("实例编辑面板没有放在窗口右侧")
	if not bool(_editor.call("_screen_position_is_over_editor_ui", instance_panel_rect.get_center())):
		return _fail("右侧实例编辑面板会把鼠标输入穿透到地图")
	if primary_tabs.tab_count != 5:
		return _fail("一级素材分类没有显示五个 Tab")
	var primary_names := []
	for index in primary_tabs.tab_count:
		primary_names.append(primary_tabs.get_tab_title(index))
	if primary_names != ["环境", "建筑", "人物", "特效", "物品"]:
		return _fail("一级素材分类顺序或名称错误")
	_editor.call("_show_asset_primary_category", "characters", "residents")
	if str(_editor.get("_active_asset_primary_id")) != "characters" or str(_editor.get("_active_asset_category_id")) != "residents":
		return _fail("没有切换到人物 / 居民")
	if secondary_flow.get_child_count() != 1 or str(secondary_flow.get_child(0).text) != "居民":
		return _fail("人物二级分类排版错误")
	var active_items: Array = _editor.get("_active_asset_items")
	if active_items.size() != 20 or active_items.size() != CHARACTER_PRESET_LIBRARY.presets().size():
		return _fail("空项目的人物分类没有显示 20 个语义预设")
	if str(active_items[0].get("kind", "")) != "character_preset" or not str(active_items[0].get("id", "")).begins_with("character_preset:"):
		return _fail("人物分类首项不是可编辑的语义预设")
	if str(_editor.get("_selected_building_asset")) != "character_composite" or str(_editor.get("_selected_character_preset_id")) != "town_guard":
		return _fail("语义预设没有切换到组件人物放置模式")
	if str(_editor.get("_selected_character_action")) != "guard" or str(_editor.get("_selected_character_direction")) != "down":
		return _fail("城镇卫兵预设没有载入默认警戒动作和朝向")
	var placement_cell := _find_placeable_object_cell()
	if placement_cell.x < 0:
		return _fail("找不到用于预设人物放置测试的空格")
	var map_data: Dictionary = _editor.get("_map_data")
	var initial_character_count: int = map_data.get("characters", []).size()
	_editor.call("_handle_building_click", placement_cell, false)
	map_data = _editor.get("_map_data")
	var characters: Array = map_data.get("characters", [])
	if characters.size() != initial_character_count + 1:
		return _fail("语义预设没有写入 characters 集合")
	var preset_character: Dictionary = characters[characters.size() - 1]
	if str(preset_character.get("preset_id", "")) != "town_guard" or preset_character.has("character_id") or preset_character.get("appearance", {}).is_empty():
		return _fail("预设人物没有保存 preset_id 和组件回退配置")
	if str(preset_character.get("action", "")) != "guard" or str(preset_character.get("direction", "")) != "down" or not bool(preset_character.get("action_loop", false)):
		return _fail("预设人物没有保存默认动作、朝向和循环状态")
	if str(preset_character.get("controller", {}).get("type", "")) != "none":
		return _fail("新放置人物没有默认为静态 Controller")
	var escape_event := InputEventKey.new()
	escape_event.keycode = KEY_ESCAPE
	escape_event.pressed = true
	_editor.call("_unhandled_input", escape_event)
	if str(_editor.get("_object_interaction_mode")) != "select":
		return _fail("Esc 没有取消手持素材并进入实例选择模式")
	var character_count_before_empty_click := characters.size()
	var empty_selection_cell := _find_placeable_object_cell()
	_editor.call("_handle_building_click", empty_selection_cell, false)
	map_data = _editor.get("_map_data")
	if map_data.get("characters", []).size() != character_count_before_empty_click:
		return _fail("实例选择模式点击空地仍然放置了手持素材")
	_editor.call("_handle_building_click", placement_cell, false)
	if int(_editor.get("_selected_building_index")) != characters.size() - 1 or str(_editor.get("_selected_object_collection")) != "characters":
		return _fail("取消手持素材后无法左键选择地图人物")
	_editor.call("_remove_building", characters.size() - 1, "characters")

	var character_panel: VBoxContainer = _editor.get("_character_editor_panel")
	var profile_selector: OptionButton = character_panel.get("_profile_selector")
	if profile_selector.item_count != 21:
		return _fail("人物编辑页没有显示新建项和 20 个语义预设")
	profile_selector.select(1)
	character_panel.call("_on_profile_selected", 1)
	if str(character_panel.get("_source_preset_id")) != "town_guard":
		return _fail("人物编辑页没有载入城镇卫兵预设")
	var name_edit: LineEdit = character_panel.get("_name_edit")
	var description_edit: TextEdit = character_panel.get("_description_edit")
	if name_edit.text != "城镇卫兵" or description_edit.text.is_empty():
		return _fail("人物编辑页没有载入预设名称和语义描述")
	var action_selector: OptionButton = character_panel.get("_action_selector")
	var direction_selector: OptionButton = character_panel.get("_direction_selector")
	var preview_visual: Node2D = character_panel.get("_preview_visual")
	if str(action_selector.get_item_metadata(action_selector.selected)) != "guard" or str(direction_selector.get_item_metadata(direction_selector.selected)) != "down":
		return _fail("人物编辑页没有载入预设默认动作和朝向")
	if preview_visual == null or str(preview_visual.call("current_action")) != "guard":
		return _fail("人物编辑页动态预览没有播放警戒动作")
	name_edit.text = "测试居民"
	description_edit.text = "用于验证由语义预设创建的小镇人物档案。"
	character_panel.call("_save_profile")
	map_data = _editor.get("_map_data")
	if map_data.get("character_profiles", []).size() != 1:
		return _fail("人物编辑器保存没有写入 character_profiles")
	var saved_profile: Dictionary = map_data.get("character_profiles", [])[0]
	if str(saved_profile.get("id", "")) != "character_town_guard" or str(saved_profile.get("source_preset_id", "")) != "town_guard" or str(saved_profile.get("description", "")).is_empty():
		return _fail("预设另存后没有保留稳定 ID、预设来源和语义描述")
	if str(saved_profile.get("default_action", "")) != "guard" or str(saved_profile.get("default_direction", "")) != "down" or not "guard" in saved_profile.get("actions", []):
		return _fail("预设另存后没有保留动作集合和默认动作")
	active_items = _editor.get("_active_asset_items")
	if active_items.size() != 21 or str(active_items[active_items.size() - 1].get("id", "")) != "character_profile:character_town_guard":
		return _fail("人物分类没有显示组件化人物档案")
	if str(_editor.get("_selected_building_asset")) != "character_composite" or str(_editor.get("_selected_object_collection")) != "characters" or not str(_editor.get("_selected_character_preset_id")).is_empty():
		return _fail("人物档案没有切换到人物实例放置模式")
	placement_cell = _find_placeable_object_cell()
	if placement_cell.x < 0:
		return _fail("找不到用于人物放置测试的空格")
	initial_character_count = map_data.get("characters", []).size()
	_editor.call("_handle_building_click", placement_cell, false)
	map_data = _editor.get("_map_data")
	characters = map_data.get("characters", [])
	if characters.size() != initial_character_count + 1:
		return _fail("组件人物没有写入 characters 集合")
	var character: Dictionary = characters[characters.size() - 1]
	if str(character.get("character_id", "")) != "character_town_guard" or character.get("appearance", {}).is_empty():
		return _fail("人物实例没有保存档案引用和组件回退配置")
	if str(character.get("action", "")) != "guard" or str(character.get("direction", "")) != "down":
		return _fail("人物档案实例没有保存默认动作和朝向")
	_editor.call("_select_building", characters.size() - 1, "characters")
	var instance_action_selector: OptionButton = _editor.get("_instance_character_action_selector")
	var instance_direction_selector: OptionButton = _editor.get("_instance_character_direction_selector")
	var instance_name_edit: LineEdit = _editor.get("_instance_character_name_edit")
	var controller_selector: OptionButton = _editor.get("_instance_character_controller_selector")
	var speed_spin: SpinBox = _editor.get("_instance_character_speed_spin")
	var scale_spin: SpinBox = _editor.get("_instance_character_scale_spin")
	var shadow_check: CheckButton = _editor.get("_instance_character_shadow_check")
	if not instance_panel.is_ancestor_of(instance_action_selector) or not instance_panel.is_ancestor_of(controller_selector):
		return _fail("人物实例属性控件没有迁移到右侧独立面板")
	var character_section: VBoxContainer = _editor.get("_instance_character_section")
	if character_section == null or not character_section.visible:
		return _fail("选中地图人物后右侧人物实例属性没有显示")
	instance_name_edit.text = "可控测试居民"
	for controller_index in controller_selector.item_count:
		if str(controller_selector.get_item_metadata(controller_index)) == "player":
			controller_selector.select(controller_index)
			break
	speed_spin.set_value_no_signal(180)
	scale_spin.set_value_no_signal(1.25)
	shadow_check.set_pressed_no_signal(false)
	for action_index in instance_action_selector.item_count:
		if str(instance_action_selector.get_item_metadata(action_index)) == "attack":
			instance_action_selector.select(action_index)
			break
	for direction_index in instance_direction_selector.item_count:
		if str(instance_direction_selector.get_item_metadata(direction_index)) == "right":
			instance_direction_selector.select(direction_index)
			break
	var loop_check: CheckButton = _editor.get("_instance_character_loop_check")
	loop_check.set_pressed_no_signal(false)
	_editor.call("_apply_selected_character_action")
	map_data = _editor.get("_map_data")
	character = map_data.get("characters", [])[characters.size() - 1]
	if str(character.get("action", "")) != "attack" or str(character.get("direction", "")) != "right" or bool(character.get("action_loop", true)):
		return _fail("人物实例动作编辑器没有写回动作、朝向和循环状态")
	var controller: Dictionary = character.get("controller", {})
	if str(character.get("name", "")) != "可控测试居民" or str(controller.get("type", "")) != "player" or not is_equal_approx(float(controller.get("move_speed", 0.0)), 180.0):
		return _fail("人物实例面板没有写回名称与 Player Controller")
	if not is_equal_approx(float(character.get("scale", 0.0)), 1.25) or bool(character.get("shadow", true)):
		return _fail("人物实例面板没有写回缩放与阴影")
	_editor.call("_remove_building", characters.size() - 1, "characters")
	var category_path: Label = _editor.get("_asset_category_path_label")
	if category_path == null or not category_path.text.begins_with("人物  /  居民"):
		return _fail("素材分类路径没有显示人物 / 居民")
	return true


func _find_placeable_object_cell() -> Vector2i:
	var map_data: Dictionary = _editor.get("_map_data")
	var size: Array = map_data.get("size", [0, 0])
	for y in range(1, int(size[1])):
		for x in range(1, int(size[0])):
			var cell := Vector2i(x, y)
			if bool(_editor.call("_can_place_building", cell, "", -1)):
				return cell
	return Vector2i(-1, -1)


func _test_render_layers() -> bool:
	var map_root := _editor.get_node_or_null("MapPreview")
	if map_root == null:
		return _fail("编辑器地图根节点不存在")
	var ground := map_root.get_node_or_null("Ground") as TileMapLayer
	var fields := map_root.get_node_or_null("Fields") as TileMapLayer
	var water := map_root.get_node_or_null("Water") as TileMapLayer
	var roads := map_root.get_node_or_null("Roads") as TileMapLayer
	var decals := map_root.get_node_or_null("ObjectLayers/GroundDecals") as Node2D
	var world := map_root.get_node_or_null("ObjectLayers/WorldObjects") as Node2D
	var foreground := map_root.get_node_or_null("ObjectLayers/ForegroundObjects") as Node2D
	var preview := map_root.get_node_or_null("ObjectLayers/PreviewObjects") as Node2D
	var overlay := map_root.get_node_or_null("EditorOverlay") as Node2D
	if null in [ground, fields, water, roads, decals, world, foreground, preview, overlay]:
		return _fail("编辑器渲染层节点不完整")
	if [ground.z_index, fields.z_index, water.z_index, roads.z_index] != [0, 10, 20, 30]:
		return _fail("地形渲染层级不正确")
	if [decals.z_index, world.z_index, foreground.z_index, preview.z_index, overlay.z_index] != [40, 50, 60, 4000, 4095]:
		return _fail("对象或编辑器渲染层级不正确")
	if not world.y_sort_enabled:
		return _fail("世界对象层没有启用 Y 排序")
	var decal_count := decals.get_child_count()
	_editor.call("_add_map_object", {"id": "layer_test_decal", "asset": "dirt_patch_1", "cell": [0, 0], "shadow": false})
	if decals.get_child_count() != decal_count + 1:
		return _fail("泥土斑块没有被分配到地面贴花层")
	var map_data: Dictionary = _editor.get("_map_data")
	var buildings: Array = map_data.get("buildings", [])
	if buildings.is_empty():
		return _fail("找不到用于实例遮挡测试的建筑")
	_editor.call("_select_building", 0, "buildings")
	var layer_selector: OptionButton = _editor.get("_instance_layer_selector")
	var order_spin: SpinBox = _editor.get("_instance_render_order_spin")
	layer_selector.select(2)
	order_spin.set_value_no_signal(77)
	_editor.call("_apply_selected_instance_rendering")
	map_data = _editor.get("_map_data")
	var object_data: Dictionary = map_data.get("buildings", [])[0]
	if str(object_data.get("render_layer", "")) != "foreground" or int(object_data.get("render_order", 0)) != 77:
		return _fail("实例遮挡设置没有写入地图对象")
	var placed_object := _find_child_by_name(foreground, str(object_data.get("id", ""))) as Node2D
	if placed_object == null or placed_object.z_index != 77:
		return _fail("编辑器没有应用实例 render_order")
	_editor.call("_reset_selected_instance_rendering")
	map_data = _editor.get("_map_data")
	object_data = map_data.get("buildings", [])[0]
	if object_data.has("render_layer") or object_data.has("render_order"):
		return _fail("恢复素材默认没有删除实例遮挡覆盖")
	_editor.call("_on_tool_pressed", "road")
	return true


func _find_child_by_name(parent: Node, child_name: String) -> Node:
	for child in parent.get_children():
		if child.name == child_name:
			return child
	return null


func _test_command_undo() -> bool:
	if not _test_undo_modifier(true, false, "Command+Z"):
		return false
	return _test_undo_modifier(false, true, "Ctrl+Z")


func _test_undo_modifier(meta_pressed: bool, ctrl_pressed: bool, label: String) -> bool:
	var road_cells: Dictionary = _editor.get("_road_cells")
	var field_cells: Dictionary = _editor.get("_field_cells")
	var water_cells: Dictionary = _editor.get("_water_cells")
	var test_cell := _find_unpainted_cell(road_cells, field_cells, water_cells)
	if test_cell.x < 0:
		return _fail("找不到用于撤销测试的空白格")
	var snapshot: Dictionary = _editor.call("_make_undo_snapshot")
	if not bool(_editor.call("_paint_cell", test_cell, false)):
		return _fail("测试格没有产生地形变化")
	_editor.call("_push_undo_snapshot", snapshot)
	var undo_event := InputEventKey.new()
	undo_event.keycode = KEY_Z
	undo_event.meta_pressed = meta_pressed
	undo_event.ctrl_pressed = ctrl_pressed
	undo_event.pressed = true
	_editor.call("_unhandled_input", undo_event)
	road_cells = _editor.get("_road_cells")
	if road_cells.has(test_cell):
		return _fail("%s 没有恢复地形" % label)
	return true


func _test_input_boundaries() -> bool:
	var project_name_edit: LineEdit = _editor.get("_project_name_edit")
	var editor_tabs: TabContainer = _editor.get("_editor_tabs")
	editor_tabs.current_tab = 0
	project_name_edit.grab_focus()
	if get_viewport().gui_get_focus_owner() != project_name_edit:
		return _fail("测试无法让文本框获得焦点")
	var map_click := InputEventMouseButton.new()
	map_click.position = Vector2(1200.0, 500.0)
	map_click.button_index = MOUSE_BUTTON_LEFT
	map_click.pressed = true
	_editor.call("_unhandled_input", map_click)
	if get_viewport().gui_get_focus_owner() != null:
		return _fail("点击地图没有释放文本输入焦点")
	map_click.pressed = false
	_editor.call("_unhandled_input", map_click)
	_editor.set("_is_painting", true)
	_editor.set("_paint_undo_captured", true)
	_editor.set("_last_cell", Vector2i.ZERO)
	var mouse_motion := InputEventMouseMotion.new()
	mouse_motion.button_mask = 0
	_editor.call("_unhandled_input", mouse_motion)
	if bool(_editor.get("_is_painting")):
		return _fail("鼠标释放事件丢失后仍保持绘制状态")
	editor_tabs.current_tab = 1
	return true


func _test_scroll_focus_boundaries() -> bool:
	var editor_tabs: TabContainer = _editor.get("_editor_tabs")
	var sidebar: PanelContainer = _editor.get("_sidebar")
	var asset_list: ItemList = _editor.get("_asset_list")
	if editor_tabs == null or sidebar == null or asset_list == null:
		return _fail("滚动焦点测试缺少编辑器控件")
	if sidebar.mouse_force_pass_scroll_events or asset_list.mouse_force_pass_scroll_events:
		return _fail("侧栏或素材列表仍会把滚动事件继续传给地图")
	editor_tabs.current_tab = 1
	_editor.call("_show_asset_primary_category", "environment", "vegetation")
	await get_tree().process_frame
	await get_tree().process_frame
	var scroll_bar := asset_list.get_v_scroll_bar()
	if scroll_bar == null or scroll_bar.max_value <= scroll_bar.page:
		return _fail("素材列表没有形成独立的可滚动区域")
	scroll_bar.value = 0.0
	var camera: Camera2D = _editor.get("_camera")
	var camera_before := camera.position
	var asset_pan := InputEventPanGesture.new()
	asset_pan.position = asset_list.get_global_rect().get_center()
	asset_pan.delta = Vector2(0.0, 36.0)
	_editor.call("_unhandled_input", asset_pan)
	if scroll_bar.value <= 0.0:
		return _fail("在素材列表中上下滑动没有滚动素材列表")
	if camera.position != camera_before:
		return _fail("在素材列表中上下滑动仍然移动了地图")
	var zoom_before := camera.zoom
	var sidebar_wheel := InputEventMouseButton.new()
	sidebar_wheel.position = sidebar.get_global_rect().get_center()
	sidebar_wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	sidebar_wheel.factor = 1.0
	sidebar_wheel.pressed = true
	_editor.call("_unhandled_input", sidebar_wheel)
	if camera.zoom != zoom_before:
		return _fail("在编辑侧栏滚动仍然缩放了地图")
	return true


func _test_zoom_inputs() -> bool:
	var camera: Camera2D = _editor.get("_camera")
	var screen_position := Vector2(1400.0, 620.0)
	var viewport_center: Vector2 = get_viewport().get_visible_rect().size * 0.5
	var offset_from_center: Vector2 = screen_position - viewport_center
	var world_before: Vector2 = camera.position + offset_from_center / camera.zoom.x
	var wheel_event := InputEventMouseButton.new()
	wheel_event.position = screen_position
	wheel_event.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_event.factor = 1.0
	wheel_event.pressed = true
	var zoom_before := camera.zoom.x
	_editor.call("_unhandled_input", wheel_event)
	if camera.zoom.x <= zoom_before:
		return _fail("鼠标滚轮没有放大地图")
	var world_after_wheel: Vector2 = camera.position + offset_from_center / camera.zoom.x
	if not world_before.is_equal_approx(world_after_wheel):
		return _fail("鼠标滚轮缩放没有保持光标下的地图位置")
	world_before = world_after_wheel
	var gesture := InputEventMagnifyGesture.new()
	gesture.position = screen_position
	gesture.factor = 1.2
	_editor.call("_unhandled_input", gesture)
	var world_after: Vector2 = camera.position + offset_from_center / camera.zoom.x
	if not world_before.is_equal_approx(world_after):
		return _fail("触控板缩放没有保持光标下的地图位置")
	world_before = world_after
	var pan_gesture := InputEventPanGesture.new()
	pan_gesture.position = screen_position
	pan_gesture.delta = Vector2(18.0, -12.0)
	var position_before_pan := camera.position
	zoom_before = camera.zoom.x
	_editor.call("_unhandled_input", pan_gesture)
	if not is_equal_approx(camera.zoom.x, zoom_before):
		return _fail("触控板双指平移意外改变了缩放")
	var expected_position := position_before_pan + pan_gesture.delta / camera.zoom.x
	if not camera.position.is_equal_approx(expected_position):
		return _fail("触控板双指手势没有平移画面")
	var zoom_before_render := camera.zoom
	var position_before_render := camera.position
	_editor.call("_render_map")
	if camera.zoom != zoom_before_render or camera.position != position_before_render:
		return _fail("地图重绘重置了用户缩放")
	return true


func _find_unpainted_cell(road_cells: Dictionary, field_cells: Dictionary, water_cells: Dictionary) -> Vector2i:
	var map_data: Dictionary = _editor.get("_map_data")
	var map_size: Array = map_data.get("size", [0, 0])
	for y in range(int(map_size[1])):
		for x in range(int(map_size[0])):
			var cell := Vector2i(x, y)
			if not road_cells.has(cell) and not field_cells.has(cell) and not water_cells.has(cell):
				return cell
	return Vector2i(-1, -1)


func _fail(message: String) -> bool:
	push_error("[TownEditorShortcutsTest] %s" % message)
	get_tree().quit(1)
	return false
