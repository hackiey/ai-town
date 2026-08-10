extends SceneTree

const PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const PRESET_LIBRARY := preload("res://src2d/data/character_preset_library.gd")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var presets := PRESET_LIBRARY.presets()
	if presets.size() != 20:
		return _fail("语义人物预设不是正好 20 个")
	var validation_errors := PRESET_LIBRARY.validate()
	if not validation_errors.is_empty():
		return _fail("预设校验失败：%s" % "；".join(validation_errors))
	var seen_ids := {}
	for preset_value in presets:
		if not preset_value is Dictionary:
			return _fail("预设列表含有非对象数据")
		var preset: Dictionary = preset_value
		var preset_id := str(preset.get("id", ""))
		if preset_id.is_empty() or seen_ids.has(preset_id):
			return _fail("预设 ID 为空或重复：%s" % preset_id)
		seen_ids[preset_id] = true
		var appearance := PART_CATALOG.normalize_appearance(preset.get("appearance", {}))
		var preview := PART_CATALOG.composite_frame_texture(appearance, 0, 1)
		if preview == null or preview.get_size() != Vector2(48, 48):
			return _fail("预设 %s 无法合成 48×48 预览" % preset_id)
		if PRESET_LIBRARY.preset(preset_id).is_empty():
			return _fail("无法按 ID 查回预设：%s" % preset_id)
	print("[CharacterPresetsTest] PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("[CharacterPresetsTest] %s" % message)
	quit(1)
