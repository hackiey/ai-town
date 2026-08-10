extends Node2D

const TILE_SIZE := 32
const SIDEBAR_WIDTH := 360.0
const INSTANCE_PANEL_WIDTH := 360.0
const MAP_AREA_LEFT := 392.0
const MAP_AREA_RIGHT := 392.0
const UNDO_LIMIT := 64
const MIN_ZOOM := 0.35
const MAX_ZOOM := 2.0
const WHEEL_ZOOM_STEP := 1.12
const OBJECT_COLLECTIONS := ["buildings", "decorations", "characters"]
const OBJECT_MODE_SELECT := "select"
const OBJECT_MODE_PLACE := "place"
const OBJECT_MODE_MOVE := "move"
const FIELDS_TEXTURE := preload("res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/1 Tiles/FieldsTileset.png")
const FENCE_TEXTURE := preload("res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/1.1 Tiles/Tileset2.png")
const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")
const ASSET_LIBRARY := preload("res://src2d/data/town_asset_library.gd")
const TOWN_MAP_RULES := preload("res://src2d/world/town_map_rules_2d.gd")
const MAP_OBJECT_SCRIPT := preload("res://src2d/world/map_object_2d.gd")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")
const CHARACTER_CONTROLLER_CATALOG := preload("res://src2d/characters/character_controller_catalog.gd")
const CHARACTER_PRESET_LIBRARY := preload("res://src2d/data/character_preset_library.gd")
const CHARACTER_EDITOR_PANEL_SCRIPT := preload("res://src2d/editor/character_editor_panel.gd")
const OVERLAY_SCRIPT := preload("res://src2d/editor/town_editor_overlay.gd")
const TOWN_HALL_API := preload("res://src2d/network/town_hall_api.gd")
const RUNTIME_SCENE := "res://src2d/levels/town_2d.tscn"
const LOBBY_SCENE := "res://src2d/lobby/town_lobby.tscn"
const LOCAL_MANAGER_SCENE := "res://src2d/lobby/local_town_manager.tscn"

var _map_root: Node2D
var _ground: TileMapLayer
var _roads: TileMapLayer
var _fields: TileMapLayer
var _water: TileMapLayer
var _object_root: Node2D
var _ground_decal_objects: Node2D
var _world_objects: Node2D
var _foreground_objects: Node2D
var _preview_objects: Node2D
var _overlay: Node2D
var _camera: Camera2D
var _ui: CanvasLayer
var _sidebar: PanelContainer
var _instance_panel: PanelContainer
var _map_header: PanelContainer
var _editor_tabs: TabContainer

var _project_selector: OptionButton
var _project_id_edit: LineEdit
var _project_name_edit: LineEdit
var _author_name_edit: LineEdit
var _description_edit: LineEdit
var _width_spin: SpinBox
var _height_spin: SpinBox
var _asset_primary_tabs: TabBar
var _asset_secondary_flow: HFlowContainer
var _asset_category_path_label: Label
var _asset_list: ItemList
var _asset_description: Label
var _select_instance_button: Button
var _move_instance_button: Button
var _object_mode_label: Label
var _instance_summary_label: Label
var _instance_character_section: VBoxContainer
var _instance_layer_selector: OptionButton
var _instance_render_order_spin: SpinBox
var _instance_layer_apply_button: Button
var _instance_layer_reset_button: Button
var _instance_layer_hint: Label
var _instance_character_source_label: Label
var _instance_character_name_edit: LineEdit
var _instance_character_controller_selector: OptionButton
var _instance_character_speed_spin: SpinBox
var _instance_character_ai_behavior_selector: OptionButton
var _instance_character_wander_radius_spin: SpinBox
var _instance_character_scale_spin: SpinBox
var _instance_character_shadow_check: CheckButton
var _instance_character_action_selector: OptionButton
var _instance_character_direction_selector: OptionButton
var _instance_character_loop_check: CheckButton
var _instance_character_action_apply_button: Button
var _instance_character_action_hint: Label
var _publish_button: Button
var _publish_request: HTTPRequest
var _status_label: Label
var _map_info_label: Label
var _character_editor_panel: VBoxContainer

var _projects: Array = []
var _current_project_id := ""
var _current_project_name := ""
var _current_project_source := ""
var _map_data: Dictionary = {}
var _ground_cells := {}
var _road_cells := {}
var _field_cells := {}
var _water_cells := {}
var _selected_tool := "road"
var _object_interaction_mode := OBJECT_MODE_SELECT
var _selected_materials := {
	"ground": ASSET_LIBRARY.DEFAULT_GROUND,
	"road": ASSET_LIBRARY.DEFAULT_ROAD,
	"field": ASSET_LIBRARY.DEFAULT_FIELD,
	"water": ASSET_LIBRARY.DEFAULT_WATER,
}
var _asset_primary_categories: Array = []
var _asset_secondary_categories: Array = []
var _asset_secondary_buttons := {}
var _active_asset_primary_id := ""
var _active_asset_category_id := ""
var _syncing_asset_categories := false
var _active_asset_items: Array = []
var _selected_asset_item: Dictionary = {}
var _selected_building_asset := "house_1"
var _selected_building_name := "小屋 1"
var _selected_building_footprint := Vector2i(4, 4)
var _selected_building_index := -1
var _selected_object_collection := "buildings"
var _selected_object_scale := 1.0
var _selected_object_shadow := true
var _selected_character_profile_id := ""
var _selected_character_preset_id := ""
var _selected_character_appearance: Dictionary = {}
var _selected_character_action := "idle"
var _selected_character_direction := "down"
var _selected_character_action_loop := true
var _preview_object: Node2D
var _preview_character_profile_id := ""
var _preview_character_preset_id := ""
var _preview_character_action := ""
var _preview_character_direction := ""
var _preview_character_action_loop := true
var _is_painting := false
var _paint_undo_captured := false
var _last_cell := Vector2i(-1, -1)
var _dirty := false
var _publish_busy := false
var _publish_was_update := false
var _field_tileset: TileSet
var _fence_tileset: TileSet
var _undo_stack: Array[Dictionary] = []


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.035, 0.055, 0.065, 1.0))
	_publish_request = HTTPRequest.new()
	_publish_request.name = "PublishTownRequest"
	add_child(_publish_request)
	_publish_request.request_completed.connect(_on_publish_completed)
	_setup_map_nodes()
	_setup_ui()
	_refresh_projects(RunMode.editor_project_id)
	if RunMode.editor_create_new:
		_prepare_new_project()
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = false
	get_viewport().size_changed.connect(_on_viewport_resized)
	if not _project_id_edit.text.is_empty():
		_set_status("编辑器已启动：触控板双指平移，滚轮或捏合缩放")


func _setup_map_nodes() -> void:
	_map_root = Node2D.new()
	_map_root.name = "MapPreview"
	add_child(_map_root)
	_field_tileset = TOWN_MAP_RULES.make_material_tileset(FIELDS_TEXTURE)
	_fence_tileset = TOWN_MAP_RULES.make_atlas_tileset(FENCE_TEXTURE)
	_ground = _new_layer("Ground", ASSET_LIBRARY.Z_GROUND)
	_fields = _new_layer("Fields", ASSET_LIBRARY.Z_FIELDS)
	_water = _new_layer("Water", ASSET_LIBRARY.Z_WATER)
	_roads = _new_layer("Roads", ASSET_LIBRARY.Z_ROADS)
	_object_root = Node2D.new()
	_object_root.name = "ObjectLayers"
	_map_root.add_child(_object_root)
	_ground_decal_objects = _new_object_layer("GroundDecals", ASSET_LIBRARY.Z_GROUND_DECALS)
	_world_objects = _new_object_layer("WorldObjects", ASSET_LIBRARY.Z_WORLD_OBJECTS, true)
	_foreground_objects = _new_object_layer("ForegroundObjects", ASSET_LIBRARY.Z_FOREGROUND, true)
	_preview_objects = _new_object_layer("PreviewObjects", ASSET_LIBRARY.Z_EDITOR_PREVIEW)
	_overlay = Node2D.new()
	_overlay.name = "EditorOverlay"
	_overlay.set_script(OVERLAY_SCRIPT)
	_overlay.z_index = ASSET_LIBRARY.Z_EDITOR_OVERLAY
	_map_root.add_child(_overlay)
	_camera = Camera2D.new()
	_camera.name = "EditorCamera"
	_camera.enabled = true
	_camera.position_smoothing_enabled = false
	add_child(_camera)


func _new_layer(layer_name: String, layer_z_index: int) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = _field_tileset
	layer.z_index = layer_z_index
	_map_root.add_child(layer)
	return layer


func _new_object_layer(layer_name: String, layer_z_index: int, use_y_sort := false) -> Node2D:
	var layer := Node2D.new()
	layer.name = layer_name
	layer.z_index = layer_z_index
	layer.y_sort_enabled = use_y_sort
	_object_root.add_child(layer)
	return layer


func _setup_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.name = "EditorUI"
	add_child(_ui)
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui.add_child(root)

	_sidebar = PanelContainer.new()
	_sidebar.name = "Sidebar"
	_sidebar.position = Vector2(16, 16)
	_sidebar.size = Vector2(SIDEBAR_WIDTH, maxf(600.0, get_viewport_rect().size.y - 32.0))
	_sidebar.mouse_force_pass_scroll_events = false
	_sidebar.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.055, 0.07, 0.96), Color(0.18, 0.68, 0.78, 0.95)))
	root.add_child(_sidebar)
	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 8)
	_sidebar.add_child(shell)

	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 10)
	shell.add_child(top_bar)
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(heading)
	var title := Label.new()
	title.text = "AI 小镇引擎"
	title.add_theme_font_size_override("font_size", 22)
	heading.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "地图与分类素材库编辑器"
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.78, 0.83))
	heading.add_child(subtitle)
	var lobby_button := Button.new()
	lobby_button.text = "← 返回我的小镇" if RunMode.editor_return_to_manager else "← 返回大厅"
	lobby_button.custom_minimum_size = Vector2(112, 42)
	lobby_button.pressed.connect(_return_to_lobby)
	top_bar.add_child(lobby_button)

	shell.add_child(HSeparator.new())
	_editor_tabs = TabContainer.new()
	_editor_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor_tabs.custom_minimum_size.y = 420
	shell.add_child(_editor_tabs)
	_build_project_tab()
	_build_asset_library_tab()
	_build_character_tab()
	_build_publish_tab()
	_editor_tabs.tab_changed.connect(_on_editor_tab_changed)
	_editor_tabs.current_tab = 1

	shell.add_child(HSeparator.new())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	shell.add_child(action_row)
	var save_button := Button.new()
	save_button.text = "保存小镇"
	save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_button.custom_minimum_size.y = 40
	save_button.pressed.connect(_save_current_project)
	action_row.add_child(save_button)
	var run_button := Button.new()
	run_button.text = "运行当前小镇"
	run_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	run_button.custom_minimum_size.y = 40
	run_button.pressed.connect(_run_current_project)
	action_row.add_child(run_button)
	var path_label := Label.new()
	path_label.text = "user://towns/<town_id>/"
	path_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	path_label.add_theme_font_size_override("font_size", 11)
	path_label.add_theme_color_override("font_color", Color(0.5, 0.62, 0.65))
	shell.add_child(path_label)

	_map_header = PanelContainer.new()
	_map_header.name = "MapHeader"
	_map_header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_map_header.offset_left = MAP_AREA_LEFT
	_map_header.offset_top = 16
	_map_header.offset_right = -16
	_map_header.offset_bottom = 64
	_map_header.mouse_force_pass_scroll_events = false
	_map_header.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.055, 0.07, 0.92), Color(0.12, 0.45, 0.52, 0.9)))
	root.add_child(_map_header)
	_status_label = Label.new()
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_map_header.add_child(_status_label)

	_build_instance_panel(root)
	_refresh_instance_rendering_editor()
	_refresh_object_interaction_ui()


