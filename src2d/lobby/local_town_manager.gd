extends Control

const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")
const LOBBY_SCENE := "res://src2d/lobby/town_lobby.tscn"
const EDITOR_SCENE := "res://src2d/editor/town_editor.tscn"
const RUNTIME_SCENE := "res://src2d/levels/town_2d.tscn"

var _town_list: VBoxContainer
var _count_label: Label
var _status_label: Label
var _import_dialog: FileDialog


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.025, 0.045, 0.055, 1.0))
	_build_ui()
	_refresh_projects()


func _build_ui() -> void:
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.025, 0.045, 0.055, 1.0)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var accent := ColorRect.new()
	accent.set_anchors_preset(Control.PRESET_TOP_WIDE)
	accent.offset_bottom = 6
	accent.color = Color(0.28, 0.86, 0.75, 0.95)
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.add_child(accent)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 42)
	margin.add_theme_constant_override("margin_right", 42)
	margin.add_theme_constant_override("margin_top", 32)
	margin.add_theme_constant_override("margin_bottom", 32)
	add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 18)
	margin.add_child(page)
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	page.add_child(header)
	var heading := VBoxContainer.new()
	header.add_child(heading)
	var title := Label.new()
	title.text = "小镇项目管理器"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(0.9, 1.0, 0.97))
	heading.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "项目列表保存在应用注册表中，每条记录指向一个小镇工程目录"
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.56, 0.76, 0.76))
	heading.add_child(subtitle)
	var action_row := HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_END
	action_row.add_theme_constant_override("separation", 10)
	header.add_child(action_row)
	var back_button := Button.new()
	back_button.text = "← 返回大厅"
	back_button.custom_minimum_size = Vector2(130, 44)
	back_button.pressed.connect(_return_to_lobby)
	action_row.add_child(back_button)
	var refresh_button := Button.new()
	refresh_button.text = "刷新列表"
	refresh_button.custom_minimum_size = Vector2(116, 44)
	refresh_button.pressed.connect(_refresh_projects)
	action_row.add_child(refresh_button)
	var import_button := Button.new()
	import_button.text = "导入已有小镇"
	import_button.custom_minimum_size = Vector2(142, 44)
	import_button.pressed.connect(_show_import_dialog)
	action_row.add_child(import_button)
	var create_button := Button.new()
	create_button.text = "＋ 新建小镇"
	create_button.custom_minimum_size = Vector2(140, 44)
	create_button.add_theme_color_override("font_color", Color(0.02, 0.12, 0.12))
	create_button.add_theme_stylebox_override("normal", _button_style(Color(0.28, 0.86, 0.75), Color(0.45, 1.0, 0.9)))
	create_button.add_theme_stylebox_override("hover", _button_style(Color(0.38, 0.94, 0.82), Color(0.65, 1.0, 0.94)))
	create_button.pressed.connect(_create_town)
	action_row.add_child(create_button)

	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.04, 0.075, 0.085, 0.98), Color(0.12, 0.32, 0.34)))
	page.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	panel.add_child(content)
	var list_header := HBoxContainer.new()
	content.add_child(list_header)
	var list_title := Label.new()
	list_title.text = "本地项目"
	list_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_title.add_theme_font_size_override("font_size", 22)
	list_header.add_child(list_title)
	_count_label = Label.new()
	_count_label.add_theme_color_override("font_color", Color(0.55, 0.86, 0.8))
	list_header.add_child(_count_label)
	_status_label = Label.new()
	_status_label.text = "注册表：%s" % TOWN_PROJECT.REGISTRY_PATH
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.46, 0.66, 0.66))
	content.add_child(_status_label)
	content.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_town_list = VBoxContainer.new()
	_town_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_town_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_town_list)

	_import_dialog = FileDialog.new()
	_import_dialog.title = "选择包含 town.json 和 map.json 的小镇工程目录"
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.use_native_dialog = true
	_import_dialog.dir_selected.connect(_on_import_directory_selected)
	add_child(_import_dialog)


func _refresh_projects() -> void:
	for child in _town_list.get_children():
		child.free()
	var local_projects := TOWN_PROJECT.list_registered_projects()
	_count_label.text = "%d 个小镇" % local_projects.size()
	if local_projects.is_empty():
		var empty := VBoxContainer.new()
		empty.custom_minimum_size.y = 220
		empty.alignment = BoxContainer.ALIGNMENT_CENTER
		_town_list.add_child(empty)
		var empty_title := Label.new()
		empty_title.text = "还没有本地小镇"
		empty_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_title.add_theme_font_size_override("font_size", 22)
		empty.add_child(empty_title)
		var empty_help := Label.new()
		empty_help.text = "点击“新建小镇”，或导入一个已有的小镇工程目录。"
		empty_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_help.add_theme_color_override("font_color", Color(0.55, 0.72, 0.72))
		empty.add_child(empty_help)
		return
	for project in local_projects:
		_town_list.add_child(_make_project_card(project))


