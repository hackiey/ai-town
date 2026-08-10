class_name CharacterPartCatalog
extends RefCounted

const CATALOG_PATH := "res://assets/craftpix/craftpix-net-254170-rpg-character-sprite-sheet-generator/exported/character_components.json"
const GROUP_NAMES_ZH := {
	"skin_tone": "肤色",
	"down_vest": "下装",
	"up_vest": "上装",
	"war_paint_and_scars": "战纹与伤疤",
	"eyes": "眼睛",
	"accessories": "配饰（可多选）",
	"equipments": "装备（可多选）",
	"face": "面部",
	"eyebrows": "眉毛",
	"hair": "发型",
	"head": "头饰",
	"ear": "耳朵",
}

static var _catalog_cache: Dictionary = {}
static var _parts_by_id: Dictionary = {}
static var _preview_cache: Dictionary = {}


static func catalog() -> Dictionary:
	if not _catalog_cache.is_empty():
		return _catalog_cache
	if not FileAccess.file_exists(CATALOG_PATH):
		push_error("[CharacterPartCatalog] missing component catalog: %s" % CATALOG_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if not parsed is Dictionary:
		push_error("[CharacterPartCatalog] invalid component catalog JSON")
		return {}
	_catalog_cache = parsed
	_parts_by_id.clear()
	for group_value in _catalog_cache.get("groups", []):
		if not group_value is Dictionary:
			continue
		for part_value in group_value.get("parts", []):
			if part_value is Dictionary:
				_parts_by_id[str(part_value.get("id", ""))] = part_value
	return _catalog_cache


static func groups() -> Array:
	return catalog().get("groups", []).duplicate(true)


static func group_display_name(group: Dictionary) -> String:
	var group_id := str(group.get("id", ""))
	return str(GROUP_NAMES_ZH.get(group_id, group.get("name", group_id)))


static func frame_size() -> Vector2i:
	var value: Array = catalog().get("frame_size", [48, 48])
	return Vector2i(int(value[0]), int(value[1])) if value.size() >= 2 else Vector2i(48, 48)


static func default_appearance() -> Dictionary:
	return normalize_appearance(catalog().get("default_appearance", {}))


static func normalize_appearance(appearance_value: Variant) -> Dictionary:
	var appearance: Dictionary = appearance_value if appearance_value is Dictionary else {}
	var raw_groups: Dictionary = appearance.get("groups", {}) if appearance.get("groups", {}) is Dictionary else {}
	var use_catalog_defaults := raw_groups.is_empty()
	var default_groups: Dictionary = catalog().get("default_appearance", {}).get("groups", {})
	var normalized_groups := {}
	for group_value in catalog().get("groups", []):
		if not group_value is Dictionary:
			continue
		var group: Dictionary = group_value
		var group_id := str(group.get("id", ""))
		var valid_ids := {}
		for part_value in group.get("parts", []):
			if part_value is Dictionary:
				valid_ids[str(part_value.get("id", ""))] = true
		var selected_value: Variant = raw_groups.get(group_id, default_groups.get(group_id, []) if use_catalog_defaults else [])
		var selected: Array = selected_value.duplicate() if selected_value is Array else ([selected_value] if selected_value is String else [])
		var valid_selected: Array = []
		for part_id_value in selected:
			var part_id := str(part_id_value)
			if valid_ids.has(part_id) and not part_id in valid_selected:
				valid_selected.append(part_id)
		if not bool(group.get("multi", false)) and valid_selected.size() > 1:
			valid_selected = [valid_selected[0]]
		if bool(group.get("required", false)) and valid_selected.is_empty():
			var parts: Array = group.get("parts", [])
			if not parts.is_empty():
				valid_selected = [str(parts[0].get("id", ""))]
		normalized_groups[group_id] = valid_selected
	return {
		"catalog": str(catalog().get("catalog_id", "craftpix_rpg_48")),
		"catalog_version": int(catalog().get("version", 1)),
		"groups": normalized_groups,
	}


static func selected_parts(appearance_value: Variant) -> Array:
	catalog()
	var appearance := normalize_appearance(appearance_value)
	var selected: Array = []
	var appearance_groups: Dictionary = appearance.get("groups", {})
	for part_ids_value in appearance_groups.values():
		if not part_ids_value is Array:
			continue
		for part_id_value in part_ids_value:
			var part: Dictionary = _parts_by_id.get(str(part_id_value), {})
			if not part.is_empty():
				selected.append(part)
	selected.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("order", 0)) < int(right.get("order", 0))
	)
	return selected


static func part(part_id: String) -> Dictionary:
	catalog()
	return _parts_by_id.get(part_id, {}).duplicate(true)


static func composite_frame_texture(appearance_value: Variant, direction_row := 0, frame_column := 1) -> Texture2D:
	var appearance := normalize_appearance(appearance_value)
	var cache_key := "%s:%d:%d" % [JSON.stringify(appearance), direction_row, frame_column]
	if _preview_cache.has(cache_key):
		return _preview_cache[cache_key]
	var size := frame_size()
	var canvas := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	canvas.fill(Color.TRANSPARENT)
	var source_rect := Rect2i(
		clampi(frame_column, 0, 2) * size.x,
		clampi(direction_row, 0, 3) * size.y,
		size.x,
		size.y
	)
	for part_value in selected_parts(appearance):
		var texture: Texture2D = load(str(part_value.get("path", "")))
		if texture == null:
			continue
		var image := texture.get_image()
		if image == null:
			continue
		canvas.blend_rect(image, source_rect, Vector2i.ZERO)
	var result := ImageTexture.create_from_image(canvas)
	_preview_cache[cache_key] = result
	return result


static func random_appearance(seed_value := 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	if seed_value == 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	var selected_groups := {}
	for group_value in catalog().get("groups", []):
		if not group_value is Dictionary:
			continue
		var group: Dictionary = group_value
		var group_id := str(group.get("id", ""))
		var parts: Array = group.get("parts", [])
		var selected: Array = []
		if parts.is_empty():
			selected_groups[group_id] = selected
			continue
		if bool(group.get("multi", false)):
			var desired_count := rng.randi_range(0, mini(2, parts.size()))
			var available := parts.duplicate()
			available.shuffle()
			for index in desired_count:
				selected.append(str(available[index].get("id", "")))
		elif bool(group.get("required", false)) or rng.randf() < 0.62:
			selected.append(str(parts[rng.randi_range(0, parts.size() - 1)].get("id", "")))
		selected_groups[group_id] = selected
	return normalize_appearance({"groups": selected_groups})
