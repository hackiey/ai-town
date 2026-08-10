extends Control

const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")
const TOWN_HALL_API := preload("res://src2d/network/town_hall_api.gd")
const EDITOR_SCENE := "res://src2d/editor/town_editor.tscn"
const RUNTIME_SCENE := "res://src2d/levels/town_2d.tscn"
const LOCAL_MANAGER_SCENE := "res://src2d/lobby/local_town_manager.tscn"

var _request: HTTPRequest
var _request_kind := ""
var _pending_town_id := ""
var _status_label: Label
var _town_list: VBoxContainer
var _refresh_button: Button
var _server_label: Label
var _local_count_label: Label


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.025, 0.045, 0.055, 1.0))
	_request = HTTPRequest.new()
	_request.name = "TownHallRequest"
	add_child(_request)
	_request.request_completed.connect(_on_request_completed)
	_build_ui()
	_refresh_local_count()
	_refresh_towns()


func _build_ui() -> void:
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.025, 0.045, 0.055, 1.0)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	move_child(background, 0)

	var accent := ColorRect.new()
	accent.set_anchors_preset(Control.PRESET_TOP_WIDE)
	accent.offset_bottom = 6
	accent.color = Color(0.22, 0.78, 0.72, 0.95)
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.add_child(accent)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 38)
	margin.add_theme_constant_override("margin_right", 38)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 18)
	margin.add_child(page)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	page.add_child(header)
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	var title := Label.new()
	title.text = "AI 小镇大厅"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(0.9, 1.0, 0.97))
	heading.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "发现玩家发布的小镇，或者创造你自己的世界"
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.56, 0.76, 0.76))
	heading.add_child(subtitle)

	_refresh_button = Button.new()
	_refresh_button.text = "刷新大厅"
	_refresh_button.custom_minimum_size = Vector2(116, 44)
	_refresh_button.pressed.connect(_refresh_towns)
	header.add_child(_refresh_button)
	var manage_button := Button.new()
	manage_button.text = "管理我的小镇"
	manage_button.custom_minimum_size = Vector2(150, 44)
	manage_button.pressed.connect(_open_project_manager)
	header.add_child(manage_button)
	var create_button := Button.new()
	create_button.text = "新建小镇"
	create_button.custom_minimum_size = Vector2(132, 44)
	create_button.add_theme_color_override("font_color", Color(0.02, 0.12, 0.12))
	create_button.add_theme_stylebox_override("normal", _button_style(Color(0.28, 0.86, 0.75), Color(0.45, 1.0, 0.9)))
	create_button.add_theme_stylebox_override("hover", _button_style(Color(0.38, 0.94, 0.82), Color(0.65, 1.0, 0.94)))
	create_button.pressed.connect(_create_town)
	header.add_child(create_button)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 20)
	page.add_child(body)

	var online_panel := PanelContainer.new()
	online_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	online_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.04, 0.075, 0.085, 0.98), Color(0.12, 0.32, 0.34)))
	body.add_child(online_panel)
	var online_content := VBoxContainer.new()
	online_content.add_theme_constant_override("separation", 12)
	online_panel.add_child(online_content)
	var online_header := HBoxContainer.new()
	online_content.add_child(online_header)
	var online_title := Label.new()
	online_title.text = "在线小镇"
	online_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online_title.add_theme_font_size_override("font_size", 22)
	online_header.add_child(online_title)
	_status_label = Label.new()
	_status_label.text = "准备连接服务器"
	_status_label.add_theme_color_override("font_color", Color(0.55, 0.76, 0.76))
	online_header.add_child(_status_label)

	var separator := HSeparator.new()
	online_content.add_child(separator)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	online_content.add_child(scroll)
	_town_list = VBoxContainer.new()
	_town_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_town_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_town_list)

	var side_panel := PanelContainer.new()
	side_panel.custom_minimum_size.x = 320
	side_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.085, 0.095, 0.98), Color(0.18, 0.48, 0.48)))
	body.add_child(side_panel)
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 12)
	side_panel.add_child(side)
	var side_title := Label.new()
	side_title.text = "镇长工作台"
	side_title.add_theme_font_size_override("font_size", 22)
	side.add_child(side_title)
	var intro := Label.new()
	intro.text = "地图保存在本机。编辑完成后，可以发布到大厅；其他玩家下载的是地图副本，不会直接修改你的原始项目。"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", Color(0.68, 0.82, 0.82))
	side.add_child(intro)
	side.add_child(HSeparator.new())
	_local_count_label = Label.new()
	_local_count_label.add_theme_color_override("font_color", Color(0.55, 0.9, 0.82))
	side.add_child(_local_count_label)
	var manage_side_button := Button.new()
	manage_side_button.text = "查看我的本地小镇"
	manage_side_button.custom_minimum_size.y = 42
	manage_side_button.pressed.connect(_open_project_manager)
	side.add_child(manage_side_button)
	var create_side_button := Button.new()
	create_side_button.text = "＋ 新建小镇"
	create_side_button.custom_minimum_size.y = 46
	create_side_button.pressed.connect(_create_town)
	side.add_child(create_side_button)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)
	_server_label = Label.new()
	_server_label.text = "服务器\n%s" % TOWN_HALL_API.base_url()
	_server_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_server_label.add_theme_font_size_override("font_size", 12)
	_server_label.add_theme_color_override("font_color", Color(0.42, 0.62, 0.63))
	side.add_child(_server_label)


