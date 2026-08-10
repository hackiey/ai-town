@tool
extends Node2D

@export var location_id := ""
@export var display_name := ""


func _ready() -> void:
	z_as_relative = false
	z_index = 4090
	queue_redraw()


func _draw() -> void:
	const WOOD := Color(0.24, 0.12, 0.07, 0.94)
	const BORDER := Color(0.91, 0.62, 0.29, 1.0)
	if display_name.is_empty():
		return
	var font := ThemeDB.fallback_font
	var name_size := font.get_string_size(display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
	var panel := Rect2(Vector2(-name_size.x * 0.5 - 8.0, -34.0), Vector2(name_size.x + 16.0, 22.0))
	draw_rect(panel, WOOD, true)
	draw_rect(panel, BORDER, false, 1.0)
	draw_string(font, Vector2(panel.position.x + 8.0, -19.0), display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.92, 0.72))
