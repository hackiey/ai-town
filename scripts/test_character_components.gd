extends SceneTree

const PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_VISUAL_SCRIPT := preload("res://src2d/characters/character_visual_2d.gd")
const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var groups := PART_CATALOG.groups()
	if groups.size() != 12:
		return _fail("人物组件目录不是 12 个原始组")
	var default_appearance := PART_CATALOG.default_appearance()
	var selected_parts := PART_CATALOG.selected_parts(default_appearance)
	if selected_parts.size() < 8:
		return _fail("默认组件选择不足，无法形成完整人物")
	var preview := PART_CATALOG.composite_frame_texture(default_appearance, 0, 1)
	if preview == null or preview.get_size() != Vector2(48, 48):
		return _fail("组件合成预览不是 48×48")

	var visual := Node2D.new()
	visual.set_script(CHARACTER_VISUAL_SCRIPT)
	visual.set("appearance", default_appearance)
	root.add_child(visual)
	await process_frame
	if visual.get_child_count() != selected_parts.size():
		return _fail("CharacterVisual2D 没有为每个已选组件创建图层")
	visual.call("set_motion", Vector2.LEFT, true)
	var first_sprite := visual.get_child(0) as Sprite2D
	if first_sprite == null or first_sprite.region_rect.position.y != 48.0:
		return _fail("人物左向动画没有同步切到第二行")
	visual.free()

	var migrated := TOWN_PROJECT.normalize_map({
		"version": 5,
		"size": [12, 10],
		"layers": {},
		"decorations": [{
			"id": "legacy_resident",
			"asset": "resident_pale_adventurer",
			"cell": [3, 4],
		}],
	})
	if int(migrated.get("version", 0)) != 7:
		return _fail("人物数据没有把地图升级到 v7")
	if not migrated.get("decorations", []).is_empty() or migrated.get("characters", []).size() != 1:
		return _fail("旧成品居民没有迁移到 characters 集合")
	var migrated_character: Dictionary = migrated.get("characters", [])[0]
	if str(migrated_character.get("asset", "")) != "character_composite" or migrated_character.get("appearance", {}).is_empty():
		return _fail("旧成品居民没有迁移成组件配置")
	if str(migrated_character.get("action", "")) != "idle" or str(migrated_character.get("direction", "")) != "down":
		return _fail("旧成品居民没有迁移成默认待机动作")
	if str(migrated_character.get("controller", {}).get("type", "")) != "none":
		return _fail("旧成品居民没有迁移成静态 Controller")

	var profile_map := TOWN_PROJECT.normalize_map({
		"version": 6,
		"size": [12, 10],
		"layers": {},
		"character_profiles": [{
			"id": "hero",
			"name": "Hero",
			"description": "A saved semantic character profile.",
			"source_preset_id": "town_guard",
			"actions": ["idle", "walk", "guard"],
			"default_action": "guard",
			"default_direction": "left",
			"appearance": default_appearance,
		}],
		"player_character_id": "hero",
	})
	if str(profile_map.get("player_character_id", "")) != "hero":
		return _fail("玩家人物档案引用没有通过地图规范化")
	if profile_map.get("character_profiles", []).size() != 1:
		return _fail("人物档案没有通过地图规范化")
	var normalized_profile: Dictionary = profile_map.get("character_profiles", [])[0]
	if str(normalized_profile.get("description", "")) != "A saved semantic character profile." or str(normalized_profile.get("source_preset_id", "")) != "town_guard":
		return _fail("人物语义描述或预设来源没有通过地图规范化")
	if str(normalized_profile.get("default_action", "")) != "guard" or str(normalized_profile.get("default_direction", "")) != "left":
		return _fail("人物档案默认动作或朝向没有通过地图规范化")

	print("[CharacterComponentsTest] PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("[CharacterComponentsTest] %s" % message)
	quit(1)
