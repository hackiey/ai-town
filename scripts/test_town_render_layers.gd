extends Node

const TOWN_SCENE := preload("res://src2d/levels/town_2d.tscn")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_PRESET_LIBRARY := preload("res://src2d/data/character_preset_library.gd")

var _town: Node2D


func _ready() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	_town = TOWN_SCENE.instantiate()
	get_tree().root.add_child(_town)
	await get_tree().process_frame
	await get_tree().process_frame
	var ground := _town.get_node_or_null("Map/Ground") as TileMapLayer
	var fields := _town.get_node_or_null("Map/Fields") as TileMapLayer
	var water := _town.get_node_or_null("Map/Water") as TileMapLayer
	var roads := _town.get_node_or_null("Map/Roads") as TileMapLayer
	var fences := _town.get_node_or_null("Map/Fences") as TileMapLayer
	var decals := _town.get_node_or_null("Buildings/GroundDecals") as Node2D
	var world := _town.get_node_or_null("Buildings/WorldObjects") as Node2D
	var foreground := _town.get_node_or_null("Buildings/ForegroundObjects") as Node2D
	if null in [ground, fields, water, roads, fences, decals, world, foreground]:
		_fail("运行时渲染层节点不完整")
		return
	if [ground.z_index, fields.z_index, water.z_index, roads.z_index, fences.z_index] != [0, 10, 20, 30, 45]:
		_fail("运行时地形或语义栅栏层级不正确")
		return
	if [decals.z_index, world.z_index, foreground.z_index] != [40, 50, 60] or not world.y_sort_enabled:
		_fail("运行时对象层级或 Y 排序不正确")
		return
	var player := world.get_node_or_null("Player") as CharacterBody2D
	if player == null or player.z_index != 0:
		_fail("玩家没有进入世界对象 Y 排序层")
		return
	player.call("play_character_action", "cast", false, true)
	var player_visual := player.get_node_or_null("CharacterVisual") as Node2D
	if player_visual == null or str(player_visual.call("current_action")) != "cast" or not bool(player.get("_action_movement_locked")):
		_fail("玩家动作 API 没有播放施法动作并锁定移动")
		return
	player_visual.call("_process", 2.0)
	if str(player_visual.call("current_action")) != "idle" or bool(player.get("_action_movement_locked")):
		_fail("玩家非循环动作结束后没有恢复待机和移动")
		return
	var controller_map := {
			"size": [20, 14],
			"buildings": [],
			"decorations": [],
			"character_profiles": [],
			"characters": [{
				"id": "placed_player",
				"name": "地图玩家",
				"asset": "character_composite",
				"preset_id": "town_guard",
				"cell": [6, 5],
				"scale": 1.25,
				"shadow": false,
				"action": "guard",
				"direction": "right",
				"action_loop": true,
				"controller": {"type": "player", "move_speed": 180},
			}, {
				"id": "wandering_ai",
				"name": "漫游居民",
				"asset": "character_composite",
				"preset_id": "traveling_bard",
				"cell": [9, 5],
				"action": "perform",
				"direction": "down",
				"action_loop": true,
				"controller": {"type": "ai", "move_speed": 75, "behavior": "wander", "wander_radius": 5},
			}],
	}
	_town.set("_map_data", controller_map)
	_town.call("_clear_generated_content")
	_town.call("_attach_player_to_world_layer")
	player.set("map_size_cells", Vector2i(20, 14))
	_town.call("_setup_player_controller")
	_town.call("_build_map_objects")
	if player.position != Vector2(208, 192) or not is_equal_approx(float(player.get("move_speed")), 180.0):
		_fail("Player Controller 没有继承地图人物的位置与移动速度")
		return
	if world.get_node_or_null("placed_player") != null:
		_fail("Player Controller 人物被重复创建为静态地图对象")
		return
	var ai_actor := world.get_node_or_null("wandering_ai") as CharacterBody2D
	if ai_actor == null or str(ai_actor.get("controller_type")) != "ai" or str(ai_actor.get("ai_behavior")) != "wander":
		_fail("AI Controller 没有创建动态 CharacterBody2D")
		return
	if not is_equal_approx(float(ai_actor.get("move_speed")), 75.0) or not is_equal_approx(float(ai_actor.get("wander_radius")), 5.0):
		_fail("AI Controller 没有继承移动参数")
		return
	var position_before_input := player.position
	Input.action_press("move_right")
	player.call("_physics_process", 1.0 / 60.0)
	Input.action_release("move_right")
	if float(player.velocity.x) <= 0.0 or player.position.x <= position_before_input.x:
		_fail("地图人物设置为 Player Controller 后仍无法读取移动输入")
		return
	var decal_count := decals.get_child_count()
	_town.call("_add_map_object", {"id": "runtime_layer_test", "asset": "dirt_patch_1", "cell": [0, 0], "shadow": false, "render_order": 83})
	if decals.get_child_count() != decal_count + 1:
		_fail("运行时泥土斑块没有进入地面贴花层")
		return
	var ordered_decal := decals.get_node_or_null("runtime_layer_test") as Node2D
	if ordered_decal == null or ordered_decal.z_index != 83:
		_fail("运行时没有应用实例 render_order")
		return
	var world_count := world.get_child_count()
	_town.call("_add_map_object", {
		"id": "runtime_resident_test",
		"asset": "character_composite",
		"cell": [2, 2],
		"shadow": true,
		"appearance": CHARACTER_PART_CATALOG.default_appearance(),
	})
	if world.get_child_count() != world_count + 1:
		_fail("居民没有进入运行时世界对象层")
		return
	var resident := world.get_node_or_null("runtime_resident_test") as Node2D
	var resident_visual := resident.get_node_or_null("Visual/CharacterVisual") as Node2D if resident != null else null
	var expected_parts := CHARACTER_PART_CATALOG.selected_parts(CHARACTER_PART_CATALOG.default_appearance()).size()
	if resident_visual == null or resident_visual.get_child_count() != expected_parts:
		_fail("运行时居民没有按组件配置创建分层视觉")
		return
	if str(resident_visual.call("current_action")) != "idle" or int(resident_visual.get("direction_row")) != 0:
		_fail("无动作配置的运行时居民没有回退到正面待机")
		return
	var preset := CHARACTER_PRESET_LIBRARY.preset("town_guard")
	var preset_world_count := world.get_child_count()
	_town.call("_add_map_object", {
		"id": "runtime_preset_resident_test",
		"asset": "character_composite",
		"preset_id": "town_guard",
		"cell": [3, 2],
		"shadow": true,
		"appearance": CHARACTER_PART_CATALOG.default_appearance(),
	})
	if world.get_child_count() != preset_world_count + 1:
		_fail("语义预设居民没有进入运行时世界对象层")
		return
	var preset_resident := world.get_node_or_null("runtime_preset_resident_test") as Node2D
	var preset_visual := preset_resident.get_node_or_null("Visual/CharacterVisual") as Node2D if preset_resident != null else null
	var expected_preset_appearance := CHARACTER_PART_CATALOG.normalize_appearance(preset.get("appearance", {}))
	var expected_preset_parts := CHARACTER_PART_CATALOG.selected_parts(expected_preset_appearance).size()
	if preset_visual == null or preset_visual.get_child_count() != expected_preset_parts or JSON.stringify(preset_visual.get("appearance")) != JSON.stringify(expected_preset_appearance):
		_fail("运行时没有按 preset_id 解析语义人物组件")
		return
	if str(preset_visual.call("current_action")) != "guard" or int(preset_visual.get("direction_row")) != 0:
		_fail("运行时没有按 preset_id 解析默认警戒动作和朝向")
		return
	var explicit_world_count := world.get_child_count()
	_town.call("_add_map_object", {
		"id": "runtime_explicit_action_test",
		"asset": "character_composite",
		"preset_id": "town_guard",
		"action": "cast",
		"direction": "up",
		"action_loop": true,
		"cell": [4, 2],
		"shadow": true,
		"appearance": CHARACTER_PART_CATALOG.default_appearance(),
	})
	if world.get_child_count() != explicit_world_count + 1:
		_fail("显式动作人物没有进入运行时世界对象层")
		return
	var explicit_resident := world.get_node_or_null("runtime_explicit_action_test") as Node2D
	var explicit_visual := explicit_resident.get_node_or_null("Visual/CharacterVisual") as Node2D if explicit_resident != null else null
	if explicit_visual == null or str(explicit_visual.call("current_action")) != "cast" or int(explicit_visual.get("direction_row")) != 3:
		_fail("实例级动作和朝向没有覆盖预设默认值")
		return
	print("[TownRenderLayersTest] PASS")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("[TownRenderLayersTest] %s" % message)
	get_tree().quit(1)