func _build_project_tab() -> void:
	var content := _new_tab_page("项目")
	content.add_child(_section_label("打开已有小镇"))
	_project_selector = OptionButton.new()
	_project_selector.custom_minimum_size.y = 34
	_project_selector.item_selected.connect(_on_project_selected)
	content.add_child(_project_selector)

	content.add_child(HSeparator.new())
	content.add_child(_section_label("新建小镇"))
	_project_id_edit = LineEdit.new()
	_project_id_edit.placeholder_text = "小镇 ID，例如 my_town"
	content.add_child(_project_id_edit)
	_project_name_edit = LineEdit.new()
	_project_name_edit.placeholder_text = "显示名称，例如 我的村庄"
	content.add_child(_project_name_edit)
	var dimension_row := HBoxContainer.new()
	dimension_row.add_child(_small_label("宽"))
	_width_spin = _new_spin(8, 256, 48)
	dimension_row.add_child(_width_spin)
	dimension_row.add_child(_small_label("高"))
	_height_spin = _new_spin(8, 256, 32)
	dimension_row.add_child(_height_spin)
	content.add_child(dimension_row)
	var create_button := Button.new()
	create_button.text = "创建小镇"
	create_button.custom_minimum_size.y = 38
	create_button.pressed.connect(_on_create_project)
	content.add_child(create_button)
	var apply_size_button := Button.new()
	apply_size_button.text = "应用地图尺寸（保留已有内容）"
	apply_size_button.pressed.connect(_on_apply_size)
	content.add_child(apply_size_button)
	var project_help := Label.new()
	project_help.text = "小镇项目保存在本机。调整尺寸时，超出新边界的地图内容会被裁剪。"
	project_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	project_help.add_theme_color_override("font_color", Color(0.62, 0.76, 0.78))
	content.add_child(project_help)


func _build_asset_library_tab() -> void:
	var content := _new_tab_page("素材库")
	var object_mode_row := HBoxContainer.new()
	object_mode_row.add_theme_constant_override("separation", 8)
	_select_instance_button = Button.new()
	_select_instance_button.text = "选择 / 编辑实例"
	_select_instance_button.tooltip_text = "取消手持素材，左键选择地图中的建筑、人物或装饰物。快捷键：Esc"
	_select_instance_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_select_instance_button.pressed.connect(_enter_instance_selection_mode)
	object_mode_row.add_child(_select_instance_button)
	content.add_child(object_mode_row)
	_object_mode_label = Label.new()
	_object_mode_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_object_mode_label.add_theme_color_override("font_color", Color(0.48, 0.76, 0.8))
	content.add_child(_object_mode_label)
	content.add_child(_section_label("素材分类"))
	_asset_primary_tabs = TabBar.new()
	_asset_primary_tabs.name = "AssetPrimaryTabs"
	_asset_primary_tabs.custom_minimum_size.y = 38
	_asset_primary_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_primary_tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
	content.add_child(_asset_primary_tabs)

	_asset_primary_categories = ASSET_LIBRARY.primary_categories()
	for category_value in _asset_primary_categories:
		if not category_value is Dictionary:
			continue
		var tab_index := _asset_primary_tabs.tab_count
		_asset_primary_tabs.add_tab(str(category_value.get("name", category_value.get("id", ""))))
		_asset_primary_tabs.set_tab_metadata(tab_index, str(category_value.get("id", "")))
	_asset_primary_tabs.tab_changed.connect(_on_asset_primary_selected)

	_asset_secondary_flow = HFlowContainer.new()
	_asset_secondary_flow.name = "AssetSecondaryCategories"
	_asset_secondary_flow.custom_minimum_size.y = 32
	_asset_secondary_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_secondary_flow.add_theme_constant_override("h_separation", 6)
	_asset_secondary_flow.add_theme_constant_override("v_separation", 6)
	content.add_child(_asset_secondary_flow)

	_asset_category_path_label = Label.new()
	_asset_category_path_label.name = "AssetCategoryPath"
	_asset_category_path_label.add_theme_font_size_override("font_size", 12)
	_asset_category_path_label.add_theme_color_override("font_color", Color(0.48, 0.76, 0.8))
	content.add_child(_asset_category_path_label)

	_asset_list = ItemList.new()
	_asset_list.name = "AssetItems"
	_asset_list.custom_minimum_size = Vector2(0, 230)
	_asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_asset_list.select_mode = ItemList.SELECT_SINGLE
	_asset_list.icon_mode = ItemList.ICON_MODE_TOP
	_asset_list.fixed_icon_size = Vector2i(48, 48)
	_asset_list.max_columns = 3
	_asset_list.same_column_width = true
	_asset_list.mouse_force_pass_scroll_events = false
	_asset_list.gui_input.connect(_on_asset_list_gui_input)
	_asset_list.item_selected.connect(_on_asset_item_selected)
	content.add_child(_asset_list)

	_asset_description = Label.new()
	_asset_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_asset_description.add_theme_color_override("font_color", Color(0.65, 0.82, 0.84))
	content.add_child(_asset_description)
	var library_help := Label.new()
	library_help.text = "点击素材进入放置模式；Esc 或“选择 / 编辑实例”取消手持素材。\n选择模式：左键选中对象；属性在右侧实例编辑面板中显示。右键删除。\nCtrl/Cmd+Z 撤销；触控板双指平移，滚轮或捏合缩放。"
	library_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	library_help.add_theme_color_override("font_color", Color(0.58, 0.72, 0.75))
	content.add_child(library_help)
	content.add_child(HSeparator.new())
	_map_info_label = Label.new()
	_map_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_info_label.add_theme_color_override("font_color", Color(0.62, 0.82, 0.86))
	content.add_child(_map_info_label)

	if not _asset_primary_categories.is_empty():
		_asset_primary_tabs.current_tab = 0
		_show_asset_primary_category("environment", "road")


func _build_instance_panel(root: Control) -> void:
	_instance_panel = PanelContainer.new()
	_instance_panel.name = "InstanceEditorPanel"
	_instance_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_instance_panel.offset_left = -INSTANCE_PANEL_WIDTH - 16.0
	_instance_panel.offset_top = 80.0
	_instance_panel.offset_right = -16.0
	_instance_panel.offset_bottom = -16.0
	_instance_panel.mouse_force_pass_scroll_events = false
	_instance_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.055, 0.07, 0.96), Color(0.52, 0.38, 0.86, 0.95)))
	root.add_child(_instance_panel)

	var scroll := ScrollContainer.new()
	scroll.name = "InstanceEditorScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_force_pass_scroll_events = false
	_instance_panel.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	scroll.add_child(margin)
	var content := VBoxContainer.new()
	content.name = "InstanceEditorContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)

	var title := Label.new()
	title.text = "实例编辑"
	title.add_theme_font_size_override("font_size", 22)
	content.add_child(title)
	_instance_summary_label = Label.new()
	_instance_summary_label.name = "InstanceSummary"
	_instance_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_instance_summary_label.add_theme_color_override("font_color", Color(0.62, 0.8, 0.86))
	content.add_child(_instance_summary_label)
	_move_instance_button = Button.new()
	_move_instance_button.text = "移动选中实例"
	_move_instance_button.tooltip_text = "让选中的实例跟随鼠标，下一次左键确定新位置。"
	_move_instance_button.pressed.connect(_start_selected_instance_move)
	content.add_child(_move_instance_button)

	content.add_child(HSeparator.new())
	content.add_child(_section_label("通用实例 · 遮挡关系"))
	_instance_layer_selector = OptionButton.new()
	for layer_id in [ASSET_LIBRARY.RENDER_LAYER_GROUND_DECAL, ASSET_LIBRARY.RENDER_LAYER_WORLD, ASSET_LIBRARY.RENDER_LAYER_FOREGROUND]:
		var layer_index := _instance_layer_selector.item_count
		_instance_layer_selector.add_item(ASSET_LIBRARY.render_layer_name(layer_id))
		_instance_layer_selector.set_item_metadata(layer_index, layer_id)
	content.add_child(_instance_layer_selector)
	var order_row := HBoxContainer.new()
	order_row.add_child(_small_label("绘制顺序"))
	_instance_render_order_spin = _new_spin(ASSET_LIBRARY.RENDER_ORDER_MIN, ASSET_LIBRARY.RENDER_ORDER_MAX, 0)
	order_row.add_child(_instance_render_order_spin)
	content.add_child(order_row)
	var layer_button_row := HBoxContainer.new()
	_instance_layer_apply_button = Button.new()
	_instance_layer_apply_button.text = "应用遮挡"
	_instance_layer_apply_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_instance_layer_apply_button.pressed.connect(_apply_selected_instance_rendering)
	layer_button_row.add_child(_instance_layer_apply_button)
	_instance_layer_reset_button = Button.new()
	_instance_layer_reset_button.text = "恢复默认"
	_instance_layer_reset_button.pressed.connect(_reset_selected_instance_rendering)
	layer_button_row.add_child(_instance_layer_reset_button)
	content.add_child(layer_button_row)
	_instance_layer_hint = Label.new()
	_instance_layer_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_instance_layer_hint.add_theme_color_override("font_color", Color(0.64, 0.78, 0.8))
	content.add_child(_instance_layer_hint)

	_instance_character_section = VBoxContainer.new()
	_instance_character_section.name = "CharacterInstanceSection"
	_instance_character_section.add_theme_constant_override("separation", 10)
	content.add_child(_instance_character_section)
	_instance_character_section.add_child(HSeparator.new())
	_instance_character_section.add_child(_section_label("人物实例 · Controller 与表现"))
	_instance_character_source_label = Label.new()
	_instance_character_source_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_instance_character_source_label.add_theme_color_override("font_color", Color(0.48, 0.76, 0.8))
	_instance_character_section.add_child(_instance_character_source_label)
	var character_name_row := HBoxContainer.new()
	character_name_row.add_child(_small_label("名称"))
	_instance_character_name_edit = LineEdit.new()
	_instance_character_name_edit.placeholder_text = "地图人物名称"
	_instance_character_name_edit.max_length = 48
	_instance_character_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	character_name_row.add_child(_instance_character_name_edit)
	_instance_character_section.add_child(character_name_row)
	_instance_character_section.add_child(_small_label("Controller"))
	_instance_character_controller_selector = OptionButton.new()
	for controller_value in CHARACTER_CONTROLLER_CATALOG.controllers():
		var controller_index := _instance_character_controller_selector.item_count
		_instance_character_controller_selector.add_item(str(controller_value.get("name", controller_value.get("id", ""))))
		_instance_character_controller_selector.set_item_metadata(controller_index, str(controller_value.get("id", "none")))
	_instance_character_controller_selector.item_selected.connect(_on_instance_character_controller_selected)
	_instance_character_section.add_child(_instance_character_controller_selector)
	var speed_row := HBoxContainer.new()
	speed_row.add_child(_small_label("移动速度"))
	_instance_character_speed_spin = _new_spin(
		roundi(CHARACTER_CONTROLLER_CATALOG.MIN_MOVE_SPEED),
		roundi(CHARACTER_CONTROLLER_CATALOG.MAX_MOVE_SPEED),
		roundi(CHARACTER_CONTROLLER_CATALOG.DEFAULT_PLAYER_SPEED)
	)
	speed_row.add_child(_instance_character_speed_spin)
	_instance_character_section.add_child(speed_row)
	_instance_character_section.add_child(_small_label("AI 行为"))
	_instance_character_ai_behavior_selector = OptionButton.new()
	for behavior_value in CHARACTER_CONTROLLER_CATALOG.ai_behaviors():
		var behavior_index := _instance_character_ai_behavior_selector.item_count
		_instance_character_ai_behavior_selector.add_item(str(behavior_value.get("name", behavior_value.get("id", ""))))
		_instance_character_ai_behavior_selector.set_item_metadata(behavior_index, str(behavior_value.get("id", "idle")))
	_instance_character_ai_behavior_selector.item_selected.connect(_on_instance_character_ai_behavior_selected)
	_instance_character_section.add_child(_instance_character_ai_behavior_selector)
	var wander_row := HBoxContainer.new()
	wander_row.add_child(_small_label("漫游半径"))
	_instance_character_wander_radius_spin = _new_spin(
		roundi(CHARACTER_CONTROLLER_CATALOG.MIN_WANDER_RADIUS),
		roundi(CHARACTER_CONTROLLER_CATALOG.MAX_WANDER_RADIUS),
		roundi(CHARACTER_CONTROLLER_CATALOG.DEFAULT_WANDER_RADIUS)
	)
	_instance_character_wander_radius_spin.suffix = " 格"
	wander_row.add_child(_instance_character_wander_radius_spin)
	_instance_character_section.add_child(wander_row)
	var character_visual_row := HBoxContainer.new()
	character_visual_row.add_child(_small_label("缩放"))
	_instance_character_scale_spin = SpinBox.new()
	_instance_character_scale_spin.min_value = 0.5
	_instance_character_scale_spin.max_value = 3.0
	_instance_character_scale_spin.step = 0.05
	_instance_character_scale_spin.value = 1.0
	_instance_character_scale_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	character_visual_row.add_child(_instance_character_scale_spin)
	_instance_character_shadow_check = CheckButton.new()
	_instance_character_shadow_check.text = "阴影"
	_instance_character_shadow_check.button_pressed = true
	character_visual_row.add_child(_instance_character_shadow_check)
	_instance_character_section.add_child(character_visual_row)
	_instance_character_section.add_child(_small_label("默认动作"))
	_instance_character_action_selector = OptionButton.new()
	for action_value in CHARACTER_ACTION_CATALOG.actions():
		var action_index := _instance_character_action_selector.item_count
		_instance_character_action_selector.add_item(str(action_value.get("name", action_value.get("id", ""))))
		_instance_character_action_selector.set_item_metadata(action_index, str(action_value.get("id", "idle")))
	_instance_character_section.add_child(_instance_character_action_selector)
	_instance_character_section.add_child(_small_label("默认朝向"))
	_instance_character_direction_selector = OptionButton.new()
	for direction_value in CHARACTER_ACTION_CATALOG.directions():
		var direction_index := _instance_character_direction_selector.item_count
		_instance_character_direction_selector.add_item(str(direction_value.get("name", direction_value.get("id", ""))))
		_instance_character_direction_selector.set_item_metadata(direction_index, str(direction_value.get("id", "down")))
	_instance_character_section.add_child(_instance_character_direction_selector)
	_instance_character_loop_check = CheckButton.new()
	_instance_character_loop_check.text = "循环播放动作"
	_instance_character_loop_check.button_pressed = true
	_instance_character_section.add_child(_instance_character_loop_check)
	_instance_character_action_apply_button = Button.new()
	_instance_character_action_apply_button.text = "应用人物实例属性"
	_instance_character_action_apply_button.custom_minimum_size.y = 38
	_instance_character_action_apply_button.pressed.connect(_apply_selected_character_action)
	_instance_character_section.add_child(_instance_character_action_apply_button)
	_instance_character_action_hint = Label.new()
	_instance_character_action_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_instance_character_action_hint.add_theme_color_override("font_color", Color(0.64, 0.78, 0.8))
	_instance_character_section.add_child(_instance_character_action_hint)


