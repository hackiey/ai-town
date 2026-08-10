extends SceneTree

const MAP_PATH := "res://data/towns/town_2d_demo/map.json"
const SCENE_PATH := "res://src2d/levels/town_2d.tscn"
const TILE_SIZE := 32
const FIELDS_TEXTURE_PATH := "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/1 Tiles/FieldsTileset.png"
const FENCE_TEXTURE_PATH := "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/1.1 Tiles/Tileset2.png"
const MAP_OBJECT_SCRIPT := preload("res://src2d/world/map_object_2d.gd")
const TOWN_MAP_RULES := preload("res://src2d/world/town_map_rules_2d.gd")


func _init() -> void:
	call_deferred("_build")


func _build() -> void:
	var map_data := _load_map_data()
	var root := Node2D.new()
	root.name = "Town2D"
	root.set_script(load("res://src2d/levels/town_2d.gd"))

	var map_root := Node2D.new()
	map_root.name = "Map"
	root.add_child(map_root)
	map_root.owner = root
	var field_tileset := _make_atlas_tileset(load(FIELDS_TEXTURE_PATH))
	var fence_tileset := _make_atlas_tileset(load(FENCE_TEXTURE_PATH))
	var ground := _new_tile_layer("Ground", map_root, field_tileset)
	var roads := _new_tile_layer("Roads", map_root, field_tileset)
	var fields := _new_tile_layer("Fields", map_root, field_tileset)
	var water := _new_tile_layer("Water", map_root, field_tileset)
	var fences := _new_tile_layer("Fences", map_root, fence_tileset)
	_build_tiles(map_data, ground, roads, fields, water, fences)

	var buildings := Node2D.new()
	buildings.name = "Buildings"
	root.add_child(buildings)
	buildings.owner = root
	for building in map_data.get("buildings", []):
		_add_map_object(buildings, building)
	for decoration in map_data.get("decorations", []):
		_add_map_object(buildings, decoration)

	var locations := Node2D.new()
	locations.name = "Locations"
	root.add_child(locations)
	locations.owner = root
	for location in map_data.get("locations", []):
		_add_location(locations, location)

	var characters := Node2D.new()
	characters.name = "Characters"
	root.add_child(characters)
	characters.owner = root
	var player := CharacterBody2D.new()
	player.name = "Player"
	var spawn: Array = map_data.get("player_spawn", [47, 32])
	player.position = Vector2(Vector2i(int(spawn[0]), int(spawn[1])) * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
	player.set_script(load("res://src2d/characters/player_2d.gd"))
	var map_size: Array = map_data.get("size", [96, 64])
	player.set("map_size_cells", Vector2i(int(map_size[0]), int(map_size[1])))
	characters.add_child(player)
	player.owner = root
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	var circle := CircleShape2D.new()
	circle.radius = 12.0
	collision.shape = circle
	player.add_child(collision)
	collision.owner = root
	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.zoom = Vector2(2.0, 2.0)
	camera.position_smoothing_enabled = false
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(map_size[0]) * TILE_SIZE
	camera.limit_bottom = int(map_size[1]) * TILE_SIZE
	player.add_child(camera)
	camera.owner = root

	var debug := Node2D.new()
	debug.name = "Debug"
	root.add_child(debug)
	debug.owner = root

	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		push_error("[Town2D] failed to pack scene: %s" % pack_error)
		quit(1)
		return
	var save_error := ResourceSaver.save(packed, SCENE_PATH)
	if save_error != OK:
		push_error("[Town2D] failed to save scene: %s" % save_error)
		quit(1)
		return
	print("[Town2D] baked scene: %s" % SCENE_PATH)
	quit()


func _load_map_data() -> Dictionary:
	var file := FileAccess.open(MAP_PATH, FileAccess.READ)
	if file == null:
		push_error("[Town2D] map data not found: %s" % MAP_PATH)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _make_atlas_tileset(texture: Texture2D) -> TileSet:
	return TOWN_MAP_RULES.make_atlas_tileset(texture)


func _new_tile_layer(layer_name: String, parent: Node, tileset: TileSet) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = tileset
	parent.add_child(layer)
	layer.owner = parent.owner
	return layer


func _build_tiles(map_data: Dictionary, ground: TileMapLayer, roads: TileMapLayer, fields: TileMapLayer, water: TileMapLayer, fences: TileMapLayer) -> void:
	var map_size: Array = map_data.get("size", [40, 24])
	var tiles: Dictionary = map_data.get("tiles", {})
	var meadow_index := int(tiles.get("meadow", 37))
	for y in range(int(map_size[1])):
		for x in range(int(map_size[0])):
			ground.set_cell(Vector2i(x, y), 0, _atlas_coord(meadow_index))
	_build_roads(roads, TOWN_MAP_RULES.collect_rect_cells(map_data.get("layers", {}).get("roads", [])))
	for spec in map_data.get("layers", {}).get("fields", []):
		_paint_rect(fields, spec, tiles)
	for spec in map_data.get("layers", {}).get("water", []):
		_paint_rect(water, spec, tiles)
	for spec in map_data.get("fences", []):
		var origin := Vector2i(int(spec.get("x", 0)), int(spec.get("y", 0)))
		var width := int(spec.get("width", 1))
		var height := int(spec.get("height", 1))
		for x in range(width):
			fences.set_cell(origin + Vector2i(x, 0), 0, Vector2i(1, 0))
			fences.set_cell(origin + Vector2i(x, height - 1), 0, Vector2i(1, 0))
		for y in range(1, height - 1):
			fences.set_cell(origin + Vector2i(0, y), 0, Vector2i(0, 0))
			fences.set_cell(origin + Vector2i(width - 1, y), 0, Vector2i(0, 0))


func _paint_rect(layer: TileMapLayer, spec: Dictionary, tiles: Dictionary) -> void:
	var tile_index := int(tiles.get(str(spec.get("tile", "meadow")), 37))
	var origin := Vector2i(int(spec.get("x", 0)), int(spec.get("y", 0)))
	var width := int(spec.get("width", 1))
	var height := int(spec.get("height", 1))
	for y in range(height):
		for x in range(width):
			layer.set_cell(origin + Vector2i(x, y), 0, _atlas_coord(tile_index))


func _build_roads(layer: TileMapLayer, road_cells: Dictionary) -> void:
	TOWN_MAP_RULES.build_roads(layer, road_cells)


func _add_map_object(parent: Node2D, object_data: Dictionary) -> void:
	var object := Node2D.new()
	object.name = str(object_data.get("id", object_data.get("asset", "Object")))
	object.set_script(MAP_OBJECT_SCRIPT)
	object.set("asset_id", str(object_data.get("asset", "")))
	object.set("object_name", str(object_data.get("name", "")))
	object.set("scale_factor", float(object_data.get("scale", 1.0)))
	object.set("shadow", bool(object_data.get("shadow", true)))
	var cell: Array = object_data.get("cell", [0, 0])
	object.position = Vector2(Vector2i(int(cell[0]), int(cell[1])) * TILE_SIZE) + Vector2(TILE_SIZE * 0.5, TILE_SIZE)
	parent.add_child(object)
	object.owner = parent.owner


func _add_location(parent: Node2D, location: Dictionary) -> void:
	var marker := Node2D.new()
	marker.name = str(location.get("id", "Location"))
	marker.set_script(load("res://src2d/world/location_marker_2d.gd"))
	var cell: Array = location.get("cell", [0, 0])
	marker.position = Vector2(Vector2i(int(cell[0]), int(cell[1])) * TILE_SIZE) + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
	marker.set("location_id", str(location.get("id", "")))
	marker.set("display_name", str(location.get("name", location.get("id", ""))))
	parent.add_child(marker)
	marker.owner = parent.owner


func _atlas_coord(tile_index: int) -> Vector2i:
	return TOWN_MAP_RULES.atlas_coord(tile_index)
