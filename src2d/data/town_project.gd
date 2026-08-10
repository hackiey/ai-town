class_name TownProject
extends RefCounted

const USER_ROOT := "user://towns"
const REGISTRY_PATH := "user://town_project_registry.json"
const REGISTRY_VERSION := 1
const BUILTIN_DEMO_ID := "town_2d_demo"
const BUILTIN_DEMO_MAP_PATH := "res://data/towns/town_2d_demo/map.json"
const ASSET_LIBRARY := preload("res://src2d/data/town_asset_library.gd")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")
const CHARACTER_CONTROLLER_CATALOG := preload("res://src2d/characters/character_controller_catalog.gd")
static func list_projects() -> Array:
	var projects_by_id := {}
	projects_by_id[BUILTIN_DEMO_ID] = {
		"id": BUILTIN_DEMO_ID,
		"name": "中央小镇示例",
		"source": "builtin",
		"path": BUILTIN_DEMO_MAP_PATH,
	}
	for project_value in list_registered_projects():
		if project_value is Dictionary and bool(project_value.get("available", false)):
			projects_by_id[str(project_value.get("id", ""))] = project_value
	for remote_value in _list_remote_projects():
		if remote_value is Dictionary:
			projects_by_id[str(remote_value.get("id", ""))] = remote_value
	var projects: Array = projects_by_id.values()
	projects.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
	return projects


static func list_registered_projects() -> Array:
	var registry := _load_registry()
	var results: Array = []
	var entries: Variant = registry.get("projects", [])
	if not entries is Array:
		return results
	for entry_value in entries:
		if not entry_value is Dictionary:
			continue
		var directory_path := _normalize_directory_path(str(entry_value.get("path", "")))
		var project_id := sanitize_id(str(entry_value.get("id", "")))
		if directory_path.is_empty() or project_id.is_empty():
			continue
		var manifest_path := _join_project_path(directory_path, "town.json")
		var map_file_path := _join_project_path(directory_path, "map.json")
		var manifest := _read_json(manifest_path)
		var available := FileAccess.file_exists(manifest_path) and FileAccess.file_exists(map_file_path)
		results.append({
			"id": project_id,
			"name": str(manifest.get("name", entry_value.get("name", project_id))),
			"source": "user",
			"directory": directory_path,
			"path": map_file_path,
			"published_id": str(manifest.get("published_id", "")),
			"available": available,
		})
	results.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
	return results


static func register_project(project_id: String, project_name: String, directory_path: String) -> bool:
	var safe_id := sanitize_id(project_id)
	var normalized_path := _normalize_directory_path(directory_path)
	if safe_id.is_empty() or normalized_path.is_empty():
		return false
	var registry := _load_registry()
	var entries: Array = registry.get("projects", [])
	var replacement := {
		"id": safe_id,
		"name": project_name.strip_edges() if not project_name.strip_edges().is_empty() else safe_id,
		"path": normalized_path,
	}
	var replaced := false
	for index in entries.size():
		var entry_value: Variant = entries[index]
		if not entry_value is Dictionary:
			continue
		if str(entry_value.get("id", "")) == safe_id or _normalize_directory_path(str(entry_value.get("path", ""))) == normalized_path:
			entries[index] = replacement
			replaced = true
			break
	if not replaced:
		entries.append(replacement)
	registry["projects"] = entries
	return _write_registry(registry)


static func unregister_project(project_id: String) -> bool:
	var safe_id := sanitize_id(project_id)
	if safe_id.is_empty():
		return false
	var registry := _load_registry()
	var entries: Array = registry.get("projects", [])
	var filtered: Array = []
	for entry_value in entries:
		if entry_value is Dictionary and str(entry_value.get("id", "")) == safe_id:
			continue
		filtered.append(entry_value)
	registry["projects"] = filtered
	return _write_registry(registry)


static func register_existing_project(directory_path: String) -> String:
	var normalized_path := _normalize_directory_path(directory_path)
	if normalized_path.is_empty():
		return ""
	var manifest := _read_json(_join_project_path(normalized_path, "town.json"))
	var map_data := _read_json(_join_project_path(normalized_path, "map.json"))
	if manifest.is_empty() or map_data.is_empty() or str(manifest.get("source", "user")) == "remote":
		return ""
	var fallback_id := normalized_path.get_file()
	var project_id := sanitize_id(str(manifest.get("id", fallback_id)))
	if project_id.is_empty():
		return ""
	var project_name := str(manifest.get("name", map_data.get("name", project_id)))
	if not register_project(project_id, project_name, normalized_path):
		return ""
	return project_id