func _build_character_tab() -> void:
	var content := _new_tab_page("人物")
	_character_editor_panel = VBoxContainer.new()
	_character_editor_panel.name = "CharacterEditorPanel"
	_character_editor_panel.set_script(CHARACTER_EDITOR_PANEL_SCRIPT)
	content.add_child(_character_editor_panel)
	_character_editor_panel.connect("profile_saved", _on_character_profile_saved)
	_character_editor_panel.connect("profile_deleted", _on_character_profile_deleted)
	_character_editor_panel.connect("player_profile_selected", _on_player_profile_selected)


func _on_character_profile_saved(profile: Dictionary) -> void:
	if _map_data.is_empty():
		_set_status("请先打开或创建小镇，再保存人物")
		return
	_push_undo_snapshot(_make_undo_snapshot())
	var profiles: Array = _map_data.get("character_profiles", [])
	var profile_id := str(profile.get("id", ""))
	var replaced := false
	for index in profiles.size():
		if str(profiles[index].get("id", "")) == profile_id:
			profiles[index] = profile.duplicate(true)
			replaced = true
			break
	if not replaced:
		profiles.append(profile.duplicate(true))
	_map_data["character_profiles"] = profiles
	for character_value in _map_data.get("characters", []):
		if character_value is Dictionary and str(character_value.get("character_id", "")) == profile_id:
			character_value["appearance"] = profile.get("appearance", {}).duplicate(true)
	_dirty = true
	_refresh_character_editor(profile_id)
	_refresh_character_asset_library(profile_id)
	_render_map()
	_set_status("已%s人物档案：%s" % ["更新" if replaced else "创建", str(profile.get("name", profile_id))])


func _on_character_profile_deleted(profile_id: String) -> void:
	var profiles: Array = _map_data.get("character_profiles", [])
	var remaining: Array = []
	var removed := false
	for profile_value in profiles:
		if profile_value is Dictionary and str(profile_value.get("id", "")) == profile_id:
			removed = true
			continue
		remaining.append(profile_value)
	if not removed:
		return
	_push_undo_snapshot(_make_undo_snapshot())
	_map_data["character_profiles"] = remaining
	if str(_map_data.get("player_character_id", "")) == profile_id:
		_map_data["player_character_id"] = ""
	_dirty = true
	_refresh_character_editor()
	_refresh_character_asset_library()
	_render_map()
	_set_status("已删除人物档案；地图中已放置的人物保留最后一次组件外观")


func _on_player_profile_selected(profile_id: String) -> void:
	if _character_profile(profile_id).is_empty():
		return
	_push_undo_snapshot(_make_undo_snapshot())
	_map_data["player_character_id"] = profile_id
	_dirty = true
	_refresh_character_editor(profile_id)
	_set_status("已将 %s 设为玩家外观" % str(_character_profile(profile_id).get("name", profile_id)))


func _refresh_character_editor(select_id := "") -> void:
	if _character_editor_panel == null or not _character_editor_panel.has_method("set_profiles"):
		return
	_character_editor_panel.call("set_profiles", _map_data.get("character_profiles", []), str(_map_data.get("player_character_id", "")))
	if not select_id.is_empty() and _character_editor_panel.has_method("select_profile"):
		_character_editor_panel.call("select_profile", select_id)


func _refresh_character_asset_library(select_profile_id := "") -> void:
	if _active_asset_category_id != "residents":
		return
	var select_asset_id := "character_profile:%s" % select_profile_id if not select_profile_id.is_empty() else ""
	_refresh_asset_items("residents", select_asset_id)


func _build_publish_tab() -> void:
	var content := _new_tab_page("发布")
	content.add_child(_section_label("发布到小镇大厅"))
	_author_name_edit = LineEdit.new()
	_author_name_edit.placeholder_text = "镇长名称，例如 Harry"
	content.add_child(_author_name_edit)
	_description_edit = LineEdit.new()
	_description_edit.placeholder_text = "一句话介绍你的小镇"
	content.add_child(_description_edit)
	_publish_button = Button.new()
	_publish_button.text = "发布到大厅"
	_publish_button.custom_minimum_size.y = 42
	_publish_button.pressed.connect(_on_publish_pressed)
	content.add_child(_publish_button)
	var publish_help := Label.new()
	publish_help.text = "首次发布会生成编辑令牌并保存在本机。之后可以更新大厅里的同一个小镇。内置地图和下载缓存不能直接发布。"
	publish_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	publish_help.add_theme_color_override("font_color", Color(0.62, 0.76, 0.78))
	content.add_child(publish_help)


func _new_tab_page(title_text: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title_text
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_force_pass_scroll_events = false
	_editor_tabs.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	scroll.add_child(margin)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)
	return content


func _on_editor_tab_changed(tab_index: int) -> void:
	if tab_index == 1 and _selected_asset_item.is_empty() and not _active_asset_category_id.is_empty():
		_refresh_asset_items(_active_asset_category_id)
	elif tab_index == 2:
		_refresh_character_editor()


func _on_asset_primary_selected(index: int) -> void:
	if _syncing_asset_categories or index < 0 or index >= _asset_primary_tabs.tab_count:
		return
	_show_asset_primary_category(str(_asset_primary_tabs.get_tab_metadata(index)))


func _show_asset_primary_category(primary_id: String, select_category_id := "", select_asset_id := "") -> void:
	_active_asset_primary_id = primary_id
	_asset_secondary_categories = ASSET_LIBRARY.categories_for_primary(primary_id)
	_asset_secondary_buttons.clear()
	for child in _asset_secondary_flow.get_children():
		_asset_secondary_flow.remove_child(child)
		child.free()
	if _asset_secondary_categories.is_empty():
		_active_asset_category_id = ""
		_asset_list.clear()
		_asset_category_path_label.text = "%s · 暂无素材" % str(ASSET_LIBRARY.primary_category(primary_id).get("name", primary_id))
		return
	var active_category_id := select_category_id
	var has_requested_category := false
	for category_value in _asset_secondary_categories:
		if str(category_value.get("id", "")) == active_category_id:
			has_requested_category = true
			break
	if not has_requested_category:
		active_category_id = str(_asset_secondary_categories[0].get("id", ""))
	var button_group := ButtonGroup.new()
	for category_value in _asset_secondary_categories:
		var category_id := str(category_value.get("id", ""))
		var button := Button.new()
		button.name = "Category_%s" % category_id
		button.text = str(category_value.get("name", category_id))
		button.toggle_mode = true
		button.button_group = button_group
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(72, 30)
		button.set_pressed_no_signal(category_id == active_category_id)
		button.pressed.connect(_on_asset_secondary_selected.bind(category_id))
		_asset_secondary_flow.add_child(button)
		_asset_secondary_buttons[category_id] = button
	_active_asset_category_id = active_category_id
	_refresh_asset_items(active_category_id, select_asset_id)


func _on_asset_secondary_selected(category_id: String) -> void:
	_active_asset_category_id = category_id
	_refresh_asset_items(category_id)


func _refresh_asset_items(category_id: String, select_asset_id := "") -> void:
	if _asset_list == null or category_id.is_empty():
		return
	var category := ASSET_LIBRARY.category(category_id)
	_active_asset_items = ASSET_LIBRARY.items_for_category(category_id)
	if category_id == "residents":
		for preset_value in CHARACTER_PRESET_LIBRARY.presets():
			if not preset_value is Dictionary:
				continue
			var preset: Dictionary = preset_value
			var preset_id := str(preset.get("id", ""))
			_active_asset_items.append({
				"id": "character_preset:%s" % preset_id,
				"asset": "character_composite",
				"preset_id": preset_id,
				"appearance": preset.get("appearance", {}).duplicate(true),
				"actions": preset.get("actions", []).duplicate(true),
				"default_action": str(preset.get("default_action", "idle")),
				"default_direction": str(preset.get("default_direction", "down")),
				"name": "预设 · %s" % str(preset.get("name", preset_id)),
				"category": "residents",
				"kind": "character_preset",
				"collection": "characters",
				"footprint": [1, 1],
				"scale": 1.0,
				"shadow": true,
				"description": "%s\n可直接放置，也可到人物页载入后继续换组件并另存。" % str(preset.get("description", "")),
			})
		for profile_value in _map_data.get("character_profiles", []):
			if not profile_value is Dictionary:
				continue
			var profile: Dictionary = profile_value
			var profile_id := str(profile.get("id", ""))
			_active_asset_items.append({
				"id": "character_profile:%s" % profile_id,
				"asset": "character_composite",
				"character_id": profile_id,
				"appearance": profile.get("appearance", {}).duplicate(true),
				"actions": profile.get("actions", []).duplicate(true),
				"default_action": str(profile.get("default_action", "idle")),
				"default_direction": str(profile.get("default_direction", "down")),
				"name": "小镇 · %s" % str(profile.get("name", profile_id)),
				"category": "residents",
				"kind": "character_profile",
				"collection": "characters",
				"footprint": [1, 1],
				"scale": 1.0,
				"shadow": true,
				"description": "由人物编辑器保存的组件组合。选择后可放置到地图；修改档案会同步更新引用它的居民。",
			})
	_asset_list.clear()
	var selected_index := 0
	for index in _active_asset_items.size():
		var item: Dictionary = _active_asset_items[index]
		var asset_id := str(item.get("id", ""))
		var icon: Texture2D = null
		if str(item.get("kind", "")) == "terrain":
			icon = TOWN_MAP_RULES.material_preview_texture(FIELDS_TEXTURE, asset_id)
		elif str(item.get("kind", "")) in ["character_profile", "character_preset"]:
			icon = CHARACTER_PART_CATALOG.composite_frame_texture(item.get("appearance", {}))
		else:
			icon = MAP_OBJECT_SCRIPT.texture_for(asset_id)
		if icon != null:
			_asset_list.add_item(str(item.get("name", asset_id)), icon)
		else:
			_asset_list.add_item(str(item.get("name", asset_id)))
		_asset_list.set_item_metadata(index, asset_id)
		_asset_list.set_item_tooltip(index, str(item.get("description", item.get("name", asset_id))))
		if asset_id == select_asset_id:
			selected_index = index
	var primary := ASSET_LIBRARY.primary_category(str(category.get("parent", _active_asset_primary_id)))
	_asset_category_path_label.text = "%s  /  %s  ·  %d 项" % [
		str(primary.get("name", _active_asset_primary_id)),
		str(category.get("name", category_id)),
		_active_asset_items.size(),
	]
	if not _active_asset_items.is_empty():
		_asset_list.select(selected_index)
		_activate_asset_item(selected_index)
	elif _asset_description != null:
		_asset_description.text = "这个分类还没有可用素材。"


func _on_asset_item_selected(index: int) -> void:
	_activate_asset_item(index)


func _on_asset_list_gui_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		_scroll_asset_list(event.delta.y)
		_asset_list.accept_event()


func _scroll_asset_list(delta_y: float) -> void:
	if _asset_list == null:
		return
	var scroll_bar := _asset_list.get_v_scroll_bar()
	if scroll_bar != null:
		scroll_bar.value += delta_y


