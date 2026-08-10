extends CanvasLayer

@onready var _minimap: Control = $Minimap

var _pending_map_data: Dictionary = {}
var _pending_player: Node2D = null


func _ready() -> void:
	if not _pending_map_data.is_empty() and _pending_player != null:
		_minimap.setup(_pending_map_data, _pending_player)


func setup(map_data: Dictionary, player: Node2D) -> void:
	_pending_map_data = map_data
	_pending_player = player
	if is_node_ready():
		_minimap.setup(map_data, player)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_minimap"):
		_minimap.visible = not _minimap.visible
		get_viewport().set_input_as_handled()
