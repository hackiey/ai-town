class_name Varieties

# 作物 variety 注册表。
# 真值在 data/mechanics/crops.lua 的 `varieties` 表；这里只做"按 id 拉数据 → 填 CropVariety
# 实例 → 缓存"，让其他 GDScript 代码继续用 `crop.variety.X` 风格访问。
#
# 加新作物：编辑 data/mechanics/crops.lua 的 varieties table，重启游戏。

static var _cache: Dictionary = {}   # id -> CropVariety
static var _ids_cache: Array = []


static func by_id(id: String) -> CropVariety:
	if id.is_empty():
		return null
	if _cache.has(id):
		return _cache[id]
	var lua_v = MechanicHost.query("crops", "get_variety", [id])
	if lua_v == null:
		return null
	var v := _from_lua(lua_v)
	_cache[id] = v
	return v


static func has_id(id: String) -> bool:
	return by_id(id) != null


static func all_ids() -> Array:
	if _ids_cache.is_empty():
		var lua_ids = MechanicHost.query("crops", "variety_ids", [])
		_ids_cache = LuaConv.to_string_array(lua_ids)
	return _ids_cache


# 给 farm_group 用：直接问 lua（避免 GDScript 这边重复实现规则）
static func pest_eligible_stage(variety_id: String, stage: String) -> bool:
	var r = MechanicHost.query("crops", "pest_eligible_stage", [variety_id, stage])
	return bool(r) if r != null else false


static func is_ripe_stage(variety_id: String, stage: String) -> bool:
	var r = MechanicHost.query("crops", "is_ripe_stage", [variety_id, stage])
	return bool(r) if r != null else false


# 由 spawn 时间 + variety 推 stage 字符串（hydrate / fresh spawn 用，不走 tick）
# 两个时间参数都是自开服累计 game-hour，不是 hour-of-day。
static func compute_stage(variety_id: String, spawned_at_total_hour: int, current_total_hour: int) -> String:
	var r = MechanicHost.query("crops", "compute_stage", [variety_id, spawned_at_total_hour, current_total_hour])
	return str(r) if r != null else ""


static func compute_maturity(care_sum: float, care_count: int) -> int:
	var r = MechanicHost.query("crops", "compute_maturity", [care_sum, care_count])
	return int(r) if r != null else 100


# Stage 显示名查询。共享 i18n catalog 与 backend：先按 variety 覆盖找
# `prompt.context.crop_stage.<variety_id>.<stage_id>`，不命中再走
# `prompt.context.crop_stage.default.<stage_id>`，再不命中返回 stage 字面值。
# 加新 variety 想要专属说法（如 wheat 用"分蘖/抽穗"）只需在
# data/i18n/zh/prompts.json 的 prompt.context.crop_stage.<variety>.* 加 key。
static func display_stage_name(variety_id: String, stage_id: String) -> String:
	if stage_id.is_empty():
		return ""
	# 走 TranslationServer.translate 而不是 tr()——tr() 是 Object 实例方法，static
	# 上下文无 self 可绑；TranslationServer 是 singleton，直接静态调即可。
	# 未命中行为同 tr()：返回 key 本身。
	var variety_key := "prompt.context.crop_stage.%s.%s" % [variety_id, stage_id]
	var translated := str(TranslationServer.translate(variety_key))
	if translated != variety_key:
		return translated
	var default_key := "prompt.context.crop_stage.default.%s" % stage_id
	var translated_default := str(TranslationServer.translate(default_key))
	if translated_default != default_key:
		return translated_default
	return stage_id


# Lua table → CropVariety carrier
static func _from_lua(t) -> CropVariety:
	var v := CropVariety.new()
	v.id = str(t["id"])
	v.display_name = str(t["display_name"])
	v.stages = LuaConv.to_string_array(t["stages"])
	v.maturation_hours = int(t["maturation_hours"])
	v.harvest_returns_to_stage = str(t["harvest_returns_to_stage"])
	v.max_harvests = int(t["max_harvests"])
	v.yield_decay_per_harvest = float(t["yield_decay_per_harvest"])
	v.harvest_yield_id = str(t["harvest_yield_id"])
	v.harvest_yield_quantity = int(t["harvest_yield_quantity"])
	v.moisture_decay_per_hour = float(t["moisture_decay_per_hour"])
	v.optimal_moisture_min = float(t["optimal_moisture_min"])
	v.optimal_moisture_max = float(t["optimal_moisture_max"])
	v.stage_colors = LuaConv.to_color_array(t["stage_colors"])
	v.stage_scales = LuaConv.to_float_array(t["stage_scales"])
	return v