func _activate_asset_item(index: int) -> void:
	if index < 0 or index >= _active_asset_items.size():
		return
	_selected_asset_item = _active_asset_items[index]
	var asset_id := str(_selected_asset_item.get("id", ""))
	var display_name := str(_selected_asset_item.get("name", asset_id))
	if _asset_description != null:
		var description := str(_selected_asset_item.get("description", "选择后可直接在地图上使用。"))
		if str(_selected_asset_item.get("kind", "")) == "object":
			description += "\n地图叠放：%s" % ASSET_LIBRARY.render_layer_name(ASSET_LIBRARY.render_layer(asset_id))
		_asset_description.text = "%s\n%s" % [display_name, description]
	if str(_selected_asset_item.get("kind", "")) == "terrain":
		_selected_character_profile_id = ""
		_selected_character_preset_id = ""
		_selected_character_appearance = {}
		_selected_character_action = "idle"
		_selected_character_direction = "down"
		_selected_character_action_loop = true
		var tool_id := str(_selected_asset_item.get("tool", "ground"))
		_selected_materials[tool_id] = asset_id
		_on_tool_pressed(tool_id)
		return
	var item_kind := str(_selected_asset_item.get("kind", ""))
	var is_character_profile := item_kind == "character_profile"
	var is_character_preset := item_kind == "character_preset"
	_selected_building_asset = str(_selected_asset_item.get("asset", asset_id))
	_selected_building_name = display_name
	_selected_character_profile_id = str(_selected_asset_item.get("character_id", "")) if is_character_profile else ""
	_selected_character_preset_id = str(_selected_asset_item.get("preset_id", "")) if is_character_preset else ""
	_selected_character_appearance = CHARACTER_PART_CATALOG.normalize_appearance(_selected_asset_item.get("appearance", {})) if is_character_profile or is_character_preset else {}
	_selected_character_action = CHARACTER_ACTION_CATALOG.normalize_action(str(_selected_asset_item.get("default_action", "idle"))) if is_character_profile or is_character_preset else "idle"
	_selected_character_direction = CHARACTER_ACTION_CATALOG.normalize_direction(str(_selected_asset_item.get("default_direction", "down"))) if is_character_profile or is_character_preset else "down"
	_selected_character_action_loop = true
	var footprint: Array = _selected_asset_item.get("footprint", [1, 1])
	_selected_building_footprint = Vector2i(maxi(1, int(footprint[0])), maxi(1, int(footprint[1]))) if footprint.size() >= 2 else Vector2i.ONE
	_selected_object_collection = str(_selected_asset_item.get("collection", "decorations"))
	_selected_object_scale = float(_selected_asset_item.get("scale", 1.0))
	_selected_object_shadow = bool(_selected_asset_item.get("shadow", true))
	_selected_building_index = -1
	_object_interaction_mode = OBJECT_MODE_PLACE
	_preview_character_profile_id = ""
	_preview_character_preset_id = ""
	_preview_character_action = ""
	_preview_character_direction = ""
	_refresh_instance_rendering_editor()
	_on_tool_pressed("object")


func _select_asset_in_library(asset_id: String) -> void:
	var catalog_item := ASSET_LIBRARY.item(asset_id)
	if catalog_item.is_empty() or _asset_primary_tabs == null:
		return
	var category_id := str(catalog_item.get("category", ""))
	var category := ASSET_LIBRARY.category(category_id)
	var primary_id := str(category.get("parent", ""))
	for primary_index in _asset_primary_tabs.tab_count:
		if str(_asset_primary_tabs.get_tab_metadata(primary_index)) == primary_id:
			_syncing_asset_categories = true
			_asset_primary_tabs.current_tab = primary_index
			_syncing_asset_categories = false
			_show_asset_primary_category(primary_id, category_id, asset_id)
			return


func _refresh_projects(select_id := "", load_selected := true) -> void:
	_projects = TOWN_PROJECT.list_projects()
	_project_selector.clear()
	var selected_index := 0
	for index in _projects.size():
		var project: Dictionary = _projects[index]
		_project_selector.add_item("%s  [%s]" % [project.get("name", project.get("id", "")), project.get("source", "")])
		_project_selector.set_item_tooltip(index, "ID: %s" % project.get("id", ""))
		if str(project.get("id", "")) == select_id:
			selected_index = index
	if not _projects.is_empty():
		_project_selector.select(selected_index)
		if load_selected:
			_load_project(selected_index)


func _load_project(index: int) -> void:
	if index < 0 or index >= _projects.size():
		return
	var project: Dictionary = _projects[index]
	_current_project_id = str(project.get("id", ""))
	_current_project_name = str(project.get("name", _current_project_id))
	_current_project_source = str(project.get("source", "builtin"))
	_map_data = TOWN_PROJECT.load_map(_current_project_id)
	if _map_data.is_empty():
		_map_data = TOWN_PROJECT.make_default_map(48, 32, _current_project_name)
	_map_data["name"] = _current_project_name
	_project_id_edit.text = _current_project_id
	_project_name_edit.text = _current_project_name
	var manifest := TOWN_PROJECT.load_manifest(_current_project_id)
	_author_name_edit.text = str(manifest.get("author_name", ""))
	_description_edit.text = str(manifest.get("description", ""))
	var map_size: Array = _map_data.get("size", [48, 32])
	_width_spin.set_value_no_signal(int(map_size[0]))
	_height_spin.set_value_no_signal(int(map_size[1]))
	_dirty = false
	_clear_undo_history()
	_selected_building_index = -1
	_object_interaction_mode = OBJECT_MODE_SELECT
	_extract_cells()
	_render_map(true)
	_refresh_character_editor()
	_refresh_instance_rendering_editor()
	_refresh_publish_ui(manifest)
	_set_status("已打开：%s" % _current_project_id)


func _prepare_new_project() -> void:
	_current_project_id = ""
	_current_project_name = ""
	_current_project_source = ""
	_map_data = TOWN_PROJECT.make_default_map(48, 32, "")
	_project_id_edit.clear()
	_project_name_edit.clear()
	_author_name_edit.clear()
	_description_edit.clear()
	_width_spin.set_value_no_signal(48)
	_height_spin.set_value_no_signal(32)
	_clear_undo_history()
	_selected_building_index = -1
	_object_interaction_mode = OBJECT_MODE_SELECT
	_extract_cells()
	_render_map(true)
	_refresh_character_editor()
	_refresh_instance_rendering_editor()
	_refresh_publish_ui({})
	_editor_tabs.current_tab = 0
	_project_id_edit.grab_focus.call_deferred()
	_set_status("新建小镇：先填写小镇 ID、名称和尺寸，然后点击“创建小镇”")


func _on_project_selected(index: int) -> void:
	if _dirty:
		_save_current_project()
	_load_project(index)


func _on_create_project() -> void:
	var requested_id := _project_id_edit.text.strip_edges()
	var project_name := _project_name_edit.text.strip_edges()
	if requested_id.is_empty():
		requested_id = project_name
	var safe_id := TOWN_PROJECT.sanitize_id(requested_id)
	if safe_id.is_empty():
		_set_status("创建失败：请输入英文、数字、下划线或短横线组成的 ID")
		return
	if project_name.is_empty():
		project_name = safe_id
	var map_data := TOWN_PROJECT.create_project(safe_id, project_name, int(_width_spin.value), int(_height_spin.value))
	if map_data.is_empty():
		_set_status("创建失败：无法写入 user://towns/%s/" % safe_id)
		return
	_refresh_projects(safe_id)
	_editor_tabs.current_tab = 1
	_set_status("已创建小镇文件夹：user://towns/%s/" % safe_id)


func _on_apply_size() -> void:
	if _map_data.is_empty():
		return
	var new_width := int(_width_spin.value)
	var new_height := int(_height_spin.value)
	var old_size: Array = _map_data.get("size", [48, 32])
	if int(old_size[0]) == new_width and int(old_size[1]) == new_height:
		return
	_push_undo_snapshot(_make_undo_snapshot())
	var resized: Dictionary = _map_data.duplicate(true)
	resized["size"] = [new_width, new_height]
	resized["name"] = _current_project_name
	var new_bounds := Vector2i(new_width, new_height)
	var ground_cells := _filter_cells(_ground_cells, new_bounds)
	var road_cells := _filter_cells(_road_cells, new_bounds)
	var field_cells := _filter_cells(_field_cells, new_bounds)
	var water_cells := _filter_cells(_water_cells, new_bounds)
	var layers: Dictionary = resized.get("layers", {})
	resized["layers"] = layers
	resized["layers"]["ground"] = TOWN_MAP_RULES.material_cells_to_rects(ground_cells)
	resized["layers"]["roads"] = TOWN_MAP_RULES.material_cells_to_rects(road_cells)
	resized["layers"]["fields"] = TOWN_MAP_RULES.material_cells_to_rects(field_cells)
	resized["layers"]["water"] = TOWN_MAP_RULES.material_cells_to_rects(water_cells)
	resized["fences"] = _clip_rect_specs(_map_data.get("fences", []), new_bounds)
	resized["buildings"] = _clip_objects(_map_data.get("buildings", []), new_bounds)
	resized["decorations"] = _clip_objects(_map_data.get("decorations", []), new_bounds)
	resized["characters"] = _clip_objects(_map_data.get("characters", []), new_bounds)
	resized["locations"] = _clip_objects(_map_data.get("locations", []), new_bounds)
	var spawn: Array = _map_data.get("player_spawn", [new_width / 2, new_height / 2])
	resized["player_spawn"] = [clampi(int(spawn[0]), 0, new_width - 1), clampi(int(spawn[1]), 0, new_height - 1)]
	_map_data = resized
	_selected_building_index = -1
	_object_interaction_mode = OBJECT_MODE_SELECT
	_extract_cells()
	_render_map(true)
	_refresh_instance_rendering_editor()
	_dirty = true
	_set_status("地图已调整为 %d × %d，边界外内容已裁剪" % [new_width, new_height])


func _on_tool_pressed(tool_id: String) -> void:
	_stop_painting()
	_selected_tool = tool_id
	if tool_id != "object":
		_object_interaction_mode = OBJECT_MODE_SELECT
		_selected_building_index = -1
		_refresh_instance_rendering_editor()
	_overlay.set("selected_tool", tool_id)
	_update_building_preview(_mouse_cell())
	_refresh_object_interaction_ui()
	var material_id := str(_selected_materials.get(tool_id, ""))
	var material := ASSET_LIBRARY.terrain_material(material_id)
	var label := _selected_building_name if tool_id == "object" else str(material.get("name", _tool_label(tool_id)))
	if tool_id == "object" and _object_interaction_mode == OBJECT_MODE_SELECT:
		_set_status("选择模式：左键点击地图中的人物或其他实例")
	else:
		_set_status("当前素材：%s" % label)


func _enter_instance_selection_mode() -> void:
	_stop_painting()
	_selected_tool = "object"
	_object_interaction_mode = OBJECT_MODE_SELECT
	_overlay.set("selected_tool", "object")
	_update_building_preview(_mouse_cell())
	_refresh_object_interaction_ui()
	_set_status("选择模式：鼠标已取消手持素材，左键点击地图实例进行编辑")


func _start_selected_instance_move() -> void:
	if _selected_building_index < 0 or _selected_instance_data().is_empty():
		_set_status("请先在选择模式中点击一个地图实例")
		return
	_selected_tool = "object"
	_object_interaction_mode = OBJECT_MODE_MOVE
	_overlay.set("selected_tool", "object")
	_update_building_preview(_mouse_cell())
	_refresh_object_interaction_ui()
	_set_status("移动模式：左键点击新位置，Esc 取消移动")


func _refresh_object_interaction_ui() -> void:
	if _object_mode_label == null:
		return
	if _move_instance_button != null:
		_move_instance_button.disabled = _selected_building_index < 0
	match _object_interaction_mode:
		OBJECT_MODE_PLACE:
			_object_mode_label.text = "当前：放置素材 · %s。Esc 可取消。" % _selected_building_name
		OBJECT_MODE_MOVE:
			_object_mode_label.text = "当前：移动选中实例。左键确定位置，Esc 取消。"
		_:
			_object_mode_label.text = "当前：选择 / 编辑实例。鼠标不会携带素材。"