func _refresh_towns() -> void:
	if not _request_kind.is_empty():
		return
	_set_busy(true, "list")
	_set_status("正在读取服务器小镇……", false)
	var request_error := _request.request(TOWN_HALL_API.list_url(), TOWN_HALL_API.json_headers())
	if request_error != OK:
		_set_busy(false)
		_set_status("无法发起大厅请求（错误 %d）" % request_error, true)


func _download_town(town_id: String) -> void:
	if not _request_kind.is_empty():
		return
	_pending_town_id = town_id
	_set_busy(true, "download")
	_set_status("正在下载小镇……", false)
	var request_error := _request.request(TOWN_HALL_API.town_url(town_id), TOWN_HALL_API.json_headers())
	if request_error != OK:
		_pending_town_id = ""
		_set_busy(false)
		_set_status("无法发起下载请求（错误 %d）" % request_error, true)


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var completed_kind := _request_kind
	_set_busy(false)
	var response_error := TOWN_HALL_API.result_error(result, response_code, body)
	if not response_error.is_empty():
		_set_status(_friendly_error(response_error), true)
		_pending_town_id = ""
		return
	var payload := TOWN_HALL_API.parse_json_body(body)
	if completed_kind == "list":
		var towns_value: Variant = payload.get("towns", [])
		if not towns_value is Array:
			_set_status("服务器返回了无法识别的小镇列表", true)
			return
		_render_towns(towns_value)
		_set_status("已加载 %d 个小镇" % towns_value.size(), false)
		return
	if completed_kind == "download":
		_open_downloaded_town(payload)


func _render_towns(towns: Array) -> void:
	for child in _town_list.get_children():
		child.free()
	if towns.is_empty():
		var empty := Label.new()
		empty.text = "大厅里还没有小镇。创建并发布第一个吧。"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.custom_minimum_size.y = 120
		empty.add_theme_color_override("font_color", Color(0.55, 0.72, 0.72))
		_town_list.add_child(empty)
		return
	for town_value in towns:
		if town_value is Dictionary:
			_town_list.add_child(_make_town_card(town_value))


func _make_town_card(town: Dictionary) -> Control:
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
	name_label.text = str(town.get("name", "未命名小镇"))
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Color(0.91, 0.98, 0.95))
	details.add_child(name_label)
	var description := str(town.get("description", "")).strip_edges()
	var description_label := Label.new()
	description_label.text = description if not description.is_empty() else "镇长还没有留下介绍。"
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label.add_theme_color_override("font_color", Color(0.64, 0.78, 0.78))
	details.add_child(description_label)
	var meta := Label.new()
	meta.text = "镇长：%s    地图：%d × %d    建筑：%d    更新：%s" % [
		str(town.get("authorName", "匿名镇长")),
		int(town.get("width", 0)),
		int(town.get("height", 0)),
		int(town.get("buildingCount", 0)),
		_format_time(str(town.get("updatedAt", ""))),
	]
	meta.add_theme_font_size_override("font_size", 12)
	meta.add_theme_color_override("font_color", Color(0.42, 0.68, 0.66))
	details.add_child(meta)
	var enter_button := Button.new()
	enter_button.text = "进入小镇"
	enter_button.custom_minimum_size = Vector2(118, 48)
	enter_button.pressed.connect(_download_town.bind(str(town.get("id", ""))))
	row.add_child(enter_button)
	return card


func _open_downloaded_town(payload: Dictionary) -> void:
	var town_value: Variant = payload.get("town", {})
	if not town_value is Dictionary:
		_set_status("服务器没有返回小镇数据", true)
		return
	var town: Dictionary = town_value
	var map_value: Variant = town.get("map", {})
	if not map_value is Dictionary:
		_set_status("下载的小镇缺少地图数据", true)
		return
	var remote_id := str(town.get("id", _pending_town_id))
	var local_id := TOWN_PROJECT.cache_remote_project(remote_id, str(town.get("name", remote_id)), map_value)
	_pending_town_id = ""
	if local_id.is_empty():
		_set_status("小镇下载成功，但无法写入本地缓存", true)
		return
	RunMode.town_id = local_id
	RunMode.town_editor = false
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file.call_deferred(RUNTIME_SCENE)


func _create_town() -> void:
	RunMode.town_editor = true
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = true
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(EDITOR_SCENE)


func _open_project_manager() -> void:
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(LOCAL_MANAGER_SCENE)


func _refresh_local_count() -> void:
	var user_count := TOWN_PROJECT.list_registered_projects().size()
	_local_count_label.text = "本机项目：%d 个" % user_count


func _set_busy(busy: bool, kind := "") -> void:
	_request_kind = kind if busy else ""
	if _refresh_button != null:
		_refresh_button.disabled = busy


func _set_status(message: String, is_error: bool) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.48, 0.42) if is_error else Color(0.55, 0.82, 0.78))


func _friendly_error(error_code: String) -> String:
	return {
		"town_not_found": "这个小镇已经从服务器移除",
		"invalid_map_size": "服务器拒绝了无效地图尺寸",
	}.get(error_code, error_code)


func _format_time(value: String) -> String:
	if value.is_empty():
		return "未知"
	return value.replace("T", " ").trim_suffix("Z").left(16)


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
