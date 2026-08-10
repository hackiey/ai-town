class_name CharacterEditorPanel
extends VBoxContainer

signal profile_saved(profile: Dictionary)
signal profile_deleted(profile_id: String)
signal player_profile_selected(profile_id: String)

const PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")
const CHARACTER_VISUAL_SCRIPT := preload("res://src2d/characters/character_visual_2d.gd")
const PRESET_LIBRARY := preload("res://src2d/data/character_preset_library.gd")

var _presets: Array = []
var _profiles: Array = []
var _player_profile_id := ""
var _current_profile_id := ""
var _source_preset_id := ""
var _appearance: Dictionary = {}
var _available_actions: Array = []
var _action_id := "idle"
var _direction_id := "down"
var _syncing_controls := false

var _profile_selector: OptionButton
var _name_edit: LineEdit
var _description_edit: TextEdit
var _preview: TextureRect
var _preview_viewport: SubViewport
var _preview_visual: Node2D
var _direction_selector: OptionButton
var _action_selector: OptionButton
var _action_hint: Label
var _single_selectors := {}
var _multi_selectors := {}
var _delete_button: Button
var _player_button: Button


func _ready() -> void:
	_presets = PRESET_LIBRARY.presets()
	add_theme_constant_override("separation", 10)
	_build_ui()
	_refresh_profile_selector()
	_new_profile()


func set_profiles(profiles_value: Variant, player_profile_id := "") -> void:
	_profiles = profiles_value.duplicate(true) if profiles_value is Array else []
	_player_profile_id = player_profile_id
	_refresh_profile_selector(_current_profile_id)


func select_profile(profile_id: String) -> void:
	if _profile_selector == null:
		return
	for index in _profile_selector.item_count:
		var metadata: Variant = _profile_selector.get_item_metadata(index)
		if metadata is Dictionary and str(metadata.get("kind", "")) == "profile" and str(metadata.get("id", "")) == profile_id:
			_profile_selector.select(index)
			_load_profile(_profile(profile_id))
			return


func _build_ui() -> void:
	var intro := Label.new()
	intro.text = "人物保存的是组件配置，不生成固定成品图。肤色、服装、五官、发型、头饰与附件会按 PSD 原始层级实时叠加。"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", Color(0.62, 0.8, 0.82))
	add_child(intro)

	add_child(_section_label("人物档案"))
	_profile_selector = OptionButton.new()
	_profile_selector.item_selected.connect(_on_profile_selected)
	add_child(_profile_selector)
	var profile_buttons := HBoxContainer.new()
	var new_button := Button.new()
	new_button.text = "新建人物"
	new_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_button.pressed.connect(_new_profile)
	profile_buttons.add_child(new_button)
	_delete_button = Button.new()
	_delete_button.text = "删除档案"
	_delete_button.pressed.connect(_delete_current_profile)
	profile_buttons.add_child(_delete_button)
	add_child(profile_buttons)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "人物名称，例如 铁匠学徒"
	add_child(_name_edit)
	_description_edit = TextEdit.new()
	_description_edit.placeholder_text = "人物语义描述，例如 负责夜间巡逻的老练卫兵"
	_description_edit.custom_minimum_size.y = 66
	_description_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(_description_edit)

	add_child(_section_label("实时预览"))
	var preview_panel := PanelContainer.new()
	preview_panel.custom_minimum_size.y = 168
	var center := CenterContainer.new()
	preview_panel.add_child(center)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(144, 144)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	center.add_child(_preview)
	_preview_viewport = SubViewport.new()
	_preview_viewport.size = Vector2i(48, 48)
	_preview_viewport.transparent_bg = true
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview.add_child(_preview_viewport)
	_preview.texture = _preview_viewport.get_texture()
	_preview_visual = Node2D.new()
	_preview_visual.name = "CharacterActionPreview"
	_preview_visual.set_script(CHARACTER_VISUAL_SCRIPT)
	_preview_visual.position = Vector2(24, 48)
	_preview_viewport.add_child(_preview_visual)
	add_child(preview_panel)
	_direction_selector = OptionButton.new()
	for direction_value in ACTION_CATALOG.directions():
		var direction_index := _direction_selector.item_count
		_direction_selector.add_item(str(direction_value.get("name", direction_value.get("id", ""))))
		_direction_selector.set_item_metadata(direction_index, str(direction_value.get("id", "down")))
	_direction_selector.item_selected.connect(_on_direction_selected)
	add_child(_direction_selector)
	_action_selector = OptionButton.new()
	_action_selector.item_selected.connect(_on_action_selected)
	add_child(_action_selector)
	_action_hint = Label.new()
	_action_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action_hint.add_theme_color_override("font_color", Color(0.62, 0.78, 0.8))
	add_child(_action_hint)

	var quick_row := HBoxContainer.new()
	var random_button := Button.new()
	random_button.text = "随机组合"
	random_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	random_button.pressed.connect(_randomize_appearance)
	quick_row.add_child(random_button)
	var clear_button := Button.new()
	clear_button.text = "清空可选件"
	clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_button.pressed.connect(_clear_optional_parts)
	quick_row.add_child(clear_button)
	add_child(quick_row)

	add_child(_section_label("组件拼接"))
	_build_part_selectors()

	var save_button := Button.new()
	save_button.text = "保存人物档案"
	save_button.custom_minimum_size.y = 40
	save_button.pressed.connect(_save_profile)
	add_child(save_button)
	_player_button = Button.new()
	_player_button.text = "设为当前小镇玩家外观"
	_player_button.custom_minimum_size.y = 36
	_player_button.pressed.connect(_select_as_player)
	add_child(_player_button)


