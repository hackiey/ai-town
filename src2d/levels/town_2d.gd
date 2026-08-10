extends Node2D

const TILE_SIZE := 32
const FIELDS_TEXTURE := preload("res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/1 Tiles/FieldsTileset.png")
const FENCE_TEXTURE := preload("res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/1.1 Tiles/Tileset2.png")
const LOCATION_MARKER_SCRIPT := preload("res://src2d/world/location_marker_2d.gd")
const MAP_OBJECT_SCRIPT := preload("res://src2d/world/map_object_2d.gd")
const MINIMAP_SCENE := preload("res://src2d/ui/minimap/minimap_layer.tscn")
const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")
const ASSET_LIBRARY := preload("res://src2d/data/town_asset_library.gd")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")
const CHARACTER_CONTROLLER_CATALOG := preload("res://src2d/characters/character_controller_catalog.gd")
const CHARACTER_ACTOR_SCRIPT := preload("res://src2d/characters/character_actor_2d.gd")
const CHARACTER_PRESET_LIBRARY := preload("res://src2d/data/character_preset_library.gd")
const TOWN_MAP_RULES := preload("res://src2d/world/town_map_rules_2d.gd")
const TOWN_EDITOR_SCENE := "res://src2d/editor/town_editor.tscn"
const TOWN_LOBBY_SCENE := "res://src2d/lobby/town_lobby.tscn"

@onready var _ground: TileMapLayer = $Map/Ground
@onready var _roads: TileMapLayer = $Map/Roads
@onready var _fields: TileMapLayer = $Map/Fields
@onready var _water: TileMapLayer = $Map/Water
@onready var _fences: TileMapLayer = $Map/Fences
@onready var _object_root: Node2D = $Buildings
@onready var _locations: Node2D = $Locations
@onready var _player: CharacterBody2D = $Characters/Player

var _map_data: Dictionary = {}
var _field_tileset: TileSet
var _fence_tileset: TileSet
var _ground_decal_objects: Node2D
var _world_objects: Node2D
var _foreground_objects: Node2D


func _ready() -> void:
	if RunMode.is_town_editor():
		call_deferred("_open_town_editor")
		return
	_setup_render_layers()
	_rebuild_map()
	_ensure_minimap()
	_setup_navigation_ui()


func _open_town_editor() -> void:
	RunMode.town_editor = true
	RunMode.editor_project_id = RunMode.town_id
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(TOWN_EDITOR_SCENE)


func _return_to_lobby() -> void:
	RunMode.town_editor = false
	RunMode.editor_project_id = ""
	RunMode.editor_create_new = false
	RunMode.editor_return_to_manager = false
	get_tree().change_scene_to_file(TOWN_LOBBY_SCENE)


