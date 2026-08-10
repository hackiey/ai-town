class_name CharacterPresetLibrary
extends RefCounted

const PRESET_PATH := "res://data/characters/semantic_presets.json"
const PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")

static var _presets_cache: Array = []


static func presets() -> Array:
	if not _presets_cache.is_empty():
		return _presets_cache.duplicate(true)
	if not FileAccess.file_exists(PRESET_PATH):
		push_error("[CharacterPresetLibrary] missing preset file: %s" % PRESET_PATH)
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PRESET_PATH))
	if not parsed is Dictionary:
		push_error("[CharacterPresetLibrary] invalid preset JSON")
		return []
	var raw_presets: Variant = parsed.get("presets", [])
	if not raw_presets is Array:
		push_error("[CharacterPresetLibrary] presets must be an array")
		return []
	for preset_value in raw_presets:
		if not preset_value is Dictionary:
			continue
		var preset: Dictionary = preset_value
		var default_action := ACTION_CATALOG.normalize_action(str(preset.get("default_action", "idle")))
		_presets_cache.append({
			"id": str(preset.get("id", "")),
			"name": str(preset.get("name", "")),
			"description": str(preset.get("description", "")),
			"actions": ACTION_CATALOG.normalize_actions(preset.get("actions", []), default_action),
			"default_action": default_action,
			"default_direction": ACTION_CATALOG.normalize_direction(str(preset.get("default_direction", "down"))),
			"appearance": PART_CATALOG.normalize_appearance(preset.get("appearance", {})),
		})
	return _presets_cache.duplicate(true)


static func preset(preset_id: String) -> Dictionary:
	for preset_value in presets():
		if preset_value is Dictionary and str(preset_value.get("id", "")) == preset_id:
			return preset_value.duplicate(true)
	return {}


static func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if not FileAccess.file_exists(PRESET_PATH):
		errors.append("missing preset file")
		return errors
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PRESET_PATH))
	if not parsed is Dictionary or not parsed.get("presets", []) is Array:
		errors.append("invalid preset root")
		return errors
	var known_groups := {}
	for group_value in PART_CATALOG.groups():
		if not group_value is Dictionary:
			continue
		var group: Dictionary = group_value
		var part_ids := {}
		for part_value in group.get("parts", []):
			if part_value is Dictionary:
				part_ids[str(part_value.get("id", ""))] = true
		known_groups[str(group.get("id", ""))] = {
			"parts": part_ids,
			"multi": bool(group.get("multi", false)),
			"required": bool(group.get("required", false)),
		}
	var seen_ids := {}
	var raw_presets: Array = parsed.get("presets", [])
	if raw_presets.size() != 20:
		errors.append("expected 20 presets, got %d" % raw_presets.size())
	for preset_index in raw_presets.size():
		var preset_value: Variant = raw_presets[preset_index]
		if not preset_value is Dictionary:
			errors.append("preset %d is not an object" % preset_index)
			continue
		var preset: Dictionary = preset_value
		var preset_id := str(preset.get("id", ""))
		if preset_id.is_empty() or seen_ids.has(preset_id):
			errors.append("invalid or duplicate preset id: %s" % preset_id)
		seen_ids[preset_id] = true
		if str(preset.get("name", "")).is_empty():
			errors.append("preset %s has no name" % preset_id)
		if str(preset.get("description", "")).is_empty():
			errors.append("preset %s has no description" % preset_id)
		var default_action := str(preset.get("default_action", ""))
		if not ACTION_CATALOG.has_action(default_action):
			errors.append("preset %s has invalid default action %s" % [preset_id, default_action])
		var actions_value: Variant = preset.get("actions", [])
		if not actions_value is Array or actions_value.is_empty():
			errors.append("preset %s has no actions" % preset_id)
		else:
			var seen_actions := {}
			for action_id_value in actions_value:
				var action_id := str(action_id_value)
				if not ACTION_CATALOG.has_action(action_id):
					errors.append("preset %s uses invalid action %s" % [preset_id, action_id])
				elif seen_actions.has(action_id):
					errors.append("preset %s repeats action %s" % [preset_id, action_id])
				seen_actions[action_id] = true
			if not default_action in actions_value:
				errors.append("preset %s default action is not in actions" % preset_id)
		var default_direction := str(preset.get("default_direction", ""))
		if ACTION_CATALOG.normalize_direction(default_direction) != default_direction:
			errors.append("preset %s has invalid default direction %s" % [preset_id, default_direction])
		var appearance_value: Variant = preset.get("appearance", {})
		var appearance: Dictionary = appearance_value if appearance_value is Dictionary else {}
		var groups_value: Variant = appearance.get("groups", {})
		var selected_groups: Dictionary = groups_value if groups_value is Dictionary else {}
		for group_id_value in selected_groups.keys():
			var group_id := str(group_id_value)
			if not known_groups.has(group_id):
				errors.append("preset %s uses unknown group %s" % [preset_id, group_id])
				continue
			var selected_value: Variant = selected_groups[group_id]
			if not selected_value is Array:
				errors.append("preset %s group %s is not an array" % [preset_id, group_id])
				continue
			var selected: Array = selected_value
			if not bool(known_groups[group_id]["multi"]) and selected.size() > 1:
				errors.append("preset %s selects multiple parts in %s" % [preset_id, group_id])
			for part_id_value in selected:
				var part_id := str(part_id_value)
				if not known_groups[group_id]["parts"].has(part_id):
					errors.append("preset %s uses invalid part %s" % [preset_id, part_id])
		for group_id_value in known_groups.keys():
			var group_id := str(group_id_value)
			if bool(known_groups[group_id]["required"]) and (not selected_groups.has(group_id) or selected_groups[group_id].is_empty()):
				errors.append("preset %s omits required group %s" % [preset_id, group_id])
	return errors
