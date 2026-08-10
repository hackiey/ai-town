class_name TownAssetLibrary
extends RefCounted

const DEFAULT_GROUND := "ground_meadow"
const DEFAULT_ROAD := "road_warm_cobble"
const DEFAULT_FIELD := "field_tilled"
const DEFAULT_WATER := "water_clear"

const RENDER_LAYER_GROUND_DECAL := "ground_decal"
const RENDER_LAYER_WORLD := "world"
const RENDER_LAYER_FOREGROUND := "foreground"
const RENDER_ORDER_MIN := -1000
const RENDER_ORDER_MAX := 1000

const Z_GROUND := 0
const Z_FIELDS := 10
const Z_WATER := 20
const Z_ROADS := 30
const Z_GROUND_DECALS := 40
const Z_FENCES := 45
const Z_WORLD_OBJECTS := 50
const Z_FOREGROUND := 60
const Z_EDITOR_PREVIEW := 4000
const Z_EDITOR_OVERLAY := 4095

const PRIMARY_CATEGORIES := [
	{"id": "environment", "name": "环境"},
	{"id": "architecture", "name": "建筑"},
	{"id": "characters", "name": "人物"},
	{"id": "effects", "name": "特效"},
	{"id": "items", "name": "物品"},
]

const CATEGORIES := [
	{"id": "ground", "parent": "environment", "name": "地表"},
	{"id": "road", "parent": "environment", "name": "道路"},
	{"id": "field", "parent": "environment", "name": "农田"},
	{"id": "water", "parent": "environment", "name": "水面"},
	{"id": "vegetation", "parent": "environment", "name": "自然"},
	{"id": "barriers", "parent": "environment", "name": "围栏"},
	{"id": "ground_details", "parent": "environment", "name": "地面细节"},
	{"id": "buildings", "parent": "architecture", "name": "住宅"},
	{"id": "tents", "parent": "architecture", "name": "帐篷"},
	{"id": "camps", "parent": "architecture", "name": "营地设施"},
	{"id": "residents", "parent": "characters", "name": "居民"},
	{"id": "flags", "parent": "effects", "name": "旗帜"},
	{"id": "fire", "parent": "effects", "name": "火焰烟雾"},
	{"id": "village_props", "parent": "items", "name": "村庄杂物"},
	{"id": "containers", "parent": "items", "name": "箱子容器"},
	{"id": "lighting", "parent": "items", "name": "灯具"},
	{"id": "materials", "parent": "items", "name": "木料"},
]

# The two installed CraftPix packs contain the same terrain atlas. These source
# profiles deliberately derive palette-compatible variants from that canonical
# atlas so road connectivity stays pixel-perfect without duplicating a pack.
const TERRAIN_SOURCES := [
	{"source_id": 0, "mode": "original", "target": Color.WHITE, "amount": 0.0},
	{"source_id": 1, "mode": "grass", "target": Color("5f8f58"), "amount": 0.72},
	{"source_id": 2, "mode": "grass", "target": Color("b69a4d"), "amount": 0.72},
	{"source_id": 3, "mode": "road", "target": Color("8f918a"), "amount": 0.82},
	{"source_id": 4, "mode": "road", "target": Color("8d6748"), "amount": 0.78},
	{"source_id": 5, "mode": "grass", "target": Color("b88b3f"), "amount": 0.84},
	{"source_id": 6, "mode": "grass", "target": Color("3c8fc1"), "amount": 0.92},
	{"source_id": 7, "mode": "grass", "target": Color("245d88"), "amount": 0.94},
]

const TERRAIN_ITEMS := [
	{
		"id": "ground_meadow", "name": "青绿草地", "category": "ground", "kind": "terrain",
		"tool": "ground", "source_id": 0, "tile": 37,
		"description": "默认草地底色；适合村庄中心和普通野外。",
	},
	{
		"id": "ground_deep", "name": "深绿草地", "category": "ground", "kind": "terrain",
		"tool": "ground", "source_id": 1, "tile": 37,
		"description": "较阴湿的深绿色草地；适合树林和建筑背阴处。",
	},
	{
		"id": "ground_dry", "name": "枯黄草地", "category": "ground", "kind": "terrain",
		"tool": "ground", "source_id": 2, "tile": 37,
		"description": "偏黄的干燥草地；适合农场外围和荒地。",
	},
	{
		"id": "road_warm_cobble", "name": "暖色石板路", "category": "road", "kind": "terrain",
		"tool": "road", "source_id": 0, "tile": 0, "auto_tile": true,
		"description": "原始 CraftPix 暖色石板路，自动生成边缘与路口。",
	},
	{
		"id": "road_gray_cobble", "name": "灰石道路", "category": "road", "kind": "terrain",
		"tool": "road", "source_id": 3, "tile": 0, "auto_tile": true,
		"description": "保留同一套连通形状的灰色石路变体。",
	},
	{
		"id": "road_forest_cobble", "name": "林地褐石路", "category": "road", "kind": "terrain",
		"tool": "road", "source_id": 4, "tile": 0, "auto_tile": true,
		"description": "更暗的褐色道路，适合林地和营地。",
	},
	{
		"id": "field_tilled", "name": "翻耕土地", "category": "field", "kind": "terrain",
		"tool": "field", "source_id": 0, "tile": 10,
		"description": "暖色土壤地块。",
	},
	{
		"id": "field_golden", "name": "金黄田地", "category": "field", "kind": "terrain",
		"tool": "field", "source_id": 5, "tile": 37,
		"description": "金黄色田地，用于区分成熟作物区域。",
	},
	{
		"id": "water_clear", "name": "浅水", "category": "water", "kind": "terrain",
		"tool": "water", "source_id": 6, "tile": 37,
		"description": "清亮蓝色水面。",
	},
	{
		"id": "water_deep", "name": "深水", "category": "water", "kind": "terrain",
		"tool": "water", "source_id": 7, "tile": 37,
		"description": "较深的蓝色水面。",
	},
]


