@tool
class_name CharacterVisual2D
extends Node2D

const PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")

signal action_finished(action_id: String)

var appearance: Dictionary = {}
var direction_row := 0
var moving := false
var action_id := "idle"
var action_loop := true
var animation_speed_scale := 1.0

var _sprites: Array[Sprite2D] = []
var _animation_time := 0.0
var _sequence_index := 0
var _motion_driven := true
var _base_position := Vector2.ZERO
var _base_rotation := 0.0
var _base_scale := Vector2.ONE


func _ready() -> void:
	_base_position = position
	_base_rotation = rotation
	_base_scale = scale
	action_id = ACTION_CATALOG.normalize_action(action_id)
	direction_row = clampi(direction_row, 0, 3)
	_motion_driven = action_id in ["idle", "walk"]
	_rebuild()
	set_process(true)


func set_appearance(value: Dictionary) -> void:
	appearance = PART_CATALOG.normalize_appearance(value)
	if is_inside_tree():
		_rebuild()


func set_motion(direction: Vector2, is_moving: bool) -> void:
	if direction.length_squared() > 0.001:
		if absf(direction.x) > absf(direction.y):
			direction_row = 2 if direction.x > 0.0 else 1
		else:
			direction_row = 0 if direction.y > 0.0 else 3
	moving = is_moving
	if not _motion_driven:
		_apply_frame()
		return
	_set_action_internal("walk" if moving else "idle", true, true)


func set_action(value: String, loop_value := true) -> void:
	_motion_driven = false
	_set_action_internal(value, loop_value, false)


func play_action(value: String, loop_value := false) -> void:
	set_action(value, loop_value)


func stop_action() -> void:
	_motion_driven = true
	moving = false
	_set_action_internal("idle", true, true)


func current_action() -> String:
	return action_id


func set_direction_row(value: int) -> void:
	direction_row = clampi(value, 0, 3)
	_apply_frame()


func set_base_scale(value: Vector2) -> void:
	_base_scale = value
	scale = value
	_apply_action_effect(ACTION_CATALOG.action(action_id), _animation_time)


func _process(delta: float) -> void:
	if _sprites.is_empty():
		return
	var action_spec := ACTION_CATALOG.action(action_id)
	var sequence: Array = action_spec.get("sequence", [1])
	if sequence.is_empty():
		sequence = [1]
	var fps := maxf(0.01, float(action_spec.get("fps", 1.0)) * animation_speed_scale)
	_animation_time += delta
	var sequence_time := _animation_time * fps
	if not action_loop and sequence_time >= sequence.size():
		var completed_action := action_id
		_motion_driven = true
		moving = false
		_set_action_internal("idle", true, true)
		action_finished.emit(completed_action)
		return
	var next_index := int(floor(sequence_time)) % sequence.size()
	if next_index == _sequence_index:
		_apply_action_effect(action_spec, sequence_time)
	else:
		_sequence_index = next_index
		_apply_frame()
		_apply_action_effect(action_spec, sequence_time)


func _rebuild() -> void:
	for child in get_children():
		child.free()
	_sprites.clear()
	appearance = PART_CATALOG.normalize_appearance(appearance)
	var size := PART_CATALOG.frame_size()
	for part_value in PART_CATALOG.selected_parts(appearance):
		var texture: Texture2D = load(str(part_value.get("path", "")))
		if texture == null:
			continue
		var sprite := Sprite2D.new()
		sprite.name = str(part_value.get("id", "Part")).replace("/", "_")
		sprite.texture = texture
		sprite.region_enabled = true
		sprite.centered = false
		sprite.position = Vector2(-size.x * 0.5, -size.y)
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(sprite)
		_sprites.append(sprite)
	_apply_frame()
	_apply_action_effect(ACTION_CATALOG.action(action_id), 0.0)


func _apply_frame() -> void:
	var size := PART_CATALOG.frame_size()
	var sequence: Array = ACTION_CATALOG.action(action_id).get("sequence", [1])
	if sequence.is_empty():
		sequence = [1]
	var frame_column := int(sequence[clampi(_sequence_index, 0, sequence.size() - 1)])
	var rect := Rect2(frame_column * size.x, direction_row * size.y, size.x, size.y)
	for sprite in _sprites:
		sprite.region_rect = rect


func _set_action_internal(value: String, loop_value: bool, preserve_motion_driver: bool) -> void:
	var normalized := ACTION_CATALOG.normalize_action(value)
	if action_id == normalized and action_loop == loop_value:
		if normalized == "idle":
			_animation_time = 0.0
			_sequence_index = 0
			_apply_frame()
			_apply_action_effect(ACTION_CATALOG.action(action_id), 0.0)
		return
	action_id = normalized
	action_loop = loop_value
	if not preserve_motion_driver:
		_motion_driven = false
	_animation_time = 0.0
	_sequence_index = 0
	_apply_frame()
	_apply_action_effect(ACTION_CATALOG.action(action_id), 0.0)


func _apply_action_effect(action_spec: Dictionary, sequence_time: float) -> void:
	position = _base_position
	rotation = _base_rotation
	scale = _base_scale
	modulate = Color.WHITE
	var effect := str(action_spec.get("effect", "none"))
	var wave := sin(sequence_time * TAU / maxf(1.0, float(action_spec.get("sequence", [1]).size())))
	var pulse := (sin(sequence_time * PI) + 1.0) * 0.5
	match effect:
		"guard":
			position.y += wave * 0.7
		"forge":
			position.y += absf(wave) * 1.5
			rotation += wave * 0.035
		"gather":
			position.y += pulse * 1.8
			scale = _base_scale * Vector2(1.0 + pulse * 0.015, 1.0 - pulse * 0.035)
		"attack":
			position += _direction_vector() * pulse * 4.0
			scale = _base_scale * (1.0 + pulse * 0.025)
		"cast":
			position.y -= pulse * 1.5
			scale = _base_scale * (1.0 + pulse * 0.04)
			modulate = Color(0.78 + pulse * 0.22, 0.84 + pulse * 0.16, 1.0, 1.0)
		"brew":
			rotation += wave * 0.025
			position.y += absf(wave) * 0.8
		"pray":
			position.y -= wave * 0.7
			modulate = Color(1.0, 0.92 + pulse * 0.08, 0.72 + pulse * 0.28, 1.0)
		"trade":
			position.y -= absf(wave) * 1.0
		"perform":
			position.y -= absf(wave) * 2.0
			rotation += wave * 0.045
		"talk":
			position.y -= absf(wave) * 0.8


func _direction_vector() -> Vector2:
	match direction_row:
		1:
			return Vector2.LEFT
		2:
			return Vector2.RIGHT
		3:
			return Vector2.UP
		_:
			return Vector2.DOWN
