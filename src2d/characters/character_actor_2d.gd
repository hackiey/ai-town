@tool
class_name CharacterActor2D
extends CharacterBody2D

const CHARACTER_VISUAL_SCRIPT := preload("res://src2d/characters/character_visual_2d.gd")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")
const CHARACTER_CONTROLLER_CATALOG := preload("res://src2d/characters/character_controller_catalog.gd")

@export var move_speed := CHARACTER_CONTROLLER_CATALOG.DEFAULT_PLAYER_SPEED
@export var map_size_cells := Vector2i(96, 64)
@export var controller_type := CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER
@export var ai_behavior := CHARACTER_CONTROLLER_CATALOG.BEHAVIOR_IDLE
@export var wander_radius := CHARACTER_CONTROLLER_CATALOG.DEFAULT_WANDER_RADIUS
@export var shadow := true
@export var scale_factor := 1.0

var character_appearance: Dictionary = {}
var character_action := "idle"
var character_direction := "down"
var character_action_loop := true

var _visual: Node2D
var _action_movement_locked := false
var _was_moving := false
var _default_action_completed := false
var _spawn_position := Vector2.ZERO
var _ai_target := Vector2.ZERO
var _has_ai_target := false
var _ai_wait_remaining := 0.0


func _ready() -> void:
	controller_type = CHARACTER_CONTROLLER_CATALOG.normalize_type(controller_type)
	ai_behavior = CHARACTER_CONTROLLER_CATALOG.normalize_ai_behavior(ai_behavior)
	move_speed = clampf(move_speed, CHARACTER_CONTROLLER_CATALOG.MIN_MOVE_SPEED, CHARACTER_CONTROLLER_CATALOG.MAX_MOVE_SPEED)
	wander_radius = clampf(wander_radius, CHARACTER_CONTROLLER_CATALOG.MIN_WANDER_RADIUS, CHARACTER_CONTROLLER_CATALOG.MAX_WANDER_RADIUS)
	scale_factor = clampf(scale_factor, 0.25, 4.0)
	_spawn_position = position
	_ensure_collision_shape()
	_ensure_character_visual()
	_apply_visual_state()
	queue_redraw()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var direction := Vector2.ZERO
	if not _action_movement_locked:
		match controller_type:
			CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER:
				direction = _read_move_input()
			CHARACTER_CONTROLLER_CATALOG.TYPE_AI:
				direction = _read_ai_input(delta)
	velocity = direction * move_speed
	_update_visual_motion(direction)
	move_and_slide()
	global_position.x = clampf(global_position.x, 16.0, map_size_cells.x * 32.0 - 16.0)
	global_position.y = clampf(global_position.y, 16.0, map_size_cells.y * 32.0 - 16.0)


func configure_from_instance(object_data: Dictionary, resolved_appearance: Dictionary) -> void:
	var controller := CHARACTER_CONTROLLER_CATALOG.normalize_controller(object_data.get("controller", {}))
	controller_type = str(controller.get("type", CHARACTER_CONTROLLER_CATALOG.TYPE_NONE))
	move_speed = float(controller.get("move_speed", CHARACTER_CONTROLLER_CATALOG.default_move_speed(controller_type)))
	ai_behavior = str(controller.get("behavior", CHARACTER_CONTROLLER_CATALOG.BEHAVIOR_IDLE))
	wander_radius = float(controller.get("wander_radius", CHARACTER_CONTROLLER_CATALOG.DEFAULT_WANDER_RADIUS))
	shadow = bool(object_data.get("shadow", true))
	scale_factor = clampf(float(object_data.get("scale", 1.0)), 0.25, 4.0)
	character_appearance = CHARACTER_PART_CATALOG.normalize_appearance(resolved_appearance)
	character_action = CHARACTER_ACTION_CATALOG.normalize_action(str(object_data.get("action", "idle")))
	character_direction = CHARACTER_ACTION_CATALOG.normalize_direction(str(object_data.get("direction", "down")))
	character_action_loop = bool(object_data.get("action_loop", true))
	_default_action_completed = false
	_has_ai_target = false
	_ai_wait_remaining = 0.0
	_spawn_position = position
	if is_inside_tree():
		_ensure_collision_shape()
		_ensure_character_visual()
		_apply_visual_state()
		queue_redraw()


func set_spawn_position(value: Vector2) -> void:
	_spawn_position = value
	_has_ai_target = false


func set_character_appearance(value: Dictionary) -> void:
	character_appearance = CHARACTER_PART_CATALOG.normalize_appearance(value)
	_ensure_character_visual()
	if _visual != null and _visual.has_method("set_appearance"):
		_visual.call("set_appearance", character_appearance)
	queue_redraw()


