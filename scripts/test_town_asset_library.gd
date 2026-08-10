extends SceneTree

const FIELDS_TEXTURE := preload("res://assets/craftpix/craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/1 Tiles/FieldsTileset.png")
const ASSET_LIBRARY := preload("res://src2d/data/town_asset_library.gd")
const MAP_RULES := preload("res://src2d/world/town_map_rules_2d.gd")
const MAP_OBJECT_SCRIPT := preload("res://src2d/world/map_object_2d.gd")
const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var primary_categories := ASSET_LIBRARY.primary_categories()
	if primary_categories.size() != 5:
		_fail("一级素材分类不是环境、建筑、人物、特效、物品五类")
		return
	var primary_ids := {}
	for primary_value in primary_categories:
		primary_ids[str(primary_value.get("id", ""))] = true
	var categories := ASSET_LIBRARY.categories()
	if categories.size() < 17:
		_fail("二级素材分类数量不足")
		return
	for category_value in categories:
		if not primary_ids.has(str(category_value.get("parent", ""))):
			_fail("二级素材分类没有有效一级分类：%s" % str(category_value.get("id", "")))
			return
	if ASSET_LIBRARY.items_for_category("ground").size() < 3:
		_fail("草地材质少于 3 种")
		return
	if ASSET_LIBRARY.items_for_category("road").size() < 3:
		_fail("道路材质少于 3 种")
		return
	if ASSET_LIBRARY.items_for_category("barriers").size() != 10:
		_fail("独立栅栏没有完整接入 10 个")
		return
	if ASSET_LIBRARY.items_for_category("ground_details").size() != 6:
		_fail("泥土斑块没有完整接入 6 个")
		return
	if ASSET_LIBRARY.items_for_category("flags").size() != 5 or ASSET_LIBRARY.items_for_category("fire").size() != 1:
		_fail("特效分类没有完整接入 5 面旗帜和 1 个篝火")
		return
	if ASSET_LIBRARY.items_for_category("residents").size() != 0:
		_fail("人物分类仍然包含固定成品角色")
		return
	var object_count := 0
	for item_value in ASSET_LIBRARY.all_items():
		if not item_value is Dictionary or str(item_value.get("kind", "")) != "object":
			continue
		object_count += 1
		var catalog_asset_id := str(item_value.get("id", ""))
		if MAP_OBJECT_SCRIPT.texture_for(catalog_asset_id) == null:
			_fail("素材库对象没有可用纹理：%s" % catalog_asset_id)
			return
	if object_count != 97:
		_fail("素材库对象数量异常：%d" % object_count)
		return
	for asset_id in ["fence_piece_1", "fence_piece_10", "dirt_patch_1", "dirt_patch_6", "flag_1", "flag_5", "campfire_lit", "character_composite"]:
		if MAP_OBJECT_SCRIPT.texture_for(asset_id) == null:
			_fail("素材没有可用预览：%s" % asset_id)
			return
	var resident_texture: Texture2D = MAP_OBJECT_SCRIPT.texture_for("character_composite")
	if resident_texture.get_size() != Vector2(48, 48):
		_fail("居民预览没有裁成 48×48 待机帧")
		return
	if ASSET_LIBRARY.render_layer("dirt_patch_1") != ASSET_LIBRARY.RENDER_LAYER_GROUND_DECAL:
		_fail("泥土斑块没有进入地面贴花层")
		return
	for asset_id in ["house_1", "flag_1", "fence_piece_1"]:
		if ASSET_LIBRARY.render_layer(asset_id) != ASSET_LIBRARY.RENDER_LAYER_WORLD:
			_fail("世界对象层级错误：%s" % asset_id)
			return
	if ASSET_LIBRARY.object_render_layer({"asset": "house_1", "render_layer": "foreground"}) != ASSET_LIBRARY.RENDER_LAYER_FOREGROUND:
		_fail("地图对象 render_layer 覆盖没有生效")
		return
	if ASSET_LIBRARY.object_render_order({"asset": "house_1", "render_order": 77}) != 77:
		_fail("地图对象 render_order 覆盖没有生效")
		return
	if ASSET_LIBRARY.object_render_order({"asset": "house_1", "render_order": 9999}) != ASSET_LIBRARY.RENDER_ORDER_MAX:
		_fail("地图对象 render_order 没有限制到安全范围")
		return

	var cells := {
		Vector2i(1, 1): "road_gray_cobble",
		Vector2i(2, 1): "road_gray_cobble",
		Vector2i(3, 1): "road_forest_cobble",
	}
	var specs := MAP_RULES.material_cells_to_rects(cells)
	var restored := MAP_RULES.collect_material_cells(specs, ASSET_LIBRARY.DEFAULT_ROAD)
	if restored != cells:
		_fail("材质格序列化往返不一致")
		return

	var tileset := MAP_RULES.make_material_tileset(FIELDS_TEXTURE)
	if tileset.get_source_count() != ASSET_LIBRARY.TERRAIN_SOURCES.size():
		_fail("材质 TileSet source 数量不一致")
		return
	var layer := TileMapLayer.new()
	layer.tile_set = tileset
	MAP_RULES.build_roads(layer, cells)
	if layer.get_cell_source_id(Vector2i(1, 1)) != 3:
		_fail("灰石道路没有使用灰石 source")
		return
	if layer.get_cell_source_id(Vector2i(3, 1)) != 4:
		_fail("林地道路没有使用褐石 source")
		return
	if layer.get_cell_atlas_coords(Vector2i(3, 1)) != MAP_RULES.atlas_coord(MAP_RULES.road_tile(15)):
		_fail("不同道路材质没有独立收边")
		return

	var legacy := TOWN_PROJECT.normalize_map({
		"version": 4,
		"size": [12, 10],
		"layers": {"roads": [{"x": 1, "y": 2, "width": 2, "height": 1}]},
	})
	if int(legacy.get("version", 0)) != 7:
		_fail("旧地图没有升级到 v7")
		return
	var legacy_roads: Array = legacy.get("layers", {}).get("roads", [])
	if legacy_roads.is_empty() or str(legacy_roads[0].get("material", "")) != ASSET_LIBRARY.DEFAULT_ROAD:
		_fail("旧道路没有迁移默认材质")
		return

	var flag := Node2D.new()
	flag.set_script(MAP_OBJECT_SCRIPT)
	flag.set("asset_id", "flag_1")
	flag.set("render_order", 25)
	root.add_child(flag)
	var campfire := Node2D.new()
	campfire.set_script(MAP_OBJECT_SCRIPT)
	campfire.set("asset_id", "campfire_lit")
	root.add_child(campfire)
	var resident := Node2D.new()
	resident.set_script(MAP_OBJECT_SCRIPT)
	resident.set("asset_id", "character_composite")
	resident.set("character_appearance", CHARACTER_PART_CATALOG.default_appearance())
	root.add_child(resident)
	await process_frame
	if flag.z_index != 25 or campfire.z_index != 0:
		_fail("MapObject2D 没有使用实例 render_order")
		return
	var flag_visual := flag.get_node_or_null("Visual")
	var campfire_visual := campfire.get_node_or_null("Visual")
	var resident_visual := resident.get_node_or_null("Visual")
	if flag_visual == null or flag_visual.get_child_count() != 1:
		_fail("旗帜动画层创建失败")
		return
	if campfire_visual == null or campfire_visual.get_child_count() != 2:
		_fail("篝火没有创建火焰与烟雾双层动画")
		return
	if resident_visual == null or resident_visual.get_child_count() != 1:
		_fail("居民组件视觉根节点创建失败")
		return
	var composite_visual := resident_visual.get_child(0) as Node2D
	var expected_part_count := CHARACTER_PART_CATALOG.selected_parts(CHARACTER_PART_CATALOG.default_appearance()).size()
	if composite_visual == null or composite_visual.get_child_count() != expected_part_count:
		_fail("居民没有按组件数量创建分层视觉")
		return
	var resident_sprite := composite_visual.get_child(0) as Sprite2D
	if resident_sprite == null or resident_sprite.position != Vector2(-24, -48) or resident_sprite.region_rect.size != Vector2(48, 48):
		_fail("居民组件没有使用 48×48 待机帧和脚底中心锚点")
		return
	var flag_sprite := flag_visual.get_child(0) as AnimatedSprite2D
	if flag_sprite == null or flag_sprite.sprite_frames.get_frame_count(&"default") != 6 or not flag_sprite.is_playing():
		_fail("旗帜没有播放 6 帧循环动画")
		return
	flag.free()
	campfire.free()
	resident.free()

	layer.tile_set = null
	layer.free()
	tileset = null
	await process_frame
	print("[TownAssetLibraryTest] PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("[TownAssetLibraryTest] %s" % message)
	quit(1)