static func categories() -> Array:
	return CATEGORIES.duplicate(true)


static func primary_categories() -> Array:
	return PRIMARY_CATEGORIES.duplicate(true)


static func categories_for_primary(primary_id: String) -> Array:
	var matches: Array = []
	for category_value in CATEGORIES:
		if str(category_value.get("parent", "")) == primary_id:
			matches.append(category_value.duplicate(true))
	return matches


static func category(category_id: String) -> Dictionary:
	for category_value in CATEGORIES:
		if str(category_value.get("id", "")) == category_id:
			return category_value.duplicate(true)
	return {}


static func primary_category(primary_id: String) -> Dictionary:
	for category_value in PRIMARY_CATEGORIES:
		if str(category_value.get("id", "")) == primary_id:
			return category_value.duplicate(true)
	return {}


static func all_items() -> Array:
	var items: Array = TERRAIN_ITEMS.duplicate(true)
	_append_numbered(items, "buildings", "buildings", "house", "小屋", 1, 4, [4, 4])
	items[items.size() - 3]["footprint"] = [5, 5]
	items[items.size() - 2]["footprint"] = [5, 5]
	items[items.size() - 1]["footprint"] = [5, 5]
	_append_numbered(items, "tents", "buildings", "tent", "帐篷", 1, 4, [2, 3])
	items[items.size() - 4]["footprint"] = [3, 3]
	_append_numbered(items, "camps", "decorations", "camp", "营地设施", 1, 3, [2, 2])
	_append_numbered(items, "vegetation", "decorations", "tree", "树木", 1, 2, [2, 3])
	_append_numbered(items, "vegetation", "decorations", "bush", "灌木", 1, 6, [1, 1], 1.0, false)
	_append_numbered(items, "vegetation", "decorations", "grass", "草丛", 1, 6, [1, 1], 2.0, false)
	_append_numbered(items, "vegetation", "decorations", "flower", "花簇", 1, 12, [1, 1], 1.5, false)
	_append_numbered(items, "vegetation", "decorations", "stone", "石头", 1, 6, [1, 1], 2.0, false)
	for number in [1, 2, 3, 5, 7, 8, 9, 10, 12, 14, 15, 16, 17]:
		items.append(_object_item("decor_%d" % number, "村庄道具 %d" % number, "village_props", "decorations", [1, 1]))
	_append_numbered(items, "containers", "decorations", "box", "箱子", 1, 5, [1, 1])
	_append_numbered(items, "containers", "decorations", "field_box", "农场箱", 1, 4, [1, 1])
	_append_numbered(items, "lighting", "decorations", "field_lamp", "农场灯", 1, 6, [1, 1])
	_append_numbered(items, "materials", "decorations", "field_log", "木料", 1, 4, [1, 1])
	_append_numbered(items, "barriers", "decorations", "fence_piece", "栅栏组件", 1, 10, [1, 1], 1.0, false)
	_append_numbered(
		items,
		"ground_details",
		"decorations",
		"dirt_patch",
		"泥土斑块",
		1,
		6,
		[1, 1],
		2.0,
		false,
		RENDER_LAYER_GROUND_DECAL
	)
	_append_numbered(items, "flags", "decorations", "flag", "动态旗帜", 1, 5, [1, 2], 1.0, false)
	var flag_names := ["旗帜 · 正面", "旗帜 · 正面斜向", "旗帜 · 背面", "旗帜 · 背面斜向", "旗帜 · 侧面"]
	for index in flag_names.size():
		items[items.size() - flag_names.size() + index]["name"] = flag_names[index]
	var campfire := _object_item("campfire_lit", "动态篝火", "fire", "decorations", [1, 1], 1.0, false)
	campfire["description"] = "火焰与烟雾双层同步播放的 6 帧循环动画。"
	items.append(campfire)
	return items


