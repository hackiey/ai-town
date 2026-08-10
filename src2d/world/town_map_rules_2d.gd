class_name TownMapRules2D
extends RefCounted

const TILE_SIZE := 32
const ASSET_LIBRARY := preload("res://src2d/data/town_asset_library.gd")

const ROAD_TILES := {
	0: 0,
	1: 34,
	2: 8,
	3: 7,
	4: 1,
	5: 29,
	6: 23,
	7: 41,
	8: 12,
	9: 5,
	10: 31,
	11: 42,
	12: 21,
	13: 40,
	14: 43,
	15: 46,
}


static func make_atlas_tileset(texture: Texture2D, columns := 8, rows := 8) -> TileSet:
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
	var atlas := TileSetAtlasSource.new()
	atlas.texture = texture
	atlas.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
	for y in range(rows):
		for x in range(columns):
			atlas.create_tile(Vector2i(x, y))
	tileset.add_source(atlas, 0)
	return tileset


static func make_material_tileset(texture: Texture2D, columns := 8, rows := 8) -> TileSet:
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
	for profile_value in ASSET_LIBRARY.TERRAIN_SOURCES:
		var profile: Dictionary = profile_value
		var source_id := int(profile.get("source_id", 0))
		var atlas := TileSetAtlasSource.new()
		atlas.texture = _make_material_texture(texture, profile)
		atlas.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
		for y in range(rows):
			for x in range(columns):
				atlas.create_tile(Vector2i(x, y))
		tileset.add_source(atlas, source_id)
	return tileset


static func atlas_coord(tile_index: int) -> Vector2i:
	return Vector2i(tile_index % 8, tile_index / 8)


static func collect_rect_cells(specs: Variant) -> Dictionary:
	var cells := {}
	if specs is Dictionary:
		specs = [specs]
	if not specs is Array:
		return cells
	for spec in specs:
		if not spec is Dictionary:
			continue
		if spec.has("cells"):
			for cell_value in spec.get("cells", []):
				var cell: Variant = _to_cell(cell_value)
				if cell is Vector2i:
					cells[cell] = true
			continue
		var origin := Vector2i(int(spec.get("x", 0)), int(spec.get("y", 0)))
		var width := maxi(1, int(spec.get("width", 1)))
		var height := maxi(1, int(spec.get("height", 1)))
		for y in range(height):
			for x in range(width):
				cells[origin + Vector2i(x, y)] = true
	return cells


static func collect_material_cells(specs: Variant, default_material: String) -> Dictionary:
	var cells := {}
	if specs is Dictionary:
		specs = [specs]
	if not specs is Array:
		return cells
	for spec_value in specs:
		if not spec_value is Dictionary:
			continue
		var spec: Dictionary = spec_value
		var material_id := str(spec.get("material", spec.get("style", default_material)))
		if material_id.is_empty():
			material_id = default_material
		if spec.has("cells"):
			for cell_value in spec.get("cells", []):
				var cell: Variant = _to_cell(cell_value)
				if cell is Vector2i:
					cells[cell] = material_id
			continue
		var origin := Vector2i(int(spec.get("x", 0)), int(spec.get("y", 0)))
		var width := maxi(1, int(spec.get("width", 1)))
		var height := maxi(1, int(spec.get("height", 1)))
		for y in range(height):
			for x in range(width):
				cells[origin + Vector2i(x, y)] = material_id
	return cells


static func cells_to_rects(cells: Dictionary) -> Array:
	var rows := {}
	for cell_value in cells.keys():
		var cell: Vector2i = cell_value
		if not rows.has(cell.y):
			rows[cell.y] = []
		rows[cell.y].append(cell.x)
	var row_keys: Array = rows.keys()
	row_keys.sort()
	var specs: Array = []
	for y in row_keys:
		var xs: Array = rows[y]
		xs.sort()
		var start := -1
		var previous := -1
		for x in xs:
			if start < 0:
				start = int(x)
				previous = int(x)
				continue
			if int(x) != previous + 1:
				specs.append({"x": start, "y": int(y), "width": previous - start + 1, "height": 1})
				start = int(x)
			previous = int(x)
		if start >= 0:
			specs.append({"x": start, "y": int(y), "width": previous - start + 1, "height": 1})
	return specs


static func material_cells_to_rects(cells: Dictionary) -> Array:
	var rows := {}
	for cell_value in cells.keys():
		var cell: Vector2i = cell_value
		var material_id := str(cells.get(cell, ""))
		var row_key := "%d:%s" % [cell.y, material_id]
		if not rows.has(row_key):
			rows[row_key] = {"y": cell.y, "material": material_id, "xs": []}
		rows[row_key]["xs"].append(cell.x)
	var row_keys: Array = rows.keys()
	row_keys.sort_custom(func(a, b):
		var row_a: Dictionary = rows[a]
		var row_b: Dictionary = rows[b]
		if int(row_a.get("y", 0)) == int(row_b.get("y", 0)):
			return str(row_a.get("material", "")) < str(row_b.get("material", ""))
		return int(row_a.get("y", 0)) < int(row_b.get("y", 0))
	)
	var specs: Array = []
	for row_key in row_keys:
		var row: Dictionary = rows[row_key]
		var xs: Array = row.get("xs", [])
		xs.sort()
		var start := -1
		var previous := -1
		for x_value in xs:
			var x := int(x_value)
			if start < 0:
				start = x
				previous = x
				continue
			if x != previous + 1:
				specs.append(_material_rect(start, int(row.get("y", 0)), previous - start + 1, str(row.get("material", ""))))
				start = x
			previous = x
		if start >= 0:
			specs.append(_material_rect(start, int(row.get("y", 0)), previous - start + 1, str(row.get("material", ""))))
	return specs