static func load_map(project_id: String) -> Dictionary:
	var path := map_path(project_id)
	if not FileAccess.file_exists(path):
		if project_id == BUILTIN_DEMO_ID:
			path = BUILTIN_DEMO_MAP_PATH
		else:
			return {}
	var map_data := _read_json(path)
	if map_data.is_empty():
		return {}
	return normalize_map(map_data)


static func create_project(project_id: String, project_name: String, width: int, height: int) -> Dictionary:
	var safe_id := sanitize_id(project_id)
	if safe_id.is_empty():
		return {}
	var map_data := make_default_map(width, height, project_name)
	if not save_project(safe_id, project_name, map_data):
		return {}
	return map_data


static func save_project(project_id: String, project_name: String, map_data: Dictionary) -> bool:
	var safe_id := sanitize_id(project_id)
	if safe_id.is_empty():
		return false
	var registered_path := _registered_directory(safe_id)
	var directory_path := registered_path if not registered_path.is_empty() else USER_ROOT + "/" + safe_id
	var existing_manifest := _read_json(_join_project_path(directory_path, "town.json"))
	var source := str(existing_manifest.get("source", "user"))
	if not _save_project_files(directory_path, safe_id, project_name, map_data, source):
		return false
	if source == "user":
		return register_project(safe_id, project_name, directory_path)
	return true


static func load_manifest(project_id: String) -> Dictionary:
	var safe_id := sanitize_id(project_id)
	if safe_id.is_empty():
		return {}
	return _read_json(_manifest_path(safe_id))


static func set_publish_credentials(project_id: String, published_id: String, edit_token: String) -> bool:
	var safe_id := sanitize_id(project_id)
	if safe_id.is_empty():
		return false
	var manifest := load_manifest(safe_id)
	if manifest.is_empty():
		return false
	manifest["published_id"] = published_id
	manifest["edit_token"] = edit_token
	manifest["source"] = "user"
	return _write_json(_manifest_path(safe_id), manifest)


static func set_publish_metadata(project_id: String, author_name: String, description: String) -> bool:
	var safe_id := sanitize_id(project_id)
	if safe_id.is_empty():
		return false
	var manifest := load_manifest(safe_id)
	if manifest.is_empty():
		return false
	manifest["author_name"] = author_name.strip_edges().left(48)
	manifest["description"] = description.strip_edges().left(300)
	return _write_json(_manifest_path(safe_id), manifest)


static func cache_remote_project(remote_id: String, project_name: String, map_data: Dictionary) -> String:
	var safe_remote_id := sanitize_id(remote_id)
	if safe_remote_id.is_empty():
		return ""
	var local_id := "remote_%s" % safe_remote_id
	var directory_path := USER_ROOT + "/" + local_id
	if not _save_project_files(directory_path, local_id, project_name, map_data, "remote"):
		return ""
	var manifest := _read_json(_join_project_path(directory_path, "town.json"))
	manifest["source"] = "remote"
	manifest["remote_id"] = remote_id
	manifest.erase("published_id")
	manifest.erase("edit_token")
	if not _write_json(_join_project_path(directory_path, "town.json"), manifest):
		return ""
	return local_id


static func make_default_map(width: int, height: int, project_name := "") -> Dictionary:
	width = clampi(width, 8, 256)
	height = clampi(height, 8, 256)
	var host := _mechanic_host()
	if host != null and host.has_method("query") and host.has_method("has_mechanic") and host.has_mechanic("town_editor"):
		var raw = host.query("town_editor", "create_map", [{"width": width, "height": height, "name": project_name}])
		var converted: Variant = LuaConv.to_variant(raw) if raw != null else null
		if converted is Dictionary:
			return normalize_map(converted)
	return normalize_map({
		"format": "ai_town",
		"version": 7,
		"name": project_name,
		"tile_size": 32,
		"size": [width, height],
		"player_spawn": [width / 2, height / 2],
		"tiles": {"meadow": 37, "path": 0, "field": 10, "water": 18},
		"terrain": {"base_ground": ASSET_LIBRARY.DEFAULT_GROUND},
		"layers": {"ground": [], "roads": [], "fields": [], "water": []},
		"fences": [],
		"buildings": [],
		"decorations": [],
		"characters": [],
		"character_profiles": [],
		"player_character_id": "",
		"locations": [],
	})