func _setup_navigation_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "TownNavigation"
	layer.layer = 50
	add_child(layer)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
	margin.offset_left = 16
	margin.offset_top = 16
	layer.add_child(margin)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.06, 0.07, 0.92)
	style.border_color = Color(0.16, 0.55, 0.54, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	margin.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	var town_name := Label.new()
	town_name.text = str(_map_data.get("name", RunMode.town_id))
	town_name.custom_minimum_size.x = 150
	town_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(town_name)
	var edit_button := Button.new()
	edit_button.text = "打开编辑器"
	edit_button.pressed.connect(_open_town_editor)
	row.add_child(edit_button)
	var lobby_button := Button.new()
	lobby_button.text = "返回大厅"
	lobby_button.pressed.connect(_return_to_lobby)
	row.add_child(lobby_button)


func _rebuild_map() -> void:
	_map_data = _load_map_data()
	if _map_data.is_empty():
		return
	_field_tileset = TOWN_MAP_RULES.make_material_tileset(FIELDS_TEXTURE)
	_fence_tileset = _make_atlas_tileset(FENCE_TEXTURE)
	_ground.tile_set = _field_tileset
	_roads.tile_set = _field_tileset
	_fields.tile_set = _field_tileset
	_water.tile_set = _field_tileset
	_fences.tile_set = _fence_tileset
	_clear_generated_content()
	_attach_player_to_world_layer()
	_build_map()
	_build_fences()
	_setup_player_controller()
	_build_map_objects()
	_build_location_markers()
	var map_size: Array = _map_data.get("size", [40, 24])
	_player.set("map_size_cells", Vector2i(int(map_size[0]), int(map_size[1])))
	var camera: Camera2D = _player.get_node("Camera2D")
	camera.enabled = true
	camera.position = Vector2.ZERO
	camera.zoom = Vector2(2.0, 2.0)
	camera.position_smoothing_enabled = false
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(map_size[0]) * TILE_SIZE
	camera.limit_bottom = int(map_size[1]) * TILE_SIZE


func _clear_generated_content() -> void:
	_ground.clear()
	_roads.clear()
	_fields.clear()
	_water.clear()
	_fences.clear()
	for child in _object_root.get_children():
		if child in [_ground_decal_objects, _world_objects, _foreground_objects]:
			for object_child in child.get_children():
				if object_child != _player:
					object_child.free()
		else:
			child.free()
	for child in _locations.get_children():
		child.free()


func _ensure_minimap() -> void:
	var existing := get_node_or_null("MinimapLayer")
	if existing != null:
		existing.setup(_map_data, _player)
		return
	var minimap_layer := MINIMAP_SCENE.instantiate()
	minimap_layer.name = "MinimapLayer"
	add_child(minimap_layer)
	minimap_layer.setup(_map_data, _player)


func _load_map_data() -> Dictionary:
	var map_data := TOWN_PROJECT.load_map(RunMode.town_id)
	if map_data.is_empty():
		map_data = TOWN_PROJECT.load_map(TOWN_PROJECT.BUILTIN_DEMO_ID)
	if map_data.is_empty():
		push_error("[Town2D] no town map found for: %s" % RunMode.town_id)
	return map_data


func _make_atlas_tileset(texture: Texture2D) -> TileSet:
	return TOWN_MAP_RULES.make_atlas_tileset(texture)


func _setup_render_layers() -> void:
	_ground.z_index = ASSET_LIBRARY.Z_GROUND
	_fields.z_index = ASSET_LIBRARY.Z_FIELDS
	_water.z_index = ASSET_LIBRARY.Z_WATER
	_roads.z_index = ASSET_LIBRARY.Z_ROADS
	_fences.z_index = ASSET_LIBRARY.Z_FENCES
	_ground_decal_objects = _ensure_object_layer("GroundDecals", ASSET_LIBRARY.Z_GROUND_DECALS)
	_world_objects = _ensure_object_layer("WorldObjects", ASSET_LIBRARY.Z_WORLD_OBJECTS, true)
	_foreground_objects = _ensure_object_layer("ForegroundObjects", ASSET_LIBRARY.Z_FOREGROUND, true)


func _ensure_object_layer(layer_name: String, layer_z_index: int, use_y_sort := false) -> Node2D:
	var layer := _object_root.get_node_or_null(layer_name) as Node2D
	if layer == null:
		layer = Node2D.new()
		layer.name = layer_name
		_object_root.add_child(layer)
	layer.z_index = layer_z_index
	layer.y_sort_enabled = use_y_sort
	return layer


func _attach_player_to_world_layer() -> void:
	if _player.get_parent() != _world_objects:
		_player.reparent(_world_objects, true)
	_player.z_index = 0


func _build_map() -> void:
	var map_size: Array = _map_data.get("size", [40, 24])
	var base_ground := str(_map_data.get("terrain", {}).get("base_ground", ASSET_LIBRARY.DEFAULT_GROUND))
	for y in range(int(map_size[1])):
		for x in range(int(map_size[0])):
			TOWN_MAP_RULES.set_material_cell(_ground, Vector2i(x, y), base_ground)
	var layers: Dictionary = _map_data.get("layers", {})
	var ground_cells := TOWN_MAP_RULES.collect_material_cells(layers.get("ground", []), ASSET_LIBRARY.DEFAULT_GROUND)
	for cell_value in ground_cells.keys():
		TOWN_MAP_RULES.set_material_cell(_ground, cell_value, str(ground_cells[cell_value]))
	var road_cells := TOWN_MAP_RULES.collect_material_cells(layers.get("roads", []), ASSET_LIBRARY.DEFAULT_ROAD)
	_build_roads(road_cells)
	var field_cells := TOWN_MAP_RULES.collect_material_cells(layers.get("fields", []), ASSET_LIBRARY.DEFAULT_FIELD)
	for cell_value in field_cells.keys():
		TOWN_MAP_RULES.set_material_cell(_fields, cell_value, str(field_cells[cell_value]))
	var water_cells := TOWN_MAP_RULES.collect_material_cells(layers.get("water", []), ASSET_LIBRARY.DEFAULT_WATER)
	for cell_value in water_cells.keys():
		TOWN_MAP_RULES.set_material_cell(_water, cell_value, str(water_cells[cell_value]))


func _paint_rect(layer: TileMapLayer, spec: Dictionary, tiles: Dictionary) -> void:
	var tile_index := int(tiles.get(str(spec.get("tile", "meadow")), 37))
	var origin := Vector2i(int(spec.get("x", 0)), int(spec.get("y", 0)))
	var width := int(spec.get("width", 1))
	var height := int(spec.get("height", 1))
	for y in range(height):
		for x in range(width):
			layer.set_cell(origin + Vector2i(x, y), 0, _atlas_coord(tile_index))


func _build_roads(road_cells: Dictionary) -> void:
	TOWN_MAP_RULES.build_roads(_roads, road_cells)


func _build_fences() -> void:
	for fence_spec in _map_data.get("fences", []):
		var origin := Vector2i(int(fence_spec.get("x", 0)), int(fence_spec.get("y", 0)))
		var width := int(fence_spec.get("width", 1))
		var height := int(fence_spec.get("height", 1))
		for x in range(width):
			_fences.set_cell(origin + Vector2i(x, 0), 0, Vector2i(1, 0))
			_fences.set_cell(origin + Vector2i(x, height - 1), 0, Vector2i(1, 0))
		for y in range(1, height - 1):
			_fences.set_cell(origin + Vector2i(0, y), 0, Vector2i(0, 0))
			_fences.set_cell(origin + Vector2i(width - 1, y), 0, Vector2i(0, 0))


func _build_map_objects() -> void:
	for building in _map_data.get("buildings", []):
		_add_map_object(building)
	for decoration in _map_data.get("decorations", []):
		_add_map_object(decoration)
	for character in _map_data.get("characters", []):
		var controller := CHARACTER_CONTROLLER_CATALOG.normalize_controller(character.get("controller", {}))
		match str(controller.get("type", "none")):
			CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER:
				continue
			CHARACTER_CONTROLLER_CATALOG.TYPE_AI:
				_add_character_actor(character)
			_:
				_add_map_object(character)


func _add_map_object(object_data: Dictionary) -> void:
	var object := Node2D.new()
	object.name = str(object_data.get("id", object_data.get("asset", "Object")))
	object.set_script(MAP_OBJECT_SCRIPT)
	object.set("asset_id", str(object_data.get("asset", "")))
	object.set("object_name", str(object_data.get("name", "")))
	object.set("scale_factor", float(object_data.get("scale", 1.0)))
	object.set("shadow", bool(object_data.get("shadow", true)))
	object.set("render_order", ASSET_LIBRARY.object_render_order(object_data))
	object.set("character_appearance", _resolve_character_appearance(object_data))
	var character_action := _resolve_character_action(object_data)
	object.set("character_action", str(character_action.get("action", "idle")))
	object.set("character_direction", str(character_action.get("direction", "down")))
	object.set("character_action_loop", bool(character_action.get("loop", true)))
	var cell: Array = object_data.get("cell", [0, 0])
	object.position = Vector2(Vector2i(int(cell[0]), int(cell[1])) * TILE_SIZE) + Vector2(TILE_SIZE * 0.5, TILE_SIZE)
	_object_layer_node(ASSET_LIBRARY.object_render_layer(object_data)).add_child(object)


func _setup_player_controller() -> void:
	var player_instance := _player_character_instance()
	var player_data: Dictionary
	var appearance: Dictionary
	if not player_instance.is_empty():
		player_data = player_instance.duplicate(true)
		appearance = _resolve_character_appearance(player_instance)
		var action_data := _resolve_character_action(player_instance)
		player_data["action"] = str(action_data.get("action", "idle"))
		player_data["direction"] = str(action_data.get("direction", "down"))
		player_data["action_loop"] = bool(action_data.get("loop", true))
		var cell: Array = player_instance.get("cell", [0, 0])
		_player.position = Vector2(Vector2i(int(cell[0]), int(cell[1])) * TILE_SIZE) + Vector2(TILE_SIZE * 0.5, TILE_SIZE)
	else:
		var profile_id := str(_map_data.get("player_character_id", ""))
		var profile := _character_profile(profile_id)
		appearance = profile.get("appearance", {}) if not profile.is_empty() else CHARACTER_PART_CATALOG.default_appearance()
		var spawn: Array = _map_data.get("player_spawn", [47, 32])
		_player.position = Vector2(Vector2i(int(spawn[0]), int(spawn[1])) * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
		player_data = {
			"controller": {"type": CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER},
			"action": str(profile.get("default_action", "idle")),
			"direction": str(profile.get("default_direction", "down")),
			"action_loop": true,
			"scale": 1.0,
			"shadow": true,
		}
	if _player.has_method("configure_from_instance"):
		_player.call("configure_from_instance", player_data, CHARACTER_PART_CATALOG.normalize_appearance(appearance))
	elif _player.has_method("set_character_appearance"):
		_player.call("set_character_appearance", CHARACTER_PART_CATALOG.normalize_appearance(appearance))
	if _player.has_method("set_spawn_position"):
		_player.call("set_spawn_position", _player.position)


func _player_character_instance() -> Dictionary:
	for character_value in _map_data.get("characters", []):
		if not character_value is Dictionary:
			continue
		var controller := CHARACTER_CONTROLLER_CATALOG.normalize_controller(character_value.get("controller", {}))
		if str(controller.get("type", "none")) == CHARACTER_CONTROLLER_CATALOG.TYPE_PLAYER:
			return character_value
	return {}


func _add_character_actor(object_data: Dictionary) -> void:
	var actor := CharacterBody2D.new()
	actor.name = str(object_data.get("id", "AICharacter"))
	actor.set_script(CHARACTER_ACTOR_SCRIPT)
	var cell: Array = object_data.get("cell", [0, 0])
	actor.position = Vector2(Vector2i(int(cell[0]), int(cell[1])) * TILE_SIZE) + Vector2(TILE_SIZE * 0.5, TILE_SIZE)
	actor.set("map_size_cells", Vector2i(int(_map_data.get("size", [40, 24])[0]), int(_map_data.get("size", [40, 24])[1])))
	actor.z_index = ASSET_LIBRARY.object_render_order(object_data)
	_object_layer_node(ASSET_LIBRARY.object_render_layer(object_data)).add_child(actor)
	var actor_data := object_data.duplicate(true)
	var action_data := _resolve_character_action(object_data)
	actor_data["action"] = str(action_data.get("action", "idle"))
	actor_data["direction"] = str(action_data.get("direction", "down"))
	actor_data["action_loop"] = bool(action_data.get("loop", true))
	actor.call("configure_from_instance", actor_data, _resolve_character_appearance(object_data))
	actor.call("set_spawn_position", actor.position)


func _character_profile(profile_id: String) -> Dictionary:
	if profile_id.is_empty():
		return {}
	for profile_value in _map_data.get("character_profiles", []):
		if profile_value is Dictionary and str(profile_value.get("id", "")) == profile_id:
			return profile_value
	return {}


func _character_preset(preset_id: String) -> Dictionary:
	return CHARACTER_PRESET_LIBRARY.preset(preset_id) if not preset_id.is_empty() else {}


func _resolve_character_appearance(object_data: Dictionary) -> Dictionary:
	if not MAP_OBJECT_SCRIPT.is_character_asset(str(object_data.get("asset", ""))):
		return {}
	var profile := _character_profile(str(object_data.get("character_id", "")))
	if not profile.is_empty():
		return CHARACTER_PART_CATALOG.normalize_appearance(profile.get("appearance", {}))
	var preset := _character_preset(str(object_data.get("preset_id", "")))
	if not preset.is_empty():
		return CHARACTER_PART_CATALOG.normalize_appearance(preset.get("appearance", {}))
	return CHARACTER_PART_CATALOG.normalize_appearance(object_data.get("appearance", {}))


func _resolve_character_action(object_data: Dictionary) -> Dictionary:
	if not MAP_OBJECT_SCRIPT.is_character_asset(str(object_data.get("asset", ""))):
		return {"action": "idle", "direction": "down", "loop": true}
	var source: Dictionary = {}
	var profile := _character_profile(str(object_data.get("character_id", "")))
	if not profile.is_empty():
		source = profile
	else:
		var preset := _character_preset(str(object_data.get("preset_id", "")))
		if not preset.is_empty():
			source = preset
	return {
		"action": CHARACTER_ACTION_CATALOG.normalize_action(str(object_data.get("action", source.get("default_action", "idle")))),
		"direction": CHARACTER_ACTION_CATALOG.normalize_direction(str(object_data.get("direction", source.get("default_direction", "down")))),
		"loop": bool(object_data.get("action_loop", true)),
	}


func _object_layer_node(render_layer: String) -> Node2D:
	match ASSET_LIBRARY.normalize_render_layer(render_layer):
		ASSET_LIBRARY.RENDER_LAYER_GROUND_DECAL:
			return _ground_decal_objects
		ASSET_LIBRARY.RENDER_LAYER_FOREGROUND:
			return _foreground_objects
		_:
			return _world_objects


func _build_location_markers() -> void:
	for location in _map_data.get("locations", []):
		var marker := Node2D.new()
		marker.set_script(LOCATION_MARKER_SCRIPT)
		var cell: Array = location.get("cell", [0, 0])
		marker.position = Vector2(Vector2i(int(cell[0]), int(cell[1])) * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
		marker.set("location_id", str(location.get("id", "")))
		marker.set("display_name", str(location.get("name", location.get("id", ""))))
		_locations.add_child(marker)


func _atlas_coord(tile_index: int) -> Vector2i:
	return TOWN_MAP_RULES.atlas_coord(tile_index)