func _select_building(index: int, collection := "buildings") -> void:
	var objects: Array = _map_data.get(collection, [])
	if index < 0 or index >= objects.size():
		return
	var object_data: Dictionary = objects[index]
	_selected_building_asset = str(object_data.get("asset", "house_1"))
	if MAP_OBJECT_SCRIPT.is_character_asset(_selected_building_asset):
		_selected_character_profile_id = str(object_data.get("character_id", ""))
		_selected_character_preset_id = str(object_data.get("preset_id", ""))
		_selected_character_appearance = _resolve_character_appearance(object_data)
		var selected_action := _resolve_character_action(object_data)
		var select_asset_id := ""
		if not _selected_character_profile_id.is_empty():
			select_asset_id = "character_profile:%s" % _selected_character_profile_id
		elif not _selected_character_preset_id.is_empty():
			select_asset_id = "character_preset:%s" % _selected_character_preset_id
		_show_asset_primary_category("characters", "residents", select_asset_id)
		_selected_character_action = str(selected_action.get("action", "idle"))
		_selected_character_direction = str(selected_action.get("direction", "down"))
		_selected_character_action_loop = bool(selected_action.get("loop", true))
	else:
		_selected_character_profile_id = ""
		_selected_character_preset_id = ""
		_selected_character_appearance = {}
		_selected_character_action = "idle"
		_selected_character_direction = "down"
		_selected_character_action_loop = true
		_select_asset_in_library(_selected_building_asset)
	_selected_building_name = str(object_data.get("name", _selected_building_asset))
	_selected_building_footprint = _object_footprint(object_data)
	_selected_object_scale = float(object_data.get("scale", 1.0))
	_selected_object_shadow = bool(object_data.get("shadow", true))
	_selected_object_collection = collection
	_selected_building_index = index
	_object_interaction_mode = OBJECT_MODE_SELECT
	_refresh_instance_rendering_editor()
	_update_building_preview(_mouse_cell())
	_refresh_object_interaction_ui()
	_set_status("已选中 %s：请在右侧实例编辑面板修改属性" % _selected_building_name)


func _refresh_instance_rendering_editor() -> void:
	if _instance_layer_selector == null:
		return
	var object_data := _selected_instance_data()
	var has_selection := not object_data.is_empty()
	if _instance_summary_label != null:
		if has_selection:
			var cell := _object_cell(object_data)
			var collection_name: String = {
				"buildings": "建筑",
				"decorations": "装饰",
				"characters": "人物",
			}.get(_selected_object_collection, "对象")
			_instance_summary_label.text = "%s · %s\nID: %s · 格子 (%d, %d)" % [
				collection_name,
				str(object_data.get("name", object_data.get("id", "未命名实例"))),
				str(object_data.get("id", "")),
				cell.x,
				cell.y,
			]
		else:
			_instance_summary_label.text = "未选择实例。按 Esc 取消手持素材，然后左键点击地图中的人物、建筑或装饰物。"
	_instance_layer_selector.disabled = not has_selection
	_instance_render_order_spin.editable = has_selection
	_instance_layer_apply_button.disabled = not has_selection
	_instance_layer_reset_button.disabled = not has_selection or (not object_data.has("render_layer") and not object_data.has("render_order"))
	_refresh_instance_character_action_editor(object_data)
	_refresh_object_interaction_ui()
	if not has_selection:
		_instance_layer_selector.select(1)
		_instance_render_order_spin.set_value_no_signal(0)
		_instance_layer_hint.text = "先点击地图中已经放置的对象，再设置这个实例的遮挡关系。"
		return
	var layer_id := ASSET_LIBRARY.object_render_layer(object_data)
	for index in _instance_layer_selector.item_count:
		if str(_instance_layer_selector.get_item_metadata(index)) == layer_id:
			_instance_layer_selector.select(index)
			break
	var order := ASSET_LIBRARY.object_render_order(object_data)
	_instance_render_order_spin.set_value_no_signal(order)
	_instance_layer_hint.text = "最终顺序 %d = 基础层 %d + 自定义 %d。数值越大越靠前；最终值相同时按地图 Y 坐标遮挡。" % [
		ASSET_LIBRARY.final_render_order(object_data),
		ASSET_LIBRARY.render_layer_z(layer_id),
		order,
	]


func _refresh_instance_character_action_editor(object_data: Dictionary) -> void:
	if _instance_character_action_selector == null:
		return
	var is_character := not object_data.is_empty() and MAP_OBJECT_SCRIPT.is_character_asset(str(object_data.get("asset", "")))
	if _instance_character_section != null:
		_instance_character_section.visible = is_character
	_instance_character_name_edit.editable = is_character
	_instance_character_controller_selector.disabled = not is_character
	_instance_character_speed_spin.editable = is_character
	_instance_character_ai_behavior_selector.disabled = not is_character
	_instance_character_wander_radius_spin.editable = is_character
	_instance_character_scale_spin.editable = is_character
	_instance_character_shadow_check.disabled = not is_character
	_instance_character_action_selector.disabled = not is_character
	_instance_character_direction_selector.disabled = not is_character
	_instance_character_loop_check.disabled = not is_character
	_instance_character_action_apply_button.disabled = not is_character
	if not is_character:
		_instance_character_source_label.text = "选中地图中的人物后，可编辑这个实例的控制器与表现。"
		_instance_character_name_edit.text = ""
		_instance_character_controller_selector.select(0)
		_instance_character_speed_spin.set_value_no_signal(CHARACTER_CONTROLLER_CATALOG.DEFAULT_PLAYER_SPEED)
		_instance_character_ai_behavior_selector.select(0)
		_instance_character_wander_radius_spin.set_value_no_signal(CHARACTER_CONTROLLER_CATALOG.DEFAULT_WANDER_RADIUS)
		_instance_character_scale_spin.set_value_no_signal(1.0)
		_instance_character_shadow_check.set_pressed_no_signal(true)
		_instance_character_action_selector.select(0)
		_instance_character_direction_selector.select(0)
		_instance_character_loop_check.set_pressed_no_signal(true)
		_instance_character_action_hint.text = "Player Controller 读取键盘输入；AI Controller 可原地活动或区域漫游。"
		_refresh_instance_character_controller_fields()
		return
	var source_name := "实例外观"
	var profile_id := str(object_data.get("character_id", ""))
	var preset_id := str(object_data.get("preset_id", ""))
	if not profile_id.is_empty():
		var profile := _character_profile(profile_id)
		source_name = "人物档案 · %s" % str(profile.get("name", profile_id))
	elif not preset_id.is_empty():
		var preset := _character_preset(preset_id)
		source_name = "语义预设 · %s" % str(preset.get("name", preset_id))
	var cell := _object_cell(object_data)
	_instance_character_source_label.text = "ID: %s · %s · 格子 (%d, %d)" % [str(object_data.get("id", "")), source_name, cell.x, cell.y]
	_instance_character_name_edit.text = str(object_data.get("name", object_data.get("id", "人物")))
	var controller := CHARACTER_CONTROLLER_CATALOG.normalize_controller(object_data.get("controller", {}))
	var controller_type := str(controller.get("type", "none"))
	for controller_index in _instance_character_controller_selector.item_count:
		if str(_instance_character_controller_selector.get_item_metadata(controller_index)) == controller_type:
			_instance_character_controller_selector.select(controller_index)
			break
	_instance_character_speed_spin.set_value_no_signal(float(controller.get("move_speed", CHARACTER_CONTROLLER_CATALOG.default_move_speed(controller_type))))
	var ai_behavior := str(controller.get("behavior", "idle"))
	for behavior_index in _instance_character_ai_behavior_selector.item_count:
		if str(_instance_character_ai_behavior_selector.get_item_metadata(behavior_index)) == ai_behavior:
			_instance_character_ai_behavior_selector.select(behavior_index)
			break
	_instance_character_wander_radius_spin.set_value_no_signal(float(controller.get("wander_radius", CHARACTER_CONTROLLER_CATALOG.DEFAULT_WANDER_RADIUS)))
	_instance_character_scale_spin.set_value_no_signal(float(object_data.get("scale", 1.0)))
	_instance_character_shadow_check.set_pressed_no_signal(bool(object_data.get("shadow", true)))
	var action_data := _resolve_character_action(object_data)
	var action_id := str(action_data.get("action", "idle"))
	var direction_id := str(action_data.get("direction", "down"))
	for action_index in _instance_character_action_selector.item_count:
		if str(_instance_character_action_selector.get_item_metadata(action_index)) == action_id:
			_instance_character_action_selector.select(action_index)
			break
	for direction_index in _instance_character_direction_selector.item_count:
		if str(_instance_character_direction_selector.get_item_metadata(direction_index)) == direction_id:
			_instance_character_direction_selector.select(direction_index)
			break
	_instance_character_loop_check.set_pressed_no_signal(bool(action_data.get("loop", true)))
	var action_spec := CHARACTER_ACTION_CATALOG.action(action_id)
	var source_label := "素材原生帧" if bool(action_spec.get("native", false)) else "程序化表现"
	var controller_spec := CHARACTER_CONTROLLER_CATALOG.controller(controller_type)
	_instance_character_action_hint.text = "%s\n%s · %s" % [
		str(controller_spec.get("description", "")),
		source_label,
		str(action_spec.get("description", "")),
	]
	_refresh_instance_character_controller_fields()


func _on_instance_character_controller_selected(_index: int) -> void:
	_refresh_instance_character_controller_fields()


func _on_instance_character_ai_behavior_selected(_index: int) -> void:
	_refresh_instance_character_controller_fields()


func _refresh_instance_character_controller_fields() -> void:
	if _instance_character_controller_selector == null:
		return
	var has_character := not _instance_character_controller_selector.disabled
	var controller_type := "none"
	if _instance_character_controller_selector.selected >= 0:
		controller_type = str(_instance_character_controller_selector.get_item_metadata(_instance_character_controller_selector.selected))
	var is_dynamic := has_character and controller_type != CHARACTER_CONTROLLER_CATALOG.TYPE_NONE
	var is_ai := has_character and controller_type == CHARACTER_CONTROLLER_CATALOG.TYPE_AI
	_instance_character_speed_spin.editable = is_dynamic
	_instance_character_ai_behavior_selector.disabled = not is_ai
	var ai_behavior := "idle"
	if _instance_character_ai_behavior_selector.selected >= 0:
		ai_behavior = str(_instance_character_ai_behavior_selector.get_item_metadata(_instance_character_ai_behavior_selector.selected))
	_instance_character_wander_radius_spin.editable = is_ai and ai_behavior == CHARACTER_CONTROLLER_CATALOG.BEHAVIOR_WANDER


func _selected_instance_data() -> Dictionary:
	var objects: Array = _map_data.get(_selected_object_collection, [])
	if _selected_building_index < 0 or _selected_building_index >= objects.size():
		return {}
	return objects[_selected_building_index]


func _apply_selected_instance_rendering() -> void:
	var object_data := _selected_instance_data()
	if object_data.is_empty():
		_set_status("请先选择地图中的对象实例")
		return
	_push_undo_snapshot(_make_undo_snapshot())
	var selected_layer_index := _instance_layer_selector.selected
	object_data["render_layer"] = str(_instance_layer_selector.get_item_metadata(selected_layer_index))
	object_data["render_order"] = clampi(roundi(_instance_render_order_spin.value), ASSET_LIBRARY.RENDER_ORDER_MIN, ASSET_LIBRARY.RENDER_ORDER_MAX)
	_dirty = true
	var selected_index := _selected_building_index
	var selected_collection := _selected_object_collection
	_render_map()
	_select_building(selected_index, selected_collection)
	_set_status("已更新 %s 的实例遮挡顺序" % _selected_building_name)


func _apply_selected_character_action() -> void:
	var object_data := _selected_instance_data()
	if object_data.is_empty() or not MAP_OBJECT_SCRIPT.is_character_asset(str(object_data.get("asset", ""))):
		_set_status("请先选择地图中的人物实例")
		return
	_push_undo_snapshot(_make_undo_snapshot())
	var name_value := _instance_character_name_edit.text.strip_edges().left(48)
	object_data["name"] = name_value if not name_value.is_empty() else str(object_data.get("id", "人物"))
	var controller_index := _instance_character_controller_selector.selected
	var behavior_index := _instance_character_ai_behavior_selector.selected
	var controller := CHARACTER_CONTROLLER_CATALOG.normalize_controller({
		"type": str(_instance_character_controller_selector.get_item_metadata(controller_index)),
		"move_speed": _instance_character_speed_spin.value,
		"behavior": str(_instance_character_ai_behavior_selector.get_item_metadata(behavior_index)),
		"wander_radius": _instance_character_wander_radius_spin.value,
	})
	if str(controller.get("type", "none")) == CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER:
		var characters: Array = _map_data.get("characters", [])
		for character_index in characters.size():
			if _selected_object_collection == "characters" and character_index == _selected_building_index:
				continue
			var other_character: Dictionary = characters[character_index]
			var other_controller := CHARACTER_CONTROLLER_CATALOG.normalize_controller(other_character.get("controller", {}))
			if str(other_controller.get("type", "none")) == CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER:
				other_controller["type"] = CHARACTER_CONTROLLER_CATALOG.TYPE_NONE
				other_character["controller"] = other_controller
	object_data["controller"] = controller
	object_data["scale"] = clampf(float(_instance_character_scale_spin.value), 0.5, 3.0)
	object_data["shadow"] = _instance_character_shadow_check.button_pressed
	var action_index := _instance_character_action_selector.selected
	var direction_index := _instance_character_direction_selector.selected
	object_data["action"] = CHARACTER_ACTION_CATALOG.normalize_action(str(_instance_character_action_selector.get_item_metadata(action_index)))
	object_data["direction"] = CHARACTER_ACTION_CATALOG.normalize_direction(str(_instance_character_direction_selector.get_item_metadata(direction_index)))
	object_data["action_loop"] = _instance_character_loop_check.button_pressed
	_dirty = true
	var selected_index := _selected_building_index
	var selected_collection := _selected_object_collection
	_render_map()
	_select_building(selected_index, selected_collection)
	var controller_name := str(CHARACTER_CONTROLLER_CATALOG.controller(str(controller.get("type", "none"))).get("name", "静态人物"))
	_set_status("已更新 %s：%s" % [_selected_building_name, controller_name])


