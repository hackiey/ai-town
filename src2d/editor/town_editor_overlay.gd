extends Node2D

const TILE_SIZE := 32.0

var map_size := Vector2i.ZERO
var hovered_cell := Vector2i(-1, -1)
var selected_tool := "road"
var show_grid := true
var preview_active := false
var preview_cell := Vector2i(-1, -1)
var preview_footprint := Vector2i.ONE
var preview_valid := false
var selected_active := false
var selected_cell := Vector2i(-1, -1)
var selected_footprint := Vector2i.ONE


func _draw() -> void:
	if map_size.x <= 0 or map_size.y <= 0:
		return
	var map_rect := Rect2(Vector2.ZERO, Vector2(float(map_size.x), float(map_size.y)) * TILE_SIZE)
	draw_rect(map_rect, Color(0.72, 0.91, 0.45, 0.85), false, 2.0)
	if show_grid:
		var grid_color := Color(0.05, 0.08, 0.05, 0.18)
		for x in range(map_size.x + 1):
			var px := float(x) * TILE_SIZE
			draw_line(Vector2(px, 0), Vector2(px, map_rect.size.y), grid_color, 1.0)
		for y in range(map_size.y + 1):
			var py := float(y) * TILE_SIZE
			draw_line(Vector2(0, py), Vector2(map_rect.size.x, py), grid_color, 1.0)
	if hovered_cell.x >= 0 and hovered_cell.y >= 0 and hovered_cell.x < map_size.x and hovered_cell.y < map_size.y:
		var cell_rect := Rect2(Vector2(hovered_cell) * TILE_SIZE, Vector2.ONE * TILE_SIZE)
		var color := Color(0.25, 0.9, 1.0, 0.3)
		if selected_tool == "ground":
			color = Color(0.55, 0.95, 0.3, 0.3)
		elif selected_tool == "road":
			color = Color(0.95, 0.55, 0.3, 0.35)
		elif selected_tool == "field":
			color = Color(0.95, 0.72, 0.25, 0.35)
		elif selected_tool == "water":
			color = Color(0.2, 0.65, 1.0, 0.35)
		draw_rect(cell_rect, color, true)
		draw_rect(cell_rect, Color.WHITE, false, 2.0)
	if selected_active:
		_draw_footprint(selected_cell, selected_footprint, Color(0.25, 0.82, 1.0, 0.9), false)
	if preview_active:
		var preview_color := Color(0.35, 1.0, 0.45, 0.9) if preview_valid else Color(1.0, 0.25, 0.25, 0.95)
		_draw_footprint(preview_cell, preview_footprint, preview_color, false)


func _draw_footprint(anchor: Vector2i, footprint: Vector2i, color: Color, filled: bool) -> void:
	var origin := Vector2i(anchor.x - floori(float(footprint.x) / 2.0), anchor.y - footprint.y)
	var rect := Rect2(Vector2(origin) * TILE_SIZE, Vector2(footprint) * TILE_SIZE)
	if filled:
		draw_rect(rect, color, true)
	draw_rect(rect, color, false, 3.0)