static func normalize_map(map_data: Dictionary) -> Dictionary:
	var normalized := map_data.duplicate(true)
	var size: Array = normalized.get("size", [48, 32])
	if size.size() < 2:
		size = [48, 32]
	normalized["size"] = [clampi(int(size[0]), 8, 256), clampi(int(size[1]), 8, 256)]
	normalized["tile_size"] = int(normalized.get("tile_size", 32))
	normalized["version"] = maxi(7, int(normalized.get("version", 1)))
	var tiles: Dictionary = normalized.get("tiles", {})
	tiles["meadow"] = int(tiles.get("meadow", 37))
	tiles["path"] = int(tiles.get("path", 0))
	tiles["field"] = int(tiles.get("field", 10))
	tiles["water"] = int(tiles.get("water", 18))
	normalized["tiles"] = tiles
	var terrain: Dictionary = normalized.get("terrain", {})
	var base_ground := str(terrain.get("base_ground", ASSET_LIBRARY.DEFAULT_GROUND))
	if ASSET_LIBRARY.terrain_material(base_ground).is_empty():
		base_ground = ASSET_LIBRARY.DEFAULT_GROUND
	terrain["base_ground"] = base_ground
	normalized["terrain"] = terrain
	var layers: Dictionary = normalized.get("layers", {})
	layers["ground"] = _normalize_material_specs(layers.get("ground", []), ASSET_LIBRARY.DEFAULT_GROUND)
	layers["roads"] = _normalize_material_specs(layers.get("roads", []), ASSET_LIBRARY.DEFAULT_ROAD)
	layers["fields"] = _normalize_material_specs(layers.get("fields", []), ASSET_LIBRARY.DEFAULT_FIELD)
	layers["water"] = _normalize_material_specs(layers.get("water", []), ASSET_LIBRARY.DEFAULT_WATER)
	normalized["layers"] = layers
	for key in ["fences", "buildings", "decorations", "characters", "locations"]:
		if not normalized.has(key):
			normalized[key] = []
	_migrate_legacy_character_objects(normalized)
	normalized["characters"] = _normalize_character_instances(normalized.get("characters", []))
	normalized["character_profiles"] = _normalize_character_profiles(normalized.get("character_profiles", []))
	var player_character_id := str(normalized.get("player_character_id", ""))
	if not _has_character_profile(normalized["character_profiles"], player_character_id):
		player_character_id = ""
	normalized["player_character_id"] = player_character_id
	var spawn: Array = normalized.get("player_spawn", [normalized["size"][0] / 2, normalized["size"][1] / 2])
	if spawn.size() < 2:
		spawn = [normalized["size"][0] / 2, normalized["size"][1] / 2]
	normalized["player_spawn"] = [
		clampi(int(spawn[0]), 0, normalized["size"][0] - 1),
		clampi(int(spawn[1]), 0, normalized["size"][1] - 1),
	]
	return normalized


static func _migrate_legacy_character_objects(map_data: Dictionary) -> void:
	var decorations: Array = map_data.get("decorations", [])
	var remaining_decorations: Array = []
	var characters: Array = map_data.get("characters", [])
	for object_value in decorations:
		if not object_value is Dictionary or str(object_value.get("asset", "")) != "resident_pale_adventurer":
			remaining_decorations.append(object_value)
			continue
		var migrated: Dictionary = object_value.duplicate(true)
		migrated["asset"] = "character_composite"
		migrated["appearance"] = CHARACTER_PART_CATALOG.default_appearance()
		migrated["action"] = "idle"
		migrated["direction"] = "down"
		migrated["action_loop"] = true
		migrated["controller"] = CHARACTER_CONTROLLER_CATALOG.normalize_controller({})
		characters.append(migrated)
	map_data["decorations"] = remaining_decorations
	map_data["characters"] = characters