func _build_part_selectors() -> void:
	for group_value in PART_CATALOG.groups():
		if not group_value is Dictionary:
			continue
		var group: Dictionary = group_value
		var group_id := str(group.get("id", ""))
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = PART_CATALOG.group_display_name(group)
		label.custom_minimum_size.x = 112
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(label)
		if bool(group.get("multi", false)):
			var selector := MenuButton.new()
			selector.text = "未选择"
			selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var popup := selector.get_popup()
			for part_value in group.get("parts", []):
				if not part_value is Dictionary:
					continue
				var part_index := popup.item_count
				popup.add_check_item(str(part_value.get("name", part_value.get("id", ""))))
				popup.set_item_metadata(part_index, str(part_value.get("id", "")))
			popup.index_pressed.connect(_on_multi_part_toggled.bind(group_id))
			_multi_selectors[group_id] = selector
			row.add_child(selector)
		else:
			var selector := OptionButton.new()
			selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if not bool(group.get("required", false)):
				selector.add_item("无")
				selector.set_item_metadata(0, "")
			for part_value in group.get("parts", []):
				if not part_value is Dictionary:
					continue
				var part_index := selector.item_count
				selector.add_item(str(part_value.get("name", part_value.get("id", ""))))
				selector.set_item_metadata(part_index, str(part_value.get("id", "")))
			selector.item_selected.connect(_on_single_part_selected.bind(group_id))
			_single_selectors[group_id] = selector
			row.add_child(selector)
		add_child(row)


func _new_profile() -> void:
	_current_profile_id = ""
	_source_preset_id = ""
	if _profile_selector != null and _profile_selector.item_count > 0:
		_profile_selector.select(0)
	if _name_edit != null:
		_name_edit.text = "新人物"
	if _description_edit != null:
		_description_edit.text = ""
	_appearance = PART_CATALOG.default_appearance()
	_available_actions = ACTION_CATALOG.normalize_actions([], "idle")
	_action_id = "idle"
	_direction_id = "down"
	_refresh_action_controls()
	_refresh_part_controls()
	_refresh_preview()
	_refresh_action_buttons()


func _on_profile_selected(index: int) -> void:
	if _syncing_controls or index < 0 or index >= _profile_selector.item_count:
		return
	var metadata: Variant = _profile_selector.get_item_metadata(index)
	if not metadata is Dictionary:
		return
	var kind := str(metadata.get("kind", ""))
	var item_id := str(metadata.get("id", ""))
	if kind == "new":
		_new_profile()
		return
	if kind == "preset":
		_load_preset(PRESET_LIBRARY.preset(item_id))
	elif kind == "profile":
		_load_profile(_profile(item_id))


func _load_preset(preset: Dictionary) -> void:
	if preset.is_empty():
		return
	_current_profile_id = ""
	_source_preset_id = str(preset.get("id", ""))
	_name_edit.text = str(preset.get("name", _source_preset_id))
	_description_edit.text = str(preset.get("description", ""))
	_appearance = PART_CATALOG.normalize_appearance(preset.get("appearance", {}))
	_action_id = ACTION_CATALOG.normalize_action(str(preset.get("default_action", "idle")))
	_available_actions = ACTION_CATALOG.normalize_actions(preset.get("actions", []), _action_id)
	_direction_id = ACTION_CATALOG.normalize_direction(str(preset.get("default_direction", "down")))
	_refresh_action_controls()
	_refresh_part_controls()
	_refresh_preview()
	_refresh_action_buttons()