func play_character_action(action_id: String, loop_value := false, lock_movement := true) -> void:
	_ensure_character_visual()
	_action_movement_locked = lock_movement
	velocity = Vector2.ZERO if lock_movement else velocity
	if _visual != null and _visual.has_method("play_action"):
		_visual.call("play_action", CHARACTER_ACTION_CATALOG.normalize_action(action_id), loop_value)


func stop_character_action() -> void:
	_action_movement_locked = false
	_apply_default_action()


func _read_move_input() -> Vector2:
	var actions := ["move_left", "move_right", "move_up", "move_down"]
	for action in actions:
		if not InputMap.has_action(action):
			return Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	return Input.get_vector(actions[0], actions[1], actions[2], actions[3])


func _read_ai_input(delta: float) -> Vector2:
	if ai_behavior != CHARACTER_CONTROLLER_CATALOG.BEHAVIOR_WANDER:
		return Vector2.ZERO
	if _ai_wait_remaining > 0.0:
		_ai_wait_remaining = maxf(0.0, _ai_wait_remaining - delta)
		return Vector2.ZERO
	if not _has_ai_target:
		_pick_ai_target()
		return Vector2.ZERO
	if position.distance_to(_ai_target) <= 6.0:
		_has_ai_target = false
		_ai_wait_remaining = randf_range(0.8, 2.4)
		return Vector2.ZERO
	return position.direction_to(_ai_target)


func _pick_ai_target() -> void:
	var radius_pixels := wander_radius * 32.0
	for _attempt in 8:
		var angle := randf_range(0.0, TAU)
		var distance := sqrt(randf()) * radius_pixels
		var candidate := _spawn_position + Vector2.from_angle(angle) * distance
		candidate.x = clampf(candidate.x, 16.0, map_size_cells.x * 32.0 - 16.0)
		candidate.y = clampf(candidate.y, 16.0, map_size_cells.y * 32.0 - 16.0)
		if candidate.distance_to(position) > 12.0:
			_ai_target = candidate
			_has_ai_target = true
			return
	_ai_wait_remaining = 1.0


func _update_visual_motion(direction: Vector2) -> void:
	if _visual == null:
		return
	var moving_now := direction.length_squared() > 0.001
	if moving_now:
		if not _was_moving and _visual.has_method("stop_action"):
			_visual.call("stop_action")
		if _visual.has_method("set_motion"):
			_visual.call("set_motion", direction, true)
	elif _was_moving:
		_apply_default_action()
	elif character_action == "idle" and _visual.has_method("set_motion"):
		_visual.call("set_motion", Vector2.ZERO, false)
	_was_moving = moving_now


func _apply_visual_state() -> void:
	if _visual == null:
		return
	if _visual.has_method("set_appearance"):
		_visual.call("set_appearance", character_appearance)
	if _visual.has_method("set_base_scale"):
		_visual.call("set_base_scale", Vector2.ONE * scale_factor)
	else:
		_visual.scale = Vector2.ONE * scale_factor
	if _visual.has_method("set_direction_row"):
		_visual.call("set_direction_row", CHARACTER_ACTION_CATALOG.direction_row(character_direction))
	_apply_default_action()


func _apply_default_action() -> void:
	if _visual == null:
		return
	if _default_action_completed and not character_action_loop:
		if _visual.has_method("stop_action"):
			_visual.call("stop_action")
		return
	if _visual.has_method("set_action"):
		_visual.call("set_action", character_action, character_action_loop)


func _ensure_collision_shape() -> void:
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision == null:
		collision = CollisionShape2D.new()
		collision.name = "CollisionShape2D"
		add_child(collision)
	var shape := CircleShape2D.new()
	shape.radius = 12.0 * scale_factor
	collision.shape = shape


func _ensure_character_visual() -> void:
	if _visual != null and is_instance_valid(_visual):
		return
	_visual = Node2D.new()
	_visual.name = "CharacterVisual"
	_visual.set_script(CHARACTER_VISUAL_SCRIPT)
	_visual.set("appearance", CHARACTER_PART_CATALOG.normalize_appearance(character_appearance))
	_visual.set("action_id", CHARACTER_ACTION_CATALOG.normalize_action(character_action))
	_visual.set("action_loop", character_action_loop)
	_visual.set("direction_row", CHARACTER_ACTION_CATALOG.direction_row(character_direction))
	_visual.scale = Vector2.ONE * scale_factor
	add_child(_visual)
	if _visual.has_signal("action_finished") and not _visual.is_connected("action_finished", _on_character_action_finished):
		_visual.connect("action_finished", _on_character_action_finished)


func _on_character_action_finished(action_id: String) -> void:
	_action_movement_locked = false
	if action_id == character_action and not character_action_loop:
		_default_action_completed = true
	else:
		_apply_default_action()


func _draw() -> void:
	if not shadow:
		return
	draw_set_transform(Vector2(0.0, 3.0), 0.0, Vector2(1.0, 0.42))
	draw_circle(Vector2.ZERO, 13.0 * scale_factor, Color(0.08, 0.07, 0.04, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