static func _normalize_character_profiles(profiles_value: Variant) -> Array:
	var profiles: Array = []
	if not profiles_value is Array:
		return profiles
	var used_ids := {}
	for profile_value in profiles_value:
		if not profile_value is Dictionary:
			continue
		var profile: Dictionary = profile_value.duplicate(true)
		var profile_id := sanitize_id(str(profile.get("id", "")))
		if profile_id.is_empty() or used_ids.has(profile_id):
			continue
		used_ids[profile_id] = true
		var default_action := CHARACTER_ACTION_CATALOG.normalize_action(str(profile.get("default_action", "idle")))
		var normalized_profile := {
			"id": profile_id,
			"name": str(profile.get("name", profile_id)).strip_edges().left(48),
			"description": str(profile.get("description", "")).strip_edges().left(240),
			"actions": CHARACTER_ACTION_CATALOG.normalize_actions(profile.get("actions", []), default_action),
			"default_action": default_action,
			"default_direction": CHARACTER_ACTION_CATALOG.normalize_direction(str(profile.get("default_direction", "down"))),
			"appearance": CHARACTER_PART_CATALOG.normalize_appearance(profile.get("appearance", {})),
		}
		var source_preset_id := sanitize_id(str(profile.get("source_preset_id", "")))
		if not source_preset_id.is_empty():
			normalized_profile["source_preset_id"] = source_preset_id
		profiles.append(normalized_profile)
	return profiles


static func _normalize_character_instances(characters_value: Variant) -> Array:
	var characters: Array = []
	if not characters_value is Array:
		return characters
	var has_player_controller := false
	for character_value in characters_value:
		if not character_value is Dictionary:
			continue
		var character: Dictionary = character_value.duplicate(true)
		character["name"] = str(character.get("name", character.get("id", "人物"))).strip_edges().left(48)
		if character.has("action"):
			character["action"] = CHARACTER_ACTION_CATALOG.normalize_action(str(character.get("action", "idle")))
		if character.has("direction"):
			character["direction"] = CHARACTER_ACTION_CATALOG.normalize_direction(str(character.get("direction", "down")))
		if character.has("action_loop"):
			character["action_loop"] = bool(character.get("action_loop", true))
		var controller := CHARACTER_CONTROLLER_CATALOG.normalize_controller(character.get("controller", {}))
		if str(controller.get("type", "none")) == CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER:
			if has_player_controller:
				controller["type"] = CHARACTER_CONTROLLER_CATALOG.TYPE_NONE
			else:
				has_player_controller = true
		character["controller"] = controller
		characters.append(character)
	return characters


static func _has_character_profile(profiles: Array, profile_id: String) -> bool:
	if profile_id.is_empty():
		return false
	for profile_value in profiles:
		if profile_value is Dictionary and str(profile_value.get("id", "")) == profile_id:
			return true
	return false


static func _normalize_material_specs(specs_value: Variant, default_material: String) -> Array:
	var specs: Array = []
	if specs_value is Dictionary:
		specs_value = [specs_value]
	if not specs_value is Array:
		return specs
	for spec_value in specs_value:
		if not spec_value is Dictionary:
			continue
		var spec: Dictionary = spec_value.duplicate(true)
		var material_id := str(spec.get("material", spec.get("style", default_material)))
		if ASSET_LIBRARY.terrain_material(material_id).is_empty():
			material_id = default_material
		spec["material"] = material_id
		spec.erase("style")
		specs.append(spec)
	return specs


static func map_path(project_id: String) -> String:
	var safe_id := sanitize_id(project_id)
	var registered_path := _registered_directory(safe_id)
	if not registered_path.is_empty():
		return _join_project_path(registered_path, "map.json")
	if safe_id == BUILTIN_DEMO_ID:
		return BUILTIN_DEMO_MAP_PATH
	return _join_project_path(USER_ROOT + "/" + safe_id, "map.json")


static func sanitize_id(value: String) -> String:
	var result := value.strip_edges().to_lower().replace(" ", "_")
	var cleaned := ""
	for character in result:
		if character in "abcdefghijklmnopqrstuvwxyz0123456789_-":
			cleaned += character
	return cleaned.left(48)


static func _manifest_path(project_id: String) -> String:
	var registered_path := _registered_directory(project_id)
	var directory_path := registered_path if not registered_path.is_empty() else USER_ROOT + "/" + project_id
	return _join_project_path(directory_path, "town.json")


static func _registered_directory(project_id: String) -> String:
	var safe_id := sanitize_id(project_id)
	if safe_id.is_empty():
		return ""
	var registry := _load_registry()
	var entries: Variant = registry.get("projects", [])
	if not entries is Array:
		return ""
	for entry_value in entries:
		if entry_value is Dictionary and str(entry_value.get("id", "")) == safe_id:
			return _normalize_directory_path(str(entry_value.get("path", "")))
	return ""


