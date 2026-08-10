@tool
class_name MapObject2D
extends Node2D

const CHARACTER_VISUAL_SCRIPT := preload("res://src2d/characters/character_visual_2d.gd")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const CHARACTER_ACTION_CATALOG := preload("res://src2d/characters/character_action_catalog.gd")
const CHARACTER_ASSET_ID := "character_composite"
const LEGACY_CHARACTER_ASSET_ID := "resident_pale_adventurer"

const ASSET_PATHS := {
	"house_1": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/7 House/1.png",
	"house_2": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/7 House/2.png",
	"house_3": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/7 House/3.png",
	"house_4": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/7 House/4.png",
	"tent_1": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/6 Tent/1.png",
	"tent_2": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/6 Tent/2.png",
	"tent_3": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/6 Tent/3.png",
	"tent_4": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/6 Tent/4.png",
	"decor_1": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/1.png",
	"decor_2": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/2.png",
	"decor_3": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/3.png",
	"decor_5": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/5.png",
	"decor_7": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/7.png",
	"decor_8": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/8.png",
	"decor_9": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/9.png",
	"decor_10": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/10.png",
	"decor_12": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/12.png",
	"decor_14": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/14.png",
	"decor_15": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/15.png",
	"decor_16": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/16.png",
	"decor_17": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/3 Decor/17.png",
	"box_1": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/4 Box/1.png",
	"box_2": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/4 Box/2.png",
	"box_3": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/4 Box/3.png",
	"box_4": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/4 Box/4.png",
	"box_5": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/4 Box/5.png",
	"stone_1": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/2 Stone/1.png",
	"stone_2": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/2 Stone/2.png",
	"stone_3": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/2 Stone/3.png",
	"stone_4": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/2 Stone/4.png",
	"stone_5": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/2 Stone/5.png",
	"stone_6": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/2 Stone/6.png",
	"grass_1": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/5 Grass/1.png",
	"grass_2": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/5 Grass/2.png",
	"grass_3": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/5 Grass/3.png",
	"grass_4": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/5 Grass/4.png",
	"grass_5": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/5 Grass/5.png",
	"grass_6": "res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/2 Objects/5 Grass/6.png",
	"tree_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Tree1.png",
	"tree_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Tree2.png",
	"bush_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/9 Bush/1.png",
	"bush_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/9 Bush/2.png",
	"bush_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/9 Bush/3.png",
	"bush_4": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/9 Bush/4.png",
	"bush_5": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/9 Bush/5.png",
	"bush_6": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/9 Bush/6.png",
	"flower_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/1.png",
	"flower_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/2.png",
	"flower_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/3.png",
	"flower_4": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/4.png",
	"flower_5": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/5.png",
	"flower_6": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/6.png",
	"flower_7": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/7.png",
	"flower_8": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/8.png",
	"flower_9": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/9.png",
	"flower_10": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/10.png",
	"flower_11": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/11.png",
	"flower_12": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/6 Flower/12.png",
	"camp_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/8 Camp/1.png",
	"camp_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/8 Camp/2.png",
	"camp_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/8 Camp/3.png",
	"field_box_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Box1.png",
	"field_box_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Box2.png",
	"field_box_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Box3.png",
	"field_box_4": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Box4.png",
	"field_lamp_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Lamp1.png",
	"field_lamp_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Lamp2.png",
	"field_lamp_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Lamp3.png",
	"field_lamp_4": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Lamp4.png",
	"field_lamp_5": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Lamp5.png",
	"field_lamp_6": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Lamp6.png",
	"field_log_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Log1.png",
	"field_log_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Log2.png",
	"field_log_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Log3.png",
	"field_log_4": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Log4.png",
	"fence_piece_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/1.png",
	"fence_piece_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/2.png",
	"fence_piece_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/3.png",
	"fence_piece_4": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/4.png",
	"fence_piece_5": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/5.png",
	"fence_piece_6": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/6.png",
	"fence_piece_7": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/7.png",
	"fence_piece_8": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/8.png",
	"fence_piece_9": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/9.png",
	"fence_piece_10": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/2 Fence/10.png",
	"dirt_patch_1": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Dirt1.png",
	"dirt_patch_2": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Dirt2.png",
	"dirt_patch_3": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Dirt3.png",
	"dirt_patch_4": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Dirt4.png",
	"dirt_patch_5": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Dirt5.png",
	"dirt_patch_6": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/2 Objects/7 Decor/Dirt6.png",
}

