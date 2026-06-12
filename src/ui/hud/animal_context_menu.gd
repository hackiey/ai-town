class_name AnimalContextMenu
extends CanvasLayer

# 玩家右键动物时显示的操作菜单（喂养 / 宰杀）。CameraRig 拾取动物后经 EventBus 发信号，
# 这里弹小面板，选完 emit 信号让 town 处理（走近 + 调玩家 husbandry RPC）。
# 镜像 NpcContextMenu，仅按钮不同：只有畜牧动物（is_livestock）才弹（野外动物不弹）。

signal feed_selected(animal: Node)
signal slaughter_selected(animal: Node)

const SCREEN_PADDING := 12.0
const OFFSET := Vector2(8.0, 8.0)

var _panel: PanelContainer = null
var _title: Label = null
var _feed_button: Button = null
var _slaughter_button: Button = null
var _target_animal: Node = null


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.animal_context_menu_requested.connect(_on_requested)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "AnimalContextPanel"
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48, 1.0))
	vbox.add_child(_title)

	vbox.add_child(HSeparator.new())

	_feed_button = Button.new()
	_feed_button.text = tr("ui.animal_menu.feed")
	_feed_button.pressed.connect(_on_feed_pressed)
	vbox.add_child(_feed_button)

	_slaughter_button = Button.new()
	_slaughter_button.text = tr("ui.animal_menu.slaughter")
	_slaughter_button.pressed.connect(_on_slaughter_pressed)
	vbox.add_child(_slaughter_button)


func _on_requested(animal: Node, screen_position: Vector2) -> void:
	if animal == null or not is_instance_valid(animal):
		return
	# 只有畜牧动物弹菜单；野外动物（无 husbandry）不弹。
	if not (animal.has_method("is_livestock") and bool(animal.call("is_livestock"))):
		return
	_target_animal = animal
	var species_id := str(animal.get("species_id"))
	var display := species_id if not species_id.is_empty() else String(animal.name)
	var key := "species.%s" % species_id
	var localized := tr(key)
	if not species_id.is_empty() and localized != key and not localized.is_empty():
		display = localized
	_title.text = display
	_panel.visible = true
	_place_panel.call_deferred(screen_position)


func _place_panel(anchor: Vector2) -> void:
	if not _panel.visible:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var panel_size := _panel.get_combined_minimum_size()
	_panel.size = panel_size
	var pos := anchor + OFFSET
	if pos.x + panel_size.x > viewport_size.x - SCREEN_PADDING:
		pos.x = anchor.x - panel_size.x - OFFSET.x
	if pos.y + panel_size.y > viewport_size.y - SCREEN_PADDING:
		pos.y = anchor.y - panel_size.y - OFFSET.y
	var max_x := maxf(SCREEN_PADDING, viewport_size.x - panel_size.x - SCREEN_PADDING)
	var max_y := maxf(SCREEN_PADDING, viewport_size.y - panel_size.y - SCREEN_PADDING)
	_panel.position = Vector2(clampf(pos.x, SCREEN_PADDING, max_x), clampf(pos.y, SCREEN_PADDING, max_y))


func _unhandled_input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_close()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var rect := Rect2(_panel.position, _panel.size)
		if not rect.has_point((event as InputEventMouseButton).position):
			_close()


func _close() -> void:
	_panel.visible = false
	_target_animal = null


func _on_feed_pressed() -> void:
	var animal := _target_animal
	_close()
	if animal != null and is_instance_valid(animal):
		feed_selected.emit(animal)


func _on_slaughter_pressed() -> void:
	var animal := _target_animal
	_close()
	if animal != null and is_instance_valid(animal):
		slaughter_selected.emit(animal)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.05, 0.96)
	style.border_color = Color(0.88, 0.70, 0.38, 0.85)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	return style