func _load_profile(profile: Dictionary) -> void:
	if profile.is_empty():
		return
	_current_profile_id = str(profile.get("id", ""))
	_source_preset_id = str(profile.get("source_preset_id", ""))
	_name_edit.text = str(profile.get("name", _current_profile_id))
	_description_edit.text = str(profile.get("description", ""))
	_appearance = PART_CATALOG.normalize_appearance(profile.get("appearance", {}))
	_action_id = ACTION_CATALOG.normalize_action(str(profile.get("default_action", "idle")))
	_available_actions = ACTION_CATALOG.normalize_actions(profile.get("actions", []), _action_id)
	_direction_id = ACTION_CATALOG.normalize_direction(str(profile.get("default_direction", "down")))
	_refresh_action_controls()
	_refresh_part_controls()
	_refresh_preview()
	_refresh_action_buttons()


func _refresh_profile_selector(select_id := "") -> void:
	if _profile_selector == null:
		return
	_syncing_controls = true
	_profile_selector.clear()
	_profile_selector.add_item("＋ 新建人物")
	_profile_selector.set_item_metadata(0, {"kind": "new", "id": ""})
	var selected_index := 0
	for preset_value in _presets:
		if not preset_value is Dictionary:
			continue
		var preset: Dictionary = preset_value
		var preset_id := str(preset.get("id", ""))
		var item_index := _profile_selector.item_count
		_profile_selector.add_item("预设 · %s" % str(preset.get("name", preset_id)))
		_profile_selector.set_item_metadata(item_index, {"kind": "preset", "id": preset_id})
	for profile_value in _profiles:
		if not profile_value is Dictionary:
			continue
		var profile: Dictionary = profile_value
		var profile_id := str(profile.get("id", ""))
		var suffix := "  · 玩家" if profile_id == _player_profile_id else ""
		var item_index := _profile_selector.item_count
		_profile_selector.add_item("小镇 · %s%s" % [str(profile.get("name", profile_id)), suffix])
		_profile_selector.set_item_metadata(item_index, {"kind": "profile", "id": profile_id})
		if profile_id == select_id:
			selected_index = item_index
	_profile_selector.select(selected_index)
	_syncing_controls = false
	if selected_index == 0 and not select_id.is_empty():
		_new_profile()
	_refresh_action_buttons()


func _on_single_part_selected(index: int, group_id: String) -> void:
	if _syncing_controls:
		return
	var selector: OptionButton = _single_selectors[group_id]
	var part_id := str(selector.get_item_metadata(index))
	var selected: Array = [] if part_id.is_empty() else [part_id]
	_appearance["groups"][group_id] = selected
	_appearance = PART_CATALOG.normalize_appearance(_appearance)
	_refresh_preview()


func _on_multi_part_toggled(index: int, group_id: String) -> void:
	if _syncing_controls:
		return
	var selector: MenuButton = _multi_selectors[group_id]
	var popup := selector.get_popup()
	var part_id := str(popup.get_item_metadata(index))
	var selected: Array = _appearance.get("groups", {}).get(group_id, []).duplicate()
	if part_id in selected:
		selected.erase(part_id)
	else:
		selected.append(part_id)
	_appearance["groups"][group_id] = selected
	_refresh_part_controls()
	_refresh_preview()


func _refresh_part_controls() -> void:
	if _single_selectors.is_empty() and _multi_selectors.is_empty():
		return
	_appearance = PART_CATALOG.normalize_appearance(_appearance)
	var appearance_groups: Dictionary = _appearance.get("groups", {})
	_syncing_controls = true
	for group_id_value in _single_selectors.keys():
		var group_id := str(group_id_value)
		var selector: OptionButton = _single_selectors[group_id]
		var selected: Array = appearance_groups.get(group_id, [])
		var selected_id := str(selected[0]) if not selected.is_empty() else ""
		for index in selector.item_count:
			if str(selector.get_item_metadata(index)) == selected_id:
				selector.select(index)
				break
	for group_id_value in _multi_selectors.keys():
		var group_id := str(group_id_value)
		var selector: MenuButton = _multi_selectors[group_id]
		var popup := selector.get_popup()
		var selected: Array = appearance_groups.get(group_id, [])
		var selected_names: Array[String] = []
		for index in popup.item_count:
			var part_id := str(popup.get_item_metadata(index))
			var is_selected := part_id in selected
			popup.set_item_checked(index, is_selected)
			if is_selected:
				selected_names.append(popup.get_item_text(index))
		selector.text = "未选择" if selected_names.is_empty() else (selected_names[0] if selected_names.size() == 1 else "%d 项已选择" % selected_names.size())
	_syncing_controls = false


func _on_direction_selected(index: int) -> void:
	if _syncing_controls:
		return
	_direction_id = ACTION_CATALOG.normalize_direction(str(_direction_selector.get_item_metadata(index)))
	_refresh_preview()


func _on_action_selected(index: int) -> void:
	if _syncing_controls:
		return
	_action_id = ACTION_CATALOG.normalize_action(str(_action_selector.get_item_metadata(index)))
	_refresh_action_hint()
	_refresh_preview()