static func _list_remote_projects() -> Array:
	var projects: Array = []
	var directory := DirAccess.open(USER_ROOT)
	if directory == null:
		return projects
	directory.list_dir_begin()
	var entry := directory.get_next()
	while entry != "":
		if directory.current_is_dir() and not entry.begins_with("."):
			var project_id := sanitize_id(entry)
			var directory_path := USER_ROOT + "/" + project_id
			var manifest := _read_json(_join_project_path(directory_path, "town.json"))
			if str(manifest.get("source", "")) == "remote":
				projects.append({
					"id": project_id,
					"name": str(manifest.get("name", project_id)),
					"source": "remote",
					"directory": directory_path,
					"path": _join_project_path(directory_path, "map.json"),
					"published_id": "",
					"available": true,
				})
		entry = directory.get_next()
	directory.list_dir_end()
	return projects


static func _load_registry() -> Dictionary:
	var registry := _read_json(REGISTRY_PATH)
	if registry.is_empty():
		registry = {"version": REGISTRY_VERSION, "legacy_imported": false, "projects": []}
	if not registry.get("projects", []) is Array:
		registry["projects"] = []
	if not bool(registry.get("legacy_imported", false)):
		_migrate_legacy_projects(registry)
		registry["legacy_imported"] = true
		_write_registry(registry)
	return registry


static func _migrate_legacy_projects(registry: Dictionary) -> void:
	var directory := DirAccess.open(USER_ROOT)
	if directory == null:
		return
	var entries: Array = registry.get("projects", [])
	directory.list_dir_begin()
	var entry := directory.get_next()
	while entry != "":
		if directory.current_is_dir() and not entry.begins_with("."):
			var project_id := sanitize_id(entry)
			var directory_path := USER_ROOT + "/" + project_id
			var manifest := _read_json(_join_project_path(directory_path, "town.json"))
			if (
				project_id != BUILTIN_DEMO_ID
				and str(manifest.get("source", "user")) == "user"
				and FileAccess.file_exists(_join_project_path(directory_path, "map.json"))
			):
				entries.append({
					"id": project_id,
					"name": str(manifest.get("name", project_id)),
					"path": directory_path,
				})
		entry = directory.get_next()
	directory.list_dir_end()
	registry["projects"] = entries


static func _write_registry(registry: Dictionary) -> bool:
	registry["version"] = REGISTRY_VERSION
	registry["legacy_imported"] = true
	return _write_json(REGISTRY_PATH, registry)


static func _save_project_files(directory_path: String, project_id: String, project_name: String, map_data: Dictionary, source: String) -> bool:
	var absolute_path := ProjectSettings.globalize_path(directory_path) if directory_path.begins_with("user://") or directory_path.begins_with("res://") else directory_path
	if DirAccess.make_dir_recursive_absolute(absolute_path) != OK:
		push_error("[TownProject] failed to create directory: %s" % directory_path)
		return false
	map_data = normalize_map(map_data)
	map_data["name"] = project_name.strip_edges() if not project_name.strip_edges().is_empty() else project_id
	var map_ok := _write_json(_join_project_path(directory_path, "map.json"), map_data)
	var manifest := _read_json(_join_project_path(directory_path, "town.json"))
	manifest.merge({
		"format": "ai_town",
		"version": 1,
		"id": project_id,
		"name": map_data["name"],
		"map": "map.json",
		"asset_pack": "builtin",
		"source": source,
	}, true)
	var manifest_ok := _write_json(_join_project_path(directory_path, "town.json"), manifest)
	return map_ok and manifest_ok


static func _normalize_directory_path(value: String) -> String:
	var normalized := value.strip_edges().replace("\\", "/")
	while normalized.ends_with("/") and normalized.length() > 1:
		normalized = normalized.trim_suffix("/")
	return normalized


static func _join_project_path(directory_path: String, file_name: String) -> String:
	return "%s/%s" % [_normalize_directory_path(directory_path), file_name]


static func _mechanic_host() -> Node:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		return (main_loop as SceneTree).root.get_node_or_null("MechanicHost")
	return null


static func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


static func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[TownProject] failed to open %s" % path)
		return false
	file.store_string(JSON.stringify(value, "  "))
	return true