static func paint_rect(layer: TileMapLayer, spec: Dictionary, tile_index: int) -> void:
	var origin := Vector2i(int(spec.get("x", 0)), int(spec.get("y", 0)))
	var width := maxi(1, int(spec.get("width", 1)))
	var height := maxi(1, int(spec.get("height", 1)))
	for y in range(height):
		for x in range(width):
			layer.set_cell(origin + Vector2i(x, y), 0, atlas_coord(tile_index))


static func build_roads(layer: TileMapLayer, road_cells: Dictionary) -> void:
	layer.clear()
	for cell_value in road_cells.keys():
		var cell: Vector2i = cell_value
		var material_id := _cell_material(road_cells, cell, ASSET_LIBRARY.DEFAULT_ROAD)
		var grass_mask := 0
		if not _road_connects(road_cells, cell + Vector2i.UP, material_id):
			grass_mask |= 1
		if not _road_connects(road_cells, cell + Vector2i.RIGHT, material_id):
			grass_mask |= 2
		if not _road_connects(road_cells, cell + Vector2i.DOWN, material_id):
			grass_mask |= 4
		if not _road_connects(road_cells, cell + Vector2i.LEFT, material_id):
			grass_mask |= 8
		var material := ASSET_LIBRARY.terrain_material(material_id)
		var source_id := int(material.get("source_id", 0))
		layer.set_cell(cell, source_id, atlas_coord(road_tile(grass_mask)))


static func set_material_cell(layer: TileMapLayer, cell: Vector2i, material_id: String) -> void:
	var material := ASSET_LIBRARY.terrain_material(material_id)
	if material.is_empty():
		return
	layer.set_cell(
		cell,
		int(material.get("source_id", 0)),
		atlas_coord(int(material.get("tile", 37)))
	)


static func material_preview_texture(texture: Texture2D, material_id: String) -> Texture2D:
	var material := ASSET_LIBRARY.terrain_material(material_id)
	if material.is_empty():
		return null
	var profile := ASSET_LIBRARY.source_profile(int(material.get("source_id", 0)))
	var atlas := AtlasTexture.new()
	atlas.atlas = _make_material_texture(texture, profile)
	var coord := atlas_coord(int(material.get("tile", 37)))
	atlas.region = Rect2(coord * TILE_SIZE, Vector2i(TILE_SIZE, TILE_SIZE))
	return atlas


static func road_tile(grass_mask: int) -> int:
	return int(ROAD_TILES.get(grass_mask, 0))


static func _material_rect(x: int, y: int, width: int, material_id: String) -> Dictionary:
	return {"x": x, "y": y, "width": width, "height": 1, "material": material_id}


static func _cell_material(cells: Dictionary, cell: Vector2i, fallback: String) -> String:
	var value: Variant = cells.get(cell, fallback)
	if value is String and not str(value).is_empty():
		return str(value)
	return fallback


static func _road_connects(cells: Dictionary, cell: Vector2i, material_id: String) -> bool:
	return cells.has(cell) and _cell_material(cells, cell, ASSET_LIBRARY.DEFAULT_ROAD) == material_id


static func _make_material_texture(texture: Texture2D, profile: Dictionary) -> Texture2D:
	if str(profile.get("mode", "original")) == "original":
		return texture
	var image := texture.get_image()
	if image == null or image.is_empty():
		return texture
	var mode := str(profile.get("mode", "original"))
	var target: Color = profile.get("target", Color.WHITE)
	var amount := clampf(float(profile.get("amount", 0.0)), 0.0, 1.0)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.a <= 0.0 or not _pixel_matches_material(pixel, mode):
				continue
			var brightness := clampf((pixel.r + pixel.g + pixel.b) / 3.0, 0.0, 1.0)
			var shade := lerpf(0.56, 1.18, brightness)
			var replacement := Color(
				clampf(target.r * shade, 0.0, 1.0),
				clampf(target.g * shade, 0.0, 1.0),
				clampf(target.b * shade, 0.0, 1.0),
				pixel.a
			)
			image.set_pixel(x, y, pixel.lerp(replacement, amount))
	return ImageTexture.create_from_image(image)


static func _pixel_matches_material(pixel: Color, mode: String) -> bool:
	if mode == "grass":
		return pixel.g >= pixel.r * 0.92 and pixel.g > pixel.b * 1.18
	if mode == "road":
		return pixel.r > pixel.g * 1.08 and pixel.r > pixel.b * 1.22
	return true


static func _to_cell(value: Variant):
	if value is Vector2i:
		return value
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return null
