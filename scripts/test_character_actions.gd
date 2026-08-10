extends SceneTree

const ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")
const CONTROLLER_CATALOG := preload("res://src2d/characters/character_controller_catalog.gd")
const PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_VISUAL_SCRIPT := preload("res://src2d/characters/character_visual_2d.gd")
const MAP_OBJECT_SCRIPT := preload("res://src2d/world/map_object_2d.gd")
const PRESET_LIBRARY := preload("res://src2d/data/character_preset_library.gd")
const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var actions := ACTION_CATALOG.actions()
	if actions.size() != 12:
		return _fail("人物动作目录不是 12 个动作")
	if not bool(ACTION_CATALOG.action("idle").get("native", false)) or not bool(ACTION_CATALOG.action("walk").get("native", false)):
		return _fail("待机和行走没有标记为素材原生动作")
	for action_value in actions:
		var action_id := str(action_value.get("id", ""))
		if action_id not in ["idle", "walk"] and bool(action_value.get("native", false)):
			return _fail("程序化动作被误标记为素材原生：%s" % action_id)

	for preset_value in PRESET_LIBRARY.presets():
		var preset: Dictionary = preset_value
		var default_action := str(preset.get("default_action", ""))
		if not default_action in preset.get("actions", []):
			return _fail("预设默认动作不在可用动作集合中：%s" % str(preset.get("id", "")))

	var visual := Node2D.new()
	visual.set_script(CHARACTER_VISUAL_SCRIPT)
	visual.set("appearance", PART_CATALOG.default_appearance())
	root.add_child(visual)
	await process_frame
	visual.call("set_direction_row", 2)
	visual.call("set_action", "forge", true)
	visual.call("_process", 0.2)
	var first_sprite := visual.get_child(0) as Sprite2D
	if str(visual.call("current_action")) != "forge" or int(visual.get("direction_row")) != 2:
		return _fail("CharacterVisual2D 没有切换锻造动作和朝向")
	if first_sprite == null or first_sprite.region_rect.position != Vector2(96, 96):
		return _fail("锻造动作没有推进到对应方向的动作帧")
	if is_zero_approx(visual.rotation) and visual.position.is_zero_approx():
		return _fail("程序化锻造动作没有产生姿态变化")
	var finished_actions: Array[String] = []
	visual.connect("action_finished", func(action_id: String) -> void: finished_actions.append(action_id))
	visual.call("play_action", "attack", false)
	visual.call("_process", 1.0)
	if finished_actions != ["attack"] or str(visual.call("current_action")) != "idle":
		return _fail("非循环动作结束后没有回到待机")
	visual.free()

	var map_object := Node2D.new()
	map_object.set_script(MAP_OBJECT_SCRIPT)
	map_object.set("asset_id", "character_composite")
	map_object.set("character_appearance", PART_CATALOG.default_appearance())
	map_object.set("character_action", "cast")
	map_object.set("character_direction", "up")
	map_object.set("character_action_loop", true)
	root.add_child(map_object)
	await process_frame
	var object_visual := map_object.get_node_or_null("Visual/CharacterVisual") as Node2D
	if object_visual == null or str(object_visual.call("current_action")) != "cast" or int(object_visual.get("direction_row")) != 3:
		return _fail("MapObject2D 没有把人物动作与朝向传给分层视觉")
	map_object.free()

	var normalized := TOWN_PROJECT.normalize_map({
		"version": 6,
		"size": [12, 10],
		"layers": {},
		"character_profiles": [{
			"id": "smith",
			"name": "Smith",
			"actions": ["idle", "walk", "forge"],
			"default_action": "forge",
			"default_direction": "right",
			"appearance": PART_CATALOG.default_appearance(),
		}],
		"characters": [{
			"id": "smith_instance",
			"asset": "character_composite",
			"character_id": "smith",
				"action": "forge",
				"direction": "right",
				"action_loop": true,
				"controller": {
					"type": "player",
					"move_speed": 999,
					"behavior": "wander",
					"wander_radius": 99,
				},
			}, {
				"id": "duplicate_player",
				"asset": "character_composite",
				"controller": {"type": "player"},
			}],
		})
	var profile: Dictionary = normalized.get("character_profiles", [])[0]
	var character: Dictionary = normalized.get("characters", [])[0]
	var duplicate_player: Dictionary = normalized.get("characters", [])[1]
	var controller: Dictionary = character.get("controller", {})
	if str(profile.get("default_action", "")) != "forge" or str(profile.get("default_direction", "")) != "right":
		return _fail("人物档案动作没有通过地图规范化")
	if str(character.get("action", "")) != "forge" or str(character.get("direction", "")) != "right" or not bool(character.get("action_loop", false)):
		return _fail("人物实例动作没有通过地图规范化")
	if int(normalized.get("version", 0)) != 7:
		return _fail("人物 Controller 数据没有升级到地图 v7")
	if str(controller.get("type", "")) != CONTROLLER_CATALOG.TYPE_PLAYER \
		or not is_equal_approx(float(controller.get("move_speed", 0.0)), CONTROLLER_CATALOG.MAX_MOVE_SPEED) \
		or str(controller.get("behavior", "")) != CONTROLLER_CATALOG.BEHAVIOR_WANDER \
		or not is_equal_approx(float(controller.get("wander_radius", 0.0)), CONTROLLER_CATALOG.MAX_WANDER_RADIUS):
		return _fail("人物 Controller 配置没有正确规范化")
	if str(duplicate_player.get("controller", {}).get("type", "")) != CONTROLLER_CATALOG.TYPE_NONE:
		return _fail("地图规范化没有限制为一个 Player Controller")

	print("[CharacterActionsTest] PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("[CharacterActionsTest] %s" % message)
	quit(1)