func _reset_selected_instance_rendering() -> void:
	var object_data := _selected_instance_data()
	if object_data.is_empty():
		_set_status("请先选择地图中的对象实例")
		return
	_push_undo_snapshot(_make_undo_snapshot())
	object_data.erase("render_layer")
	object_data.erase("render_order")
	_dirty = true
	var selected_index := _selected_building_index
	var selected_collection := _selected_object_collection
	_render_map()
	_select_building(selected_index, selected_collection)
	_set_status("已恢复 %s 的素材默认遮挡" % _selected_building_name)


func _update_building_preview(cell: Vector2i) -> void:
	var placing := _object_interaction_mode == OBJECT_MODE_PLACE and _selected_building_index < 0
	var moving_selected := _object_interaction_mode == OBJECT_MODE_MOVE and _selected_building_index >= 0
	var active := _selected_tool == "object" and _is_valid_cell(cell) and (placing or moving_selected)
	_overlay.set("preview_active", active)
	_overlay.set("preview_cell", cell)
	_overlay.set("preview_footprint", _selected_building_footprint)
	_overlay.set("preview_valid", active and _can_place_building(cell, _selected_object_collection, _selected_building_index))
	_overlay.set("selected_active", _selected_building_index >= 0)
	var selected_objects: Array = _map_data.get(_selected_object_collection, [])
	if _selected_building_index >= 0 and _selected_building_index < selected_objects.size():
		var selected_data: Dictionary = selected_objects[_selected_building_index]
		_overlay.set("selected_cell", _object_cell(selected_data))
		_overlay.set("selected_footprint", _object_footprint(selected_data))
	else:
		_overlay.set("selected_cell", Vector2i(-1, -1))
	if not active:
		if _preview_object != null:
			_preview_object.visible = false
		_overlay.queue_redraw()
		return
	_ensure_preview_object()
	_preview_object.visible = true
	_preview_object.position = _object_position(cell)
	_preview_object.modulate = Color(1.0, 1.0, 1.0, 0.58) if bool(_overlay.get("preview_valid")) else Color(1.0, 0.35, 0.35, 0.58)
	_overlay.queue_redraw()


func _ensure_preview_object() -> void:
	if _preview_object != null and is_instance_valid(_preview_object) and str(_preview_object.get("asset_id")) == _selected_building_asset:
		if not MAP_OBJECT_SCRIPT.is_character_asset(_selected_building_asset) or (
			_preview_character_profile_id == _selected_character_profile_id
			and _preview_character_preset_id == _selected_character_preset_id
			and _preview_character_action == _selected_character_action
			and _preview_character_direction == _selected_character_direction
			and _preview_character_action_loop == _selected_character_action_loop
		):
			return
	if _preview_object != null and is_instance_valid(_preview_object):
		_preview_object.free()
	_preview_object = Node2D.new()
	_preview_object.name = "BuildingPreview"
	_preview_object.set_script(MAP_OBJECT_SCRIPT)
	_preview_object.set("asset_id", _selected_building_asset)
	_preview_object.set("object_name", _selected_building_name)
	_preview_object.set("scale_factor", _selected_object_scale)
	_preview_object.set("shadow", false)
	_preview_object.set("character_appearance", _selected_character_appearance.duplicate(true))
	_preview_object.set("character_action", _selected_character_action)
	_preview_object.set("character_direction", _selected_character_direction)
	_preview_object.set("character_action_loop", _selected_character_action_loop)
	_preview_objects.add_child(_preview_object)
	_preview_character_profile_id = _selected_character_profile_id
	_preview_character_preset_id = _selected_character_preset_id
	_preview_character_action = _selected_character_action
	_preview_character_direction = _selected_character_direction
	_preview_character_action_loop = _selected_character_action_loop


func _handle_building_click(cell: Vector2i, erase: bool) -> void:
	if erase:
		var hit := _find_building_at_cell(cell)
		if not hit.is_empty():
			_remove_building(int(hit.get("index", -1)), str(hit.get("collection", "buildings")))
		elif _object_interaction_mode == OBJECT_MODE_PLACE:
			_enter_instance_selection_mode()
		else:
			_set_status("这里没有可删除的对象")
		return
	var hit := _find_building_at_cell(cell)
	if not hit.is_empty():
		_select_building(int(hit.get("index", -1)), str(hit.get("collection", "buildings")))
		return
	if _object_interaction_mode == OBJECT_MODE_SELECT:
		if _selected_building_index >= 0:
			_selected_building_index = -1
			_refresh_instance_rendering_editor()
			_update_building_preview(cell)
			_set_status("已取消实例选择")
		else:
			_set_status("这里没有可选择的地图实例")
		return
	if _object_interaction_mode == OBJECT_MODE_MOVE:
		if _selected_building_index < 0:
			_enter_instance_selection_mode()
			return
		if _can_place_building(cell, _selected_object_collection, _selected_building_index):
			var selected_data: Dictionary = _map_data[_selected_object_collection][_selected_building_index]
			if _object_cell(selected_data) == cell:
				_object_interaction_mode = OBJECT_MODE_SELECT
				_update_building_preview(cell)
				_refresh_object_interaction_ui()
				_set_status("实例位置未变化")
				return
			_push_undo_snapshot(_make_undo_snapshot())
			selected_data["cell"] = [cell.x, cell.y]
			_dirty = true
			var selected_index := _selected_building_index
			var selected_collection := _selected_object_collection
			_render_map()
			_select_building(selected_index, selected_collection)
			_set_status("已移动 %s" % _selected_building_name)
		else:
			_set_status("无法移动：超出地图、碰到水面或与其他对象重叠")
		return
	if _object_interaction_mode != OBJECT_MODE_PLACE:
		_enter_instance_selection_mode()
		return
	if not _can_place_building(cell, "", -1):
		_set_status("无法放置：超出地图、碰到水面或与其他对象重叠")
		return
	_push_undo_snapshot(_make_undo_snapshot())
	var new_building := {
		"id": _new_building_id(_selected_object_collection),
		"name": _selected_building_name,
		"asset": _selected_building_asset,
		"cell": [cell.x, cell.y],
		"footprint": [_selected_building_footprint.x, _selected_building_footprint.y],
		"scale": _selected_object_scale,
		"shadow": _selected_object_shadow,
	}
	if MAP_OBJECT_SCRIPT.is_character_asset(_selected_building_asset):
		if not _selected_character_profile_id.is_empty():
			new_building["character_id"] = _selected_character_profile_id
		if not _selected_character_preset_id.is_empty():
			new_building["preset_id"] = _selected_character_preset_id
		new_building["appearance"] = _selected_character_appearance.duplicate(true)
		new_building["action"] = _selected_character_action
		new_building["direction"] = _selected_character_direction
		new_building["action_loop"] = _selected_character_action_loop
		new_building["controller"] = CHARACTER_CONTROLLER_CATALOG.normalize_controller({})
	_map_data[_selected_object_collection].append(new_building)
	_dirty = true
	_render_map()
	_set_status("已放置 %s" % _selected_building_name)


func _remove_building(index: int, collection := "buildings") -> void:
	var objects: Array = _map_data.get(collection, [])
	if index < 0 or index >= objects.size():
		return
	_push_undo_snapshot(_make_undo_snapshot())
	var removed_name := str(objects[index].get("name", objects[index].get("asset", "对象")))
	objects.remove_at(index)
	_selected_building_index = -1
	_object_interaction_mode = OBJECT_MODE_SELECT
	_refresh_instance_rendering_editor()
	_dirty = true
	_render_map()
	_set_status("已删除 %s" % removed_name)


func _new_building_id(collection: String) -> String:
	var prefix := "building" if collection == "buildings" else ("character" if collection == "characters" else "decoration")
	var base := "%s_%s" % [prefix, _selected_building_asset]
	var id := base
	var suffix := 1
	while _has_building_id(id):
		id = "%s_%d" % [base, suffix]
		suffix += 1
	return id


func _has_building_id(id: String) -> bool:
	for collection in OBJECT_COLLECTIONS:
		for object_data in _map_data.get(collection, []):
			if str(object_data.get("id", "")) == id:
				return true
	return false


func _find_building_at_cell(cell: Vector2i) -> Dictionary:
	for collection in ["characters", "decorations", "buildings"]:
		var objects: Array = _map_data.get(collection, [])
		for index in range(objects.size() - 1, -1, -1):
			var object_data: Dictionary = objects[index]
			if _footprint_contains(object_data, cell) or _object_cell(object_data) == cell:
				return {"collection": collection, "index": index}
	return {}


func _can_place_building(anchor: Vector2i, ignored_collection: String, ignored_index: int) -> bool:
	if not _footprint_in_bounds(anchor, _selected_building_footprint):
		return false
	for y in range(_selected_building_footprint.y):
		for x in range(_selected_building_footprint.x):
			var cell := _footprint_origin(anchor, _selected_building_footprint) + Vector2i(x, y)
			if _water_cells.has(cell):
				return false
	for collection in OBJECT_COLLECTIONS:
		var objects: Array = _map_data.get(collection, [])
		for index in objects.size():
			if collection == ignored_collection and index == ignored_index:
				continue
			if _footprints_overlap(anchor, _selected_building_footprint, objects[index]):
				return false
	return true


func _footprint_in_bounds(anchor: Vector2i, footprint: Vector2i) -> bool:
	var origin := _footprint_origin(anchor, footprint)
	var map_size: Array = _map_data.get("size", [0, 0])
	return origin.x >= 0 and origin.y >= 0 and origin.x + footprint.x <= int(map_size[0]) and origin.y + footprint.y <= int(map_size[1])


func _footprints_overlap(anchor: Vector2i, footprint: Vector2i, object_data: Dictionary) -> bool:
	var other_cell := _object_cell(object_data)
	var other_footprint := _object_footprint(object_data)
	var origin := _footprint_origin(anchor, footprint)
	var other_origin := _footprint_origin(other_cell, other_footprint)
	return origin.x < other_origin.x + other_footprint.x \
		and origin.x + footprint.x > other_origin.x \
		and origin.y < other_origin.y + other_footprint.y \
		and origin.y + footprint.y > other_origin.y


func _footprint_contains(object_data: Dictionary, cell: Vector2i) -> bool:
	var origin := _footprint_origin(_object_cell(object_data), _object_footprint(object_data))
	var footprint := _object_footprint(object_data)
	return cell.x >= origin.x and cell.y >= origin.y and cell.x < origin.x + footprint.x and cell.y < origin.y + footprint.y


func _footprint_origin(anchor: Vector2i, footprint: Vector2i) -> Vector2i:
	return Vector2i(anchor.x - floori(float(footprint.x) / 2.0), anchor.y - footprint.y)


func _object_cell(object_data: Dictionary) -> Vector2i:
	var cell: Array = object_data.get("cell", [0, 0])
	return Vector2i(int(cell[0]), int(cell[1])) if cell.size() >= 2 else Vector2i.ZERO


func _object_footprint(object_data: Dictionary) -> Vector2i:
	var footprint: Array = object_data.get("footprint", [1, 1])
	return Vector2i(maxi(1, int(footprint[0])), maxi(1, int(footprint[1]))) if footprint.size() >= 2 else Vector2i.ONE


func _object_position(cell: Vector2i) -> Vector2:
	return Vector2(cell * TILE_SIZE) + Vector2(TILE_SIZE * 0.5, TILE_SIZE)


func _character_profile(profile_id: String) -> Dictionary:
	if profile_id.is_empty():
		return {}
	for profile_value in _map_data.get("character_profiles", []):
		if profile_value is Dictionary and str(profile_value.get("id", "")) == profile_id:
			return profile_value
	return {}