func _make_project_card(project: Dictionary) -> Control:
	var project_id := str(project.get("id", ""))
	var available := bool(project.get("available", false))
	var map_data := TOWN_PROJECT.load_map(project_id) if available else {}
	var map_size: Array = map_data.get("size", [0, 0])
	var published_id := str(project.get("published_id", ""))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _panel_style(Color(0.055, 0.105, 0.115, 1.0), Color(0.12, 0.28, 0.3)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	card.add_child(row)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", 4)
	row.add_child(details)
	var name_label := Label.new()
	name_label.text = str(project.get("name", project_id))
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Color(0.91, 0.98, 0.95))
	details.add_child(name_label)
	var directory_label := Label.new()
	directory_label.text = str(project.get("directory", ""))
	directory_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	directory_label.add_theme_font_size_override("font_size", 12)
	directory_label.add_theme_color_override("font_color", Color(0.42, 0.68, 0.66))
	details.add_child(directory_label)
	var meta := Label.new()
	meta.text = "ID：%s    地图：%d × %d    建筑：%d    %s" % [
		project_id,
		int(map_size[0]) if map_size.size() >= 2 else 0,
		int(map_size[1]) if map_size.size() >= 2 else 0,
		map_data.get("buildings", []).size(),
		"工程可用" if available else "工程路径失效",
	]
	meta.add_theme_color_override("font_color", Color(0.58, 0.76, 0.76))
	details.add_child(meta)
	var publish_state := Label.new()
	publish_state.text = "已发布到大厅" if not published_id.is_empty() else "尚未发布"
	publish_state.add_theme_color_override("font_color", Color(0.42, 0.9, 0.72) if not published_id.is_empty() else Color(0.68, 0.72, 0.72))
	details.add_child(publish_state)
	var run_button := Button.new()
	run_button.text = "运行"
	run_button.custom_minimum_size = Vector2(92, 44)
	run_button.disabled = not available
	run_button.pressed.connect(_run_town.bind(project_id))
	row.add_child(run_button)
	var edit_button := Button.new()
	edit_button.text = "编辑"
	edit_button.custom_minimum_size = Vector2(100, 44)
	edit_button.disabled = not available
	edit_button.pressed.connect(_edit_town.bind(project_id))
	row.add_child(edit_button)
	var remove_button := Button.new()
	remove_button.text = "从列表移除"
	remove_button.custom_minimum_size = Vector2(124, 44)
	remove_button.tooltip_text = "只移除项目路径记录，不删除小镇文件"
	remove_button.pressed.connect(_remove_project.bind(project_id))
	row.add_child(remove_button)
	return card


func _show_import_dialog() -> void:
	_import_dialog.popup_centered_ratio(0.75)


func _on_import_directory_selected(directory_path: String) -> void:
	var project_id := TOWN_PROJECT.register_existing_project(directory_path)
	if project_id.is_empty():
		_set_status("导入失败：所选目录必须包含有效的 town.json 和 map.json", true)
		return
	_refresh_projects()
	_set_status("已把工程路径加入项目列表：%s" % directory_path, false)


func _remove_project(project_id: String) -> void:
	if not TOWN_PROJECT.unregister_project(project_id):
		_set_status("无法从项目列表移除：%s" % project_id, true)
		return
	_refresh_projects()
	_set_status("已从列表移除，工程文件没有被删除：%s" % project_id, false)


func _edit_town(project_id: String) -> void:
	RunMode.town_editor = true
	RunMode.editor_project_id = project_id
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = true
	get_tree().change_scene_to_file(EDITOR_SCENE)


func _run_town(project_id: String) -> void:
	RunMode.town_id = project_id
	RunMode.town_editor = false
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(RUNTIME_SCENE)


func _create_town() -> void:
	RunMode.town_editor = true
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = true
	RunMode.editor_return_to_manager = true
	get_tree().change_scene_to_file(EDITOR_SCENE)


func _return_to_lobby() -> void:
	RunMode.town_editor = false
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(LOBBY_SCENE)


func _set_status(message: String, is_error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.48, 0.42) if is_error else Color(0.5, 0.82, 0.76))


func _panel_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style


func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.content_margin_left = 12
	style.content_margin_right = 12
	return style