static func items_for_category(category_id: String) -> Array:
	var matches: Array = []
	for item_value in all_items():
		if item_value is Dictionary and str(item_value.get("category", "")) == category_id:
			matches.append(item_value)
	return matches


static func item(asset_id: String) -> Dictionary:
	for item_value in all_items():
		if item_value is Dictionary and str(item_value.get("id", "")) == asset_id:
			return item_value
	return {}


static func terrain_material(material_id: String) -> Dictionary:
	for item_value in TERRAIN_ITEMS:
		if str(item_value.get("id", "")) == material_id:
			return item_value
	return {}


static func render_layer(asset_id: String) -> String:
	var asset := item(asset_id)
	return normalize_render_layer(str(asset.get("render_layer", RENDER_LAYER_WORLD)))


static func object_render_layer(object_data: Dictionary) -> String:
	var default_layer := render_layer(str(object_data.get("asset", "")))
	return normalize_render_layer(str(object_data.get("render_layer", default_layer)), default_layer)


static func render_order(asset_id: String) -> int:
	return clampi(int(item(asset_id).get("render_order", 0)), RENDER_ORDER_MIN, RENDER_ORDER_MAX)


static func object_render_order(object_data: Dictionary) -> int:
	var default_order := render_order(str(object_data.get("asset", "")))
	return clampi(int(object_data.get("render_order", default_order)), RENDER_ORDER_MIN, RENDER_ORDER_MAX)


static func render_layer_z(layer_id: String) -> int:
	return {
		RENDER_LAYER_GROUND_DECAL: Z_GROUND_DECALS,
		RENDER_LAYER_WORLD: Z_WORLD_OBJECTS,
		RENDER_LAYER_FOREGROUND: Z_FOREGROUND,
	}.get(normalize_render_layer(layer_id), Z_WORLD_OBJECTS)


static func final_render_order(object_data: Dictionary) -> int:
	return render_layer_z(object_render_layer(object_data)) + object_render_order(object_data)


static func normalize_render_layer(layer_id: String, fallback := RENDER_LAYER_WORLD) -> String:
	if layer_id in [RENDER_LAYER_GROUND_DECAL, RENDER_LAYER_WORLD, RENDER_LAYER_FOREGROUND]:
		return layer_id
	return fallback


static func render_layer_name(layer_id: String) -> String:
	return {
		RENDER_LAYER_GROUND_DECAL: "地面贴花层",
		RENDER_LAYER_WORLD: "世界对象层（按 Y 前后遮挡）",
		RENDER_LAYER_FOREGROUND: "前景层",
	}.get(normalize_render_layer(layer_id), "世界对象层（按 Y 前后遮挡）")


static func default_material(tool_id: String) -> String:
	return {
		"ground": DEFAULT_GROUND,
		"road": DEFAULT_ROAD,
		"field": DEFAULT_FIELD,
		"water": DEFAULT_WATER,
	}.get(tool_id, DEFAULT_GROUND)


static func source_profile(source_id: int) -> Dictionary:
	for source_value in TERRAIN_SOURCES:
		if int(source_value.get("source_id", -1)) == source_id:
			return source_value
	return TERRAIN_SOURCES[0]


static func minimap_color(material_id: String) -> Color:
	return {
		"ground_meadow": Color("6b8738"),
		"ground_deep": Color("477047"),
		"ground_dry": Color("a69045"),
		"road_warm_cobble": Color("d1784b"),
		"road_gray_cobble": Color("858883"),
		"road_forest_cobble": Color("7e5a40"),
		"field_tilled": Color("b56d3f"),
		"field_golden": Color("bd943e"),
		"water_clear": Color("2f87b8"),
		"water_deep": Color("1f577f"),
	}.get(material_id, Color("6b8738"))


static func _append_numbered(
	items: Array,
	category: String,
	collection: String,
	prefix: String,
	label: String,
	first: int,
	last: int,
	footprint: Array,
	scale := 1.0,
	shadow := true,
	render_layer := RENDER_LAYER_WORLD
) -> void:
	for number in range(first, last + 1):
		items.append(_object_item(
			"%s_%d" % [prefix, number],
			"%s %d" % [label, number],
			category,
			collection,
			footprint,
			scale,
			shadow,
			render_layer
		))


static func _object_item(
	asset_id: String,
	display_name: String,
	category: String,
	collection: String,
	footprint: Array,
	scale := 1.0,
	shadow := true,
	render_layer := RENDER_LAYER_WORLD,
	render_order := 0
) -> Dictionary:
	return {
		"id": asset_id,
		"name": display_name,
		"category": category,
		"kind": "object",
		"collection": collection,
		"footprint": footprint.duplicate(),
		"scale": scale,
		"shadow": shadow,
		"render_layer": render_layer,
		"render_order": clampi(render_order, RENDER_ORDER_MIN, RENDER_ORDER_MAX),
	}