func _character_preset(preset_id: String) -> Dictionary:
	return CHARACTER_PRESET_LIBRARY.preset(preset_id) if not preset_id.is_empty() else {}


func _resolve_character_appearance(object_data: Dictionary) -> Dictionary:
	if not MAP_OBJECT_SCRIPT.is_character_asset(str(object_data.get("asset", ""))):
		return {}
	var profile := _character_profile(str(object_data.get("character_id", "")))
	if not profile.is_empty():
		return CHARACTER_PART_CATALOG.normalize_appearance(profile.get("appearance", {}))
	var preset := _character_preset(str(object_data.get("preset_id", "")))
	if not preset.is_empty():
		return CHARACTER_PART_CATALOG.normalize_appearance(preset.get("appearance", {}))
	return CHARACTER_PART_CATALOG.normalize_appearance(object_data.get("appearance", {}))


func _resolve_character_action(object_data: Dictionary) -> Dictionary:
	if not MAP_OBJECT_SCRIPT.is_character_asset(str(object_data.get("asset", ""))):
		return {"action": "idle", "direction": "down", "loop": true}
	var source: Dictionary = {}
	var profile := _character_profile(str(object_data.get("character_id", "")))
	if not profile.is_empty():
		source = profile
	else:
		var preset := _character_preset(str(object_data.get("preset_id", "")))
		if not preset.is_empty():
			source = preset
	return {
		"action": CHARACTER_ACTION_CATALOG.normalize_action(str(object_data.get("action", source.get("default_action", "idle")))),
		"direction": CHARACTER_ACTION_CATALOG.normalize_direction(str(object_data.get("direction", source.get("default_direction", "down")))),
		"loop": bool(object_data.get("action_loop", true)),
	}


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_enter_instance_selection_mode()
			get_viewport().set_input_as_handled()
			return
		var command_or_control: bool = event.ctrl_pressed or event.meta_pressed
		if event.keycode == KEY_Z and command_or_control and not event.shift_pressed:
			_undo_last_edit()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_S and command_or_control:
			_save_current_project()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE:
			if _selected_tool == "object" and _selected_building_index >= 0:
				_remove_building(_selected_building_index, _selected_object_collection)
				get_viewport().set_input_as_handled()
				return
	if _pointer_event_is_over_editor_ui(event):
		if event is InputEventPanGesture and _control_contains_screen_position(_asset_list, event.position):
			_scroll_asset_list(event.delta.y)
		if event is InputEventMouseMotion and _is_painting and (event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)) == 0:
			_stop_painting()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMagnifyGesture:
		_zoom_at_screen_position(_camera.zoom.x * event.factor, event.position)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventPanGesture:
		_camera.position += event.delta / _camera.zoom.x
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		var cell := _mouse_cell()
		_overlay.set("hovered_cell", cell)
		_overlay.queue_redraw()
		if _selected_tool == "object":
			_update_building_preview(cell)
			return
		if _is_painting and (event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)) == 0:
			_stop_painting()
			return
		if _is_painting and cell != _last_cell and _is_valid_cell(cell):
			var undo_snapshot := {}
			if not _paint_undo_captured:
				undo_snapshot = _make_undo_snapshot()
			if _paint_segment(_last_cell, cell, (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0) and not _paint_undo_captured:
				_push_undo_snapshot(undo_snapshot)
				_paint_undo_captured = true
			_last_cell = cell
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
				var scroll_factor := maxf(0.01, event.factor)
				_zoom_at_screen_position(_camera.zoom.x * pow(WHEEL_ZOOM_STEP, direction * scroll_factor), event.position)
			get_viewport().set_input_as_handled()
			return
		if event.pressed and (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT):
			get_viewport().gui_release_focus()
		if _selected_tool == "object" and (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT):
			if event.pressed:
				var building_cell := _mouse_cell()
				if _is_valid_cell(building_cell):
					_handle_building_click(building_cell, event.button_index == MOUSE_BUTTON_RIGHT)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				var cell := _mouse_cell()
				if _is_valid_cell(cell):
					_is_painting = true
					_paint_undo_captured = false
					_last_cell = cell
					var undo_snapshot := _make_undo_snapshot()
					if _paint_cell(cell, event.button_index == MOUSE_BUTTON_RIGHT):
						_push_undo_snapshot(undo_snapshot)
						_paint_undo_captured = true
			else:
				_stop_painting()
			get_viewport().set_input_as_handled()
			return
		get_viewport().set_input_as_handled()


func _pointer_event_is_over_editor_ui(event: InputEvent) -> bool:
	if event is InputEventMouse:
		return _screen_position_is_over_editor_ui(event.position)
	if event is InputEventGesture:
		return _screen_position_is_over_editor_ui(event.position)
	return false


func _screen_position_is_over_editor_ui(screen_position: Vector2) -> bool:
	return _control_contains_screen_position(_sidebar, screen_position) \
		or _control_contains_screen_position(_instance_panel, screen_position) \
		or _control_contains_screen_position(_map_header, screen_position)


func _control_contains_screen_position(control: Control, screen_position: Vector2) -> bool:
	return control != null and control.is_visible_in_tree() and control.get_global_rect().has_point(screen_position)


func _mouse_cell() -> Vector2i:
	var world := get_global_mouse_position()
	return Vector2i(floori(world.x / TILE_SIZE), floori(world.y / TILE_SIZE))


func _paint_segment(from_cell: Vector2i, to_cell: Vector2i, erase: bool) -> bool:
	var distance := maxi(absi(to_cell.x - from_cell.x), absi(to_cell.y - from_cell.y))
	var changed := false
	for step in range(distance + 1):
		var amount := float(step) / float(maxi(1, distance))
		var cell := Vector2i(roundi(lerpf(from_cell.x, to_cell.x, amount)), roundi(lerpf(from_cell.y, to_cell.y, amount)))
		if _paint_cell(cell, erase):
			changed = true
	return changed


func _paint_cell(cell: Vector2i, erase: bool) -> bool:
	if not _is_valid_cell(cell):
		return false
	var was_ground := str(_ground_cells.get(cell, ""))
	var was_road := _road_cells.has(cell)
	var was_road_material := str(_road_cells.get(cell, ""))
	var was_field := _field_cells.has(cell)
	var was_field_material := str(_field_cells.get(cell, ""))
	var was_water := _water_cells.has(cell)
	var was_water_material := str(_water_cells.get(cell, ""))
	if erase:
		_ground_cells.erase(cell)
		_road_cells.erase(cell)
		_field_cells.erase(cell)
		_water_cells.erase(cell)
	else:
		var material_id := str(_selected_materials.get(_selected_tool, ASSET_LIBRARY.default_material(_selected_tool)))
		if _selected_tool == "ground":
			var base_ground := str(_map_data.get("terrain", {}).get("base_ground", ASSET_LIBRARY.DEFAULT_GROUND))
			if material_id == base_ground:
				_ground_cells.erase(cell)
			else:
				_ground_cells[cell] = material_id
			_road_cells.erase(cell)
			_field_cells.erase(cell)
			_water_cells.erase(cell)
		elif _selected_tool == "road":
			_road_cells[cell] = material_id
			_field_cells.erase(cell)
			_water_cells.erase(cell)
		elif _selected_tool == "field":
			_field_cells[cell] = material_id
			_road_cells.erase(cell)
			_water_cells.erase(cell)
		elif _selected_tool == "water":
			_water_cells[cell] = material_id
			_road_cells.erase(cell)
			_field_cells.erase(cell)
	var changed := was_ground != str(_ground_cells.get(cell, "")) \
		or was_road != _road_cells.has(cell) or was_road_material != str(_road_cells.get(cell, "")) \
		or was_field != _field_cells.has(cell) or was_field_material != str(_field_cells.get(cell, "")) \
		or was_water != _water_cells.has(cell) or was_water_material != str(_water_cells.get(cell, ""))
	if not changed:
		return false
	_render_ground_cell(cell)
	_refresh_terrain()
	_dirty = true
	return true


func _refresh_terrain() -> void:
	TOWN_MAP_RULES.build_roads(_roads, _road_cells)
	_fields.clear()
	_water.clear()
	for cell_value in _field_cells.keys():
		TOWN_MAP_RULES.set_material_cell(_fields, cell_value, str(_field_cells[cell_value]))
	for cell_value in _water_cells.keys():
		TOWN_MAP_RULES.set_material_cell(_water, cell_value, str(_water_cells[cell_value]))


func _render_ground_cell(cell: Vector2i) -> void:
	var base_ground := str(_map_data.get("terrain", {}).get("base_ground", ASSET_LIBRARY.DEFAULT_GROUND))
	TOWN_MAP_RULES.set_material_cell(_ground, cell, str(_ground_cells.get(cell, base_ground)))


func _extract_cells() -> void:
	var layers: Dictionary = _map_data.get("layers", {})
	_ground_cells = TOWN_MAP_RULES.collect_material_cells(layers.get("ground", []), ASSET_LIBRARY.DEFAULT_GROUND)
	_road_cells = TOWN_MAP_RULES.collect_material_cells(layers.get("roads", []), ASSET_LIBRARY.DEFAULT_ROAD)
	_field_cells = TOWN_MAP_RULES.collect_material_cells(layers.get("fields", []), ASSET_LIBRARY.DEFAULT_FIELD)
	_water_cells = TOWN_MAP_RULES.collect_material_cells(layers.get("water", []), ASSET_LIBRARY.DEFAULT_WATER)


func _render_map(fit_camera := false) -> void:
	_ground.clear()
	var map_size: Array = _map_data.get("size", [48, 32])
	for y in range(int(map_size[1])):
		for x in range(int(map_size[0])):
			_render_ground_cell(Vector2i(x, y))
	_refresh_terrain()
	_clear_object_layers()
	for object_data in _map_data.get("buildings", []):
		_add_map_object(object_data)
	for object_data in _map_data.get("decorations", []):
		_add_map_object(object_data)
	for object_data in _map_data.get("characters", []):
		_add_map_object(object_data)
	_preview_object = null
	_preview_character_profile_id = ""
	_preview_character_preset_id = ""
	_preview_character_action = ""
	_preview_character_direction = ""
	_preview_character_action_loop = true
	_overlay.set("map_size", Vector2i(int(map_size[0]), int(map_size[1])))
	_overlay.queue_redraw()
	if fit_camera:
		_fit_camera()
	_update_map_info()


func _add_map_object(object_data: Dictionary) -> void:
	var object := Node2D.new()
	object.name = str(object_data.get("id", object_data.get("asset", "Object")))
	object.set_script(MAP_OBJECT_SCRIPT)
	object.set("asset_id", str(object_data.get("asset", "")))
	object.set("object_name", str(object_data.get("name", "")))
	object.set("scale_factor", float(object_data.get("scale", 1.0)))
	object.set("shadow", bool(object_data.get("shadow", true)))
	object.set("render_order", ASSET_LIBRARY.object_render_order(object_data))
	object.set("character_appearance", _resolve_character_appearance(object_data))
	var character_action := _resolve_character_action(object_data)
	object.set("character_action", str(character_action.get("action", "idle")))
	object.set("character_direction", str(character_action.get("direction", "down")))
	object.set("character_action_loop", bool(character_action.get("loop", true)))
	var cell: Array = object_data.get("cell", [0, 0])
	object.position = Vector2(Vector2i(int(cell[0]), int(cell[1])) * TILE_SIZE) + Vector2(TILE_SIZE * 0.5, TILE_SIZE)
	_object_layer_node(ASSET_LIBRARY.object_render_layer(object_data)).add_child(object)


func _object_layer_node(render_layer: String) -> Node2D:
	match ASSET_LIBRARY.normalize_render_layer(render_layer):
		ASSET_LIBRARY.RENDER_LAYER_GROUND_DECAL:
			return _ground_decal_objects
		ASSET_LIBRARY.RENDER_LAYER_FOREGROUND:
			return _foreground_objects
		_:
			return _world_objects


func _clear_object_layers() -> void:
	for layer in [_ground_decal_objects, _world_objects, _foreground_objects, _preview_objects]:
		for child in layer.get_children():
			child.free()


func _save_current_project() -> bool:
	if _current_project_id.is_empty() or _map_data.is_empty():
		_set_status("请先创建小镇项目，再保存或运行")
		return false
	_sync_map_data()
	var project_name := _project_name_edit.text.strip_edges()
	if project_name.is_empty():
		project_name = _current_project_id
	if TOWN_PROJECT.save_project(_current_project_id, project_name, _map_data):
		_current_project_name = project_name
		_dirty = false
		if _current_project_source == "user":
			TOWN_PROJECT.set_publish_metadata(_current_project_id, _author_name_edit.text, _description_edit.text)
		_set_status("已保存：user://towns/%s/map.json" % _current_project_id)
		_refresh_projects(_current_project_id, false)
		return true
	else:
		_set_status("保存失败，请检查本地写入权限")
		return false


func _sync_map_data() -> void:
	var map_size: Array = _map_data.get("size", [48, 32])
	_map_data["size"] = [int(map_size[0]), int(map_size[1])]
	_map_data["layers"]["ground"] = TOWN_MAP_RULES.material_cells_to_rects(_ground_cells)
	_map_data["layers"]["roads"] = TOWN_MAP_RULES.material_cells_to_rects(_road_cells)
	_map_data["layers"]["fields"] = TOWN_MAP_RULES.material_cells_to_rects(_field_cells)
	_map_data["layers"]["water"] = TOWN_MAP_RULES.material_cells_to_rects(_water_cells)


func _run_current_project() -> void:
	if not _save_current_project():
		return
	RunMode.town_id = _current_project_id
	RunMode.town_editor = false
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(RUNTIME_SCENE)


func _on_publish_pressed() -> void:
	if _publish_busy:
		return
	if _current_project_source != "user":
		_set_status("内置或下载的小镇不能直接发布，请先创建自己的小镇项目")
		return
	if not _save_current_project():
		return
	var manifest := TOWN_PROJECT.load_manifest(_current_project_id)
	var published_id := str(manifest.get("published_id", ""))
	var edit_token := str(manifest.get("edit_token", ""))
	if not published_id.is_empty() and edit_token.is_empty():
		_set_status("无法更新：本机缺少这个小镇的编辑令牌")
		return
	var payload := {
		"name": _current_project_name,
		"authorName": _author_name_edit.text.strip_edges(),
		"description": _description_edit.text.strip_edges(),
		"map": _map_data,
	}
	_publish_was_update = not published_id.is_empty()
	var url := TOWN_HALL_API.town_url(published_id) if _publish_was_update else TOWN_HALL_API.list_url()
	var method := HTTPClient.METHOD_PUT if _publish_was_update else HTTPClient.METHOD_POST
	var request_error := _publish_request.request(url, TOWN_HALL_API.json_headers(edit_token), method, JSON.stringify(payload))
	if request_error != OK:
		_set_status("无法发起发布请求（错误 %d）" % request_error)
		return
	_publish_busy = true
	_refresh_publish_ui(manifest)
	_set_status("正在%s小镇……" % ("更新" if _publish_was_update else "发布"))


func _on_publish_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_publish_busy = false
	var response_error := TOWN_HALL_API.result_error(result, response_code, body)
	if not response_error.is_empty():
		_refresh_publish_ui(TOWN_PROJECT.load_manifest(_current_project_id))
		_set_status("发布失败：%s" % _friendly_publish_error(response_error))
		return
	var payload := TOWN_HALL_API.parse_json_body(body)
	if not _publish_was_update:
		var town_value: Variant = payload.get("town", {})
		if not town_value is Dictionary:
			_set_status("发布失败：服务器没有返回小镇 ID")
			_refresh_publish_ui(TOWN_PROJECT.load_manifest(_current_project_id))
			return
		var published_id := str(town_value.get("id", ""))
		var edit_token := str(payload.get("editToken", ""))
		if published_id.is_empty() or edit_token.is_empty():
			_set_status("发布失败：服务器没有返回编辑凭据")
			_refresh_publish_ui(TOWN_PROJECT.load_manifest(_current_project_id))
			return
		if not TOWN_PROJECT.set_publish_credentials(_current_project_id, published_id, edit_token):
			_set_status("小镇已发布，但本机无法保存后续更新凭据")
			_refresh_publish_ui(TOWN_PROJECT.load_manifest(_current_project_id))
			return
	TOWN_PROJECT.set_publish_metadata(_current_project_id, _author_name_edit.text, _description_edit.text)
	var success_message := "已更新大厅中的小镇" if _publish_was_update else "已发布到小镇大厅"
	_refresh_projects(_current_project_id, false)
	_set_status(success_message)


func _refresh_publish_ui(manifest: Dictionary) -> void:
	if _publish_button == null:
		return
	var can_publish := _current_project_source == "user"
	_publish_button.disabled = _publish_busy or not can_publish
	if _publish_busy:
		_publish_button.text = "正在提交……"
	elif not can_publish:
		_publish_button.text = "当前项目不可直接发布"
	elif str(manifest.get("published_id", "")).is_empty():
		_publish_button.text = "发布到大厅"
	else:
		_publish_button.text = "更新大厅地图"


func _friendly_publish_error(error_code: String) -> String:
	return {
		"name_required": "请填写小镇名称",
		"map_required": "地图数据为空",
		"invalid_map_size": "地图尺寸必须在 8 到 256 格之间",
		"map_too_large": "地图文件超过服务器限制",
		"too_many_buildings": "建筑数量超过服务器限制",
		"town_not_found": "服务器上的小镇已经不存在",
		"invalid_edit_token": "编辑令牌失效，无法覆盖服务器版本",
	}.get(error_code, error_code)


func _return_to_lobby() -> void:
	if _dirty and not _save_current_project():
		return
	var target_scene := LOCAL_MANAGER_SCENE if RunMode.editor_return_to_manager else LOBBY_SCENE
	RunMode.town_editor = false
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(target_scene)


func _fit_camera() -> void:
	if _map_data.is_empty():
		return
	var map_size: Array = _map_data.get("size", [48, 32])
	var map_pixels := Vector2(float(map_size[0]), float(map_size[1])) * TILE_SIZE
	var viewport_size := get_viewport_rect().size
	var available := Vector2(maxf(320.0, viewport_size.x - MAP_AREA_LEFT - MAP_AREA_RIGHT), maxf(480.0, viewport_size.y - 100.0))
	var zoom_value := minf(1.0, minf(available.x / maxf(1.0, map_pixels.x), available.y / maxf(1.0, map_pixels.y)))
	_set_zoom(zoom_value)
	var target_screen := Vector2(MAP_AREA_LEFT, 16.0) + available * 0.5
	var screen_center := viewport_size * 0.5
	_camera.position = map_pixels * 0.5 - (target_screen - screen_center) / _camera.zoom.x


func _set_zoom(value: float) -> void:
	var zoom_value := clampf(value, MIN_ZOOM, MAX_ZOOM)
	_camera.zoom = Vector2.ONE * zoom_value


func _zoom_at_screen_position(value: float, screen_position: Vector2) -> void:
	var old_zoom := _camera.zoom.x
	var new_zoom := clampf(value, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(old_zoom, new_zoom):
		return
	var viewport_center := get_viewport_rect().size * 0.5
	var offset_from_center := screen_position - viewport_center
	var world_position := _camera.position + offset_from_center / old_zoom
	_camera.zoom = Vector2.ONE * new_zoom
	_camera.position = world_position - offset_from_center / new_zoom


func _make_undo_snapshot() -> Dictionary:
	var snapshot: Dictionary = _map_data.duplicate(true)
	var layers_value: Variant = snapshot.get("layers", {})
	var layers: Dictionary = layers_value if layers_value is Dictionary else {}
	snapshot["layers"] = layers
	layers["ground"] = TOWN_MAP_RULES.material_cells_to_rects(_ground_cells)
	layers["roads"] = TOWN_MAP_RULES.material_cells_to_rects(_road_cells)
	layers["fields"] = TOWN_MAP_RULES.material_cells_to_rects(_field_cells)
	layers["water"] = TOWN_MAP_RULES.material_cells_to_rects(_water_cells)
	return snapshot


func _push_undo_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	if _undo_stack.size() >= UNDO_LIMIT:
		_undo_stack.pop_front()
	_undo_stack.append(snapshot)


func _clear_undo_history() -> void:
	_undo_stack.clear()
	_stop_painting()


func _stop_painting() -> void:
	_is_painting = false
	_paint_undo_captured = false
	_last_cell = Vector2i(-1, -1)


func _undo_last_edit() -> void:
	if _undo_stack.is_empty():
		_set_status("没有可撤销的编辑")
		return
	var previous_size: Array = _map_data.get("size", [0, 0])
	_map_data = _undo_stack.pop_back().duplicate(true)
	var restored_size: Array = _map_data.get("size", [0, 0])
	_width_spin.set_value_no_signal(int(restored_size[0]))
	_height_spin.set_value_no_signal(int(restored_size[1]))
	_selected_building_index = -1
	_object_interaction_mode = OBJECT_MODE_SELECT
	_extract_cells()
	_render_map(previous_size != restored_size)
	_refresh_character_editor()
	_refresh_instance_rendering_editor()
	_update_building_preview(_mouse_cell())
	_dirty = true
	_set_status("已撤销上一步编辑")


func _filter_cells(cells: Dictionary, bounds: Vector2i) -> Dictionary:
	var filtered := {}
	for cell_value in cells.keys():
		var cell: Vector2i = cell_value
		if cell.x >= 0 and cell.y >= 0 and cell.x < bounds.x and cell.y < bounds.y:
			filtered[cell] = cells[cell]
	return filtered


func _clip_rect_specs(specs: Variant, bounds: Vector2i) -> Array:
	var clipped: Array = []
	if not specs is Array:
		return clipped
	for spec in specs:
		if not spec is Dictionary:
			continue
		var origin := Vector2i(int(spec.get("x", 0)), int(spec.get("y", 0)))
		var width := int(spec.get("width", 1))
		var height := int(spec.get("height", 1))
		var finish := Vector2i(origin.x + width, origin.y + height)
		var clipped_origin := Vector2i(maxi(0, origin.x), maxi(0, origin.y))
		var clipped_finish := Vector2i(mini(bounds.x, finish.x), mini(bounds.y, finish.y))
		if clipped_finish.x <= clipped_origin.x or clipped_finish.y <= clipped_origin.y:
			continue
		var copy: Dictionary = spec.duplicate(true)
		copy["x"] = clipped_origin.x
		copy["y"] = clipped_origin.y
		copy["width"] = clipped_finish.x - clipped_origin.x
		copy["height"] = clipped_finish.y - clipped_origin.y
		clipped.append(copy)
	return clipped


func _clip_objects(objects: Variant, bounds: Vector2i) -> Array:
	var clipped: Array = []
	if not objects is Array:
		return clipped
	for object_data in objects:
		if not object_data is Dictionary:
			continue
		var cell: Array = object_data.get("cell", [-1, -1])
		if cell.size() < 2:
			continue
		if int(cell[0]) < 0 or int(cell[1]) < 0 or int(cell[0]) >= bounds.x or int(cell[1]) >= bounds.y:
			continue
		clipped.append(object_data.duplicate(true))
	return clipped


func _is_valid_cell(cell: Vector2i) -> bool:
	var map_size: Array = _map_data.get("size", [0, 0])
	return cell.x >= 0 and cell.y >= 0 and cell.x < int(map_size[0]) and cell.y < int(map_size[1])


func _update_map_info() -> void:
	if _map_info_label == null or _map_data.is_empty():
		return
	var map_size: Array = _map_data.get("size", [0, 0])
	_map_info_label.text = "当前：%s\n尺寸：%d × %d\n草地变体：%d 格 · 道路：%d 格 · 农田：%d 格 · 水面：%d 格\n建筑：%d 个 · 装饰：%d 个 · 人物：%d 个\n\n同材质道路会自动拼接；不同道路材质在交界处各自收边。" % [
		_current_project_name,
		int(map_size[0]),
		int(map_size[1]),
		_ground_cells.size(),
		_road_cells.size(),
		_field_cells.size(),
		_water_cells.size(),
		_map_data.get("buildings", []).size(),
		_map_data.get("decorations", []).size(),
		_map_data.get("characters", []).size(),
	]


func _on_viewport_resized() -> void:
	if _map_data.is_empty():
		return
	var sidebar := _ui.get_node_or_null("Root/Sidebar")
	if sidebar != null:
		sidebar.size.y = maxf(600.0, get_viewport_rect().size.y - 32.0)
	_fit_camera()


func _set_status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message + ("  *未保存" if _dirty else "")


func _tool_label(tool_id: String) -> String:
	return {"ground": "草地", "road": "道路", "field": "农田", "water": "水面", "object": "对象"}.get(tool_id, tool_id)


func _section_label(text_value: String) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_color_override("font_color", Color(0.35, 0.88, 0.92))
	label.add_theme_font_size_override("font_size", 14)
	return label


func _small_label(text_value: String) -> Label:
	var label := Label.new()
	label.text = text_value
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.custom_minimum_size.x = 22
	return label


func _new_spin(minimum: int, maximum: int, value: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spin


func _panel_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style