func _refresh_action_controls() -> void:
	if _action_selector == null or _direction_selector == null:
		return
	_syncing_controls = true
	_action_selector.clear()
	for action_id_value in _available_actions:
		var action_id := ACTION_CATALOG.normalize_action(str(action_id_value))
		var action_spec := ACTION_CATALOG.action(action_id)
		var action_index := _action_selector.item_count
		_action_selector.add_item("动作 · %s" % str(action_spec.get("name", action_id)))
		_action_selector.set_item_metadata(action_index, action_id)
		if action_id == _action_id:
			_action_selector.select(action_index)
	for direction_index in _direction_selector.item_count:
		if str(_direction_selector.get_item_metadata(direction_index)) == _direction_id:
			_direction_selector.select(direction_index)
			break
	_syncing_controls = false
	_refresh_action_hint()


func _refresh_action_hint() -> void:
	if _action_hint == null:
		return
	var action_spec := ACTION_CATALOG.action(_action_id)
	var source_label := "素材原生帧" if bool(action_spec.get("native", false)) else "程序化表现 · 可替换为真实动作帧"
	_action_hint.text = "%s｜%s" % [source_label, str(action_spec.get("description", ""))]


func _refresh_preview() -> void:
	if _preview_visual == null:
		return
	_preview_visual.call("set_appearance", _appearance)
	_preview_visual.call("set_direction_row", ACTION_CATALOG.direction_row(_direction_id))
	_preview_visual.call("set_action", _action_id, true)


func _randomize_appearance() -> void:
	_appearance = PART_CATALOG.random_appearance()
	_refresh_part_controls()
	_refresh_preview()


func _clear_optional_parts() -> void:
	var groups_value: Dictionary = _appearance.get("groups", {})
	for group_value in PART_CATALOG.groups():
		if group_value is Dictionary and not bool(group_value.get("required", false)):
			groups_value[str(group_value.get("id", ""))] = []
	_appearance = PART_CATALOG.normalize_appearance({"groups": groups_value})
	_refresh_part_controls()
	_refresh_preview()


func _save_profile() -> void:
	var display_name := _name_edit.text.strip_edges()
	if display_name.is_empty():
		display_name = "未命名人物"
	var profile_id := _current_profile_id
	if profile_id.is_empty():
		profile_id = _make_profile_id(display_name, _source_preset_id)
	_current_profile_id = profile_id
	var profile := {
		"id": profile_id,
		"name": display_name.left(48),
		"description": _description_edit.text.strip_edges().left(240),
		"actions": ACTION_CATALOG.normalize_actions(_available_actions, _action_id),
		"default_action": ACTION_CATALOG.normalize_action(_action_id),
		"default_direction": ACTION_CATALOG.normalize_direction(_direction_id),
		"appearance": PART_CATALOG.normalize_appearance(_appearance),
	}
	if not _source_preset_id.is_empty():
		profile["source_preset_id"] = _source_preset_id
	profile_saved.emit(profile)


func _delete_current_profile() -> void:
	if _current_profile_id.is_empty():
		return
	profile_deleted.emit(_current_profile_id)
	_new_profile()


func _select_as_player() -> void:
	if _current_profile_id.is_empty():
		return
	player_profile_selected.emit(_current_profile_id)


func _make_profile_id(display_name: String, preferred_base := "") -> String:
	var cleaned := ""
	var source := preferred_base if not preferred_base.is_empty() else display_name
	for character in source.to_lower().replace(" ", "_"):
		if character in "abcdefghijklmnopqrstuvwxyz0123456789_-":
			cleaned += character
	var base := "character_%s" % cleaned if not cleaned.is_empty() else "character"
	var candidate := base.left(48)
	var suffix := 2
	while _has_profile_id(candidate):
		candidate = "%s_%d" % [base.left(43), suffix]
		suffix += 1
	return candidate


func _has_profile_id(profile_id: String) -> bool:
	for profile_value in _profiles:
		if profile_value is Dictionary and str(profile_value.get("id", "")) == profile_id:
			return true
	return false


func _profile(profile_id: String) -> Dictionary:
	for profile_value in _profiles:
		if profile_value is Dictionary and str(profile_value.get("id", "")) == profile_id:
			return profile_value
	return {}


func _refresh_action_buttons() -> void:
	if _delete_button != null:
		_delete_button.disabled = _current_profile_id.is_empty()
	if _player_button != null:
		_player_button.disabled = _current_profile_id.is_empty()
		_player_button.text = "当前玩家外观" if _current_profile_id == _player_profile_id and not _current_profile_id.is_empty() else "设为当前小镇玩家外观"


func _section_label(text_value: String) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_color_override("font_color", Color(0.35, 0.88, 0.92))
	label.add_theme_font_size_override("font_size", 14)
	return label
