extends Control

const ASSET_LIBRARY := preload("res://src2d/data/town_asset_library.gd")

const PANEL_COLOR := Color(0.018, 0.027, 0.035, 0.94)
const PANEL_BORDER := Color(0.22, 0.75, 0.86, 0.95)
const MAP_GROUND := Color(0.42, 0.53, 0.22, 1.0)
const MAP_ROAD := Color(0.82, 0.47, 0.28, 1.0)
const MAP_FIELD := Color(0.75, 0.58, 0.24, 1.0)
const MAP_WATER := Color(0.12, 0.42, 0.68, 1.0)
const MAP_BUILDING := Color(0.29, 0.15, 0.09, 1.0)
const MAP_LOCATION := Color(0.15, 0.9, 1.0, 1.0)
const MAP_PLAYER := Color(1.0, 0.95, 0.3, 1.0)

var _map_data: Dictionary = {}
var _player: Node2D = null
var _last_player_position := Vector2.INF


func setup(map_data: Dictionary, player: Node2D) -> void:
	_map_data = map_data
	_player = player
	queue_redraw()


func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _last_player_position.distance_squared_to(_player.global_position) >= 4.0:
		_last_player_position = _player.global_position
		queue_redraw()


func _draw() -> void:
	if _map_data.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), PANEL_COLOR, true)
	draw_rect(Rect2(Vector2.ZERO, size), PANEL_BORDER, false, 2.0)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(16, 24), "小镇地图", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color.WHITE)
	draw_string(font, Vector2(size.x - 90, 23), "M 隐藏", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.65, 0.82, 0.86))

	var map_rect := _map_rect()
	var base_ground := str(_map_data.get("terrain", {}).get("base_ground", ASSET_LIBRARY.DEFAULT_GROUND))
	draw_rect(map_rect, ASSET_LIBRARY.minimap_color(base_ground), true)
	draw_rect(map_rect, Color(0.65, 0.82, 0.46, 1.0), false, 1.0)
	_draw_material_specs(map_rect, _map_data.get("layers", {}).get("ground", []), ASSET_LIBRARY.DEFAULT_GROUND)
	_draw_material_specs(map_rect, _map_data.get("layers", {}).get("water", []), ASSET_LIBRARY.DEFAULT_WATER)
	_draw_material_specs(map_rect, _map_data.get("layers", {}).get("fields", []), ASSET_LIBRARY.DEFAULT_FIELD)
	_draw_material_specs(map_rect, _map_data.get("layers", {}).get("roads", []), ASSET_LIBRARY.DEFAULT_ROAD)
	_draw_buildings(map_rect)
	_draw_locations(map_rect)
	_draw_player(map_rect)

	var coord_text := ""
	if _player != null and is_instance_valid(_player):
		var cell := Vector2i(floori(_player.global_position.x / 32.0), floori(_player.global_position.y / 32.0))
		coord_text = "位置  %d, %d" % [cell.x, cell.y]
	draw_string(font, Vector2(16, size.y - 10), coord_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.72, 0.86, 0.9))


func _map_rect() -> Rect2:
	var available := Rect2(Vector2(14, 34), Vector2(size.x - 28, size.y - 62))
	var map_size: Array = _map_data.get("size", [96, 64])
	var aspect := float(map_size[0]) / float(map_size[1])
	var width := available.size.x
	var height := width / aspect
	if height > available.size.y:
		height = available.size.y
		width = height * aspect
	return Rect2(available.position + (available.size - Vector2(width, height)) * 0.5, Vector2(width, height))


func _draw_specs(map_rect: Rect2, specs: Array, color: Color) -> void:
	for spec in specs:
		if spec is Dictionary:
			draw_rect(_cell_rect(map_rect, spec), color, true)


func _draw_material_specs(map_rect: Rect2, specs: Array, default_material: String) -> void:
	for spec in specs:
		if spec is Dictionary:
			var material_id := str(spec.get("material", spec.get("style", default_material)))
			draw_rect(_cell_rect(map_rect, spec), ASSET_LIBRARY.minimap_color(material_id), true)


func _draw_buildings(map_rect: Rect2) -> void:
	for building in _map_data.get("buildings", []):
		if not building is Dictionary:
			continue
		var cell: Array = building.get("cell", [0, 0])
		var building_size: Array = building.get("footprint", building.get("size", [1, 1]))
		var spec := {
			"x": int(cell[0]) - int(building_size[0]) / 2,
			"y": int(cell[1]) - int(building_size[1]),
			"width": int(building_size[0]),
			"height": int(building_size[1]),
		}
		var rect := _cell_rect(map_rect, spec)
		draw_rect(rect, MAP_BUILDING, true)
		draw_rect(rect, Color(0.9, 0.67, 0.32, 1.0), false, 1.0)


func _draw_locations(map_rect: Rect2) -> void:
	for location in _map_data.get("locations", []):
		if not location is Dictionary:
			continue
		var cell: Array = location.get("cell", [0, 0])
		var point := _cell_to_map(map_rect, Vector2(float(cell[0]) + 0.5, float(cell[1]) + 0.5))
		draw_circle(point, 2.5, MAP_LOCATION)


func _draw_player(map_rect: Rect2) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var cell_position := _player.global_position / 32.0
	var point := _cell_to_map(map_rect, cell_position)
	draw_circle(point, 5.0, Color(0.02, 0.03, 0.04, 0.9))
	draw_circle(point, 3.5, MAP_PLAYER)
	draw_arc(point, 6.0, 0.0, TAU, 20, Color.WHITE, 1.5)


func _cell_rect(map_rect: Rect2, spec: Dictionary) -> Rect2:
	var start := _cell_to_map(map_rect, Vector2(float(spec.get("x", 0)), float(spec.get("y", 0))))
	var finish := _cell_to_map(
		map_rect,
		Vector2(
			float(spec.get("x", 0)) + float(spec.get("width", 1)),
			float(spec.get("y", 0)) + float(spec.get("height", 1))
		)
	)
	return Rect2(start, finish - start)


func _cell_to_map(map_rect: Rect2, cell: Vector2) -> Vector2:
	var map_size: Array = _map_data.get("size", [96, 64])
	return map_rect.position + Vector2(
		cell.x / float(map_size[0]) * map_rect.size.x,
		cell.y / float(map_size[1]) * map_rect.size.y
	)