const ANIMATED_ASSETS := {
	"flag_1": {
		"fps": 8.0,
		"layers": [{"path": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/3 Animated Objects/1 Flag/1.png", "frame_size": Vector2i(32, 64)}],
	},
	"flag_2": {
		"fps": 8.0,
		"layers": [{"path": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/3 Animated Objects/1 Flag/2.png", "frame_size": Vector2i(32, 64)}],
	},
	"flag_3": {
		"fps": 8.0,
		"layers": [{"path": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/3 Animated Objects/1 Flag/3.png", "frame_size": Vector2i(32, 64)}],
	},
	"flag_4": {
		"fps": 8.0,
		"layers": [{"path": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/3 Animated Objects/1 Flag/4.png", "frame_size": Vector2i(32, 64)}],
	},
	"flag_5": {
		"fps": 8.0,
		"layers": [{"path": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/3 Animated Objects/1 Flag/5.png", "frame_size": Vector2i(32, 64)}],
	},
	"campfire_lit": {
		"preview_layer": 1,
		"layers": [
			{"path": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/3 Animated Objects/2 Campfire/1.png", "frame_size": Vector2i(32, 64), "fps": 6.0},
			{"path": "res://assets/craftpix/craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/3 Animated Objects/2 Campfire/2.png", "frame_size": Vector2i(32, 32), "fps": 10.0},
		],
	},
}

const TILE_SIZE := 32.0
const RENDER_ORDER_MIN := -1000
const RENDER_ORDER_MAX := 1000

@export var asset_id := ""
@export var object_name := ""
@export var scale_factor := 1.0
@export var shadow := true
@export_range(RENDER_ORDER_MIN, RENDER_ORDER_MAX, 1) var render_order := 0
var character_appearance: Dictionary = {}
var character_action := "idle"
var character_direction := "down"
var character_action_loop := true

var _visual_root: Node2D


static func texture_for(id: String) -> Texture2D:
	if is_character_asset(id):
		return CHARACTER_PART_CATALOG.composite_frame_texture(CHARACTER_PART_CATALOG.default_appearance())
	var path: String = ASSET_PATHS.get(id, "")
	if not path.is_empty():
		return load(path)
	var animation: Dictionary = ANIMATED_ASSETS.get(id, {})
	if animation.is_empty():
		return null
	var layers: Array = animation.get("layers", [])
	if layers.is_empty():
		return null
	var preview_index := clampi(int(animation.get("preview_layer", 0)), 0, layers.size() - 1)
	return _first_animation_frame(layers[preview_index])


static func is_animated(id: String) -> bool:
	return ANIMATED_ASSETS.has(id)


static func is_character_asset(id: String) -> bool:
	return id == CHARACTER_ASSET_ID or id == LEGACY_CHARACTER_ASSET_ID


static func animation_layer_count(id: String) -> int:
	var animation: Dictionary = ANIMATED_ASSETS.get(id, {})
	return animation.get("layers", []).size()


func _ready() -> void:
	if _visual_root == null:
		_create_visual()
	# Equal instance orders keep using the parent layer's Y sort. A different
	# order lets the map author explicitly force this instance behind or ahead.
	z_index = clampi(render_order, RENDER_ORDER_MIN, RENDER_ORDER_MAX)
	queue_redraw()


func _create_visual() -> void:
	_visual_root = Node2D.new()
	_visual_root.name = "Visual"
	add_child(_visual_root)
	if is_character_asset(asset_id):
		_create_character_visual()
	elif is_animated(asset_id):
		_create_animated_visuals()
	else:
		_create_static_sprite()


func _create_character_visual() -> void:
	var visual := Node2D.new()
	visual.name = "CharacterVisual"
	visual.set_script(CHARACTER_VISUAL_SCRIPT)
	visual.set("appearance", CHARACTER_PART_CATALOG.normalize_appearance(character_appearance))
	visual.set("action_id", CHARACTER_ACTION_CATALOG.normalize_action(character_action))
	visual.set("action_loop", character_action_loop)
	visual.set("direction_row", CHARACTER_ACTION_CATALOG.direction_row(character_direction))
	visual.scale = Vector2.ONE * scale_factor
	_visual_root.add_child(visual)


func _create_static_sprite() -> void:
	var texture := texture_for(asset_id)
	if texture == null:
		push_warning("[MapObject2D] unknown asset: %s" % asset_id)
		return
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = texture
	sprite.centered = false
	sprite.position = Vector2(-texture.get_width() * scale_factor * 0.5, -texture.get_height() * scale_factor)
	sprite.scale = Vector2.ONE * scale_factor
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_visual_root.add_child(sprite)


func _create_animated_visuals() -> void:
	var animation: Dictionary = ANIMATED_ASSETS.get(asset_id, {})
	var fps := float(animation.get("fps", 8.0))
	var layers: Array = animation.get("layers", [])
	for layer_index in layers.size():
		var layer_spec: Dictionary = layers[layer_index]
		var layer_fps := float(layer_spec.get("fps", fps))
		var texture: Texture2D = load(str(layer_spec.get("path", "")))
		var frame_size: Vector2i = layer_spec.get("frame_size", Vector2i(32, 32))
		if texture == null or frame_size.x <= 0 or frame_size.y <= 0:
			continue
		var frame_count := maxi(1, texture.get_width() / frame_size.x)
		var frames := SpriteFrames.new()
		frames.set_animation_speed(&"default", layer_fps)
		frames.set_animation_loop(&"default", true)
		for frame_index in frame_count:
			var frame := AtlasTexture.new()
			frame.atlas = texture
			frame.region = Rect2(Vector2i(frame_index * frame_size.x, 0), frame_size)
			frames.add_frame(&"default", frame)
		var sprite := AnimatedSprite2D.new()
		sprite.name = "AnimatedLayer%d" % (layer_index + 1)
		sprite.sprite_frames = frames
		sprite.centered = false
		sprite.position = Vector2(-frame_size.x * scale_factor * 0.5, -frame_size.y * scale_factor)
		sprite.scale = Vector2.ONE * scale_factor
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_visual_root.add_child(sprite)
		sprite.play(&"default")
		sprite.frame = absi(("%s:%s:%d" % [name, asset_id, layer_index]).hash()) % frame_count


static func _first_animation_frame(layer_spec: Dictionary) -> Texture2D:
	var texture: Texture2D = load(str(layer_spec.get("path", "")))
	var frame_size: Vector2i = layer_spec.get("frame_size", Vector2i(32, 32))
	if texture == null:
		return null
	var frame := AtlasTexture.new()
	frame.atlas = texture
	frame.region = Rect2(Vector2i.ZERO, frame_size)
	return frame


func _draw() -> void:
	if not shadow:
		return
	var texture := texture_for(asset_id)
	if texture == null:
		return
	var radius := maxf(12.0, texture.get_width() * scale_factor * 0.34)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.42))
	draw_circle(Vector2(0.0, 3.0), radius, Color(0.08, 0.07, 0.04, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
