class_name Crop
extends Node3D

# 一株作物。Phase 2.5 模型：
# - **时间轴**（决定 stage 显示 + 收获窗口）：spawned_at_game_hour 起 maturation_hours
#   内 stage 自动按 time_progress 推进。到 ripe 阶段就能收，无论照料如何。
# - **评分轴**（决定 quality / yield）：每 game-hour 给一个 0/0.5/1 的"小时分"，
#   累加到 care_score_sum / care_score_count。harvest 时 maturity = sum/count → quality。
# - **水分轴**：水分真值住在 FarmGroup；server 端 FarmGroup setter 把 farm.moisture
#   推到自家所有 crop.moisture，crop.moisture 再走 SceneReplicationConfig 直接复制到
#   client。Client 端的 FarmGroup setter 不再做 crop 回填（避免 spawn / 复制时序竞态）。
#
# Multi-harvest：harvest 后 spawned_at_game_hour 回退到 harvest_returns_to_stage 对应的
# 时间点；评分清零重新累。max_harvests 到了 queue_free。
#
# 同步形态：CropSpawner 在 server 端 spawn → SceneReplicationConfig 推 stage / has_pest /
# maturity_int / moisture 给 client 渲染。care_score_sum/count、harvests_done 仅 server。

const PLACEHOLDER_HEIGHT := 1.2
const PLACEHOLDER_RADIUS := 0.25

# 距离 ≤ 该值 → 头顶状态气泡显示
const LABEL_VISIBLE_RANGE := 5.0
# Quality bin (int 1-100) → 等级名（用于 UI / label / tooltip）
const QUALITY_BAD_MAX := 39
const QUALITY_NORMAL_MAX := 69
const QUALITY_GOOD_MAX := 89

# 在 spawn data 里赋值；同步给 client 后两端都能由 variety_id 反查 CropVariety。
var variety_id: String = ""
var stage: String = "":
	set(value):
		if stage == value:
			return
		stage = value
		_apply_visual()

var moisture: float = 1.0:
	set(value):
		var clamped := clampf(value, 0.0, 1.0)
		if is_equal_approx(moisture, clamped):
			return
		moisture = clamped
		_apply_visual()

var has_pest: bool = false:
	set(value):
		if has_pest == value:
			return
		has_pest = value
		_apply_visual()

# 当前累计的 maturity，1-100 整数。同步给 client 用于头顶品质显示。
var maturity_int: int = 100:
	set(value):
		var clamped := clampi(value, 1, 100)
		if maturity_int == clamped:
			return
		maturity_int = clamped
		_apply_visual()

# 仅 server：评分累加 + 时间锚 + 收获次数
var spawned_at_game_hour: int = -1
var care_score_sum: float = 0.0
var care_score_count: int = 0
var harvests_done: int = 0

var variety: CropVariety = null
var _mesh: MeshInstance3D = null
var _material: StandardMaterial3D = null
var _cached_farm: FarmGroup = null


# town.gd._init_runtime 给 CropSpawner.spawn_function 赋值 → 这里。两端都跑。
static func from_spawn_data(data: Variant) -> Node:
	var d: Dictionary = data as Dictionary
	var crop := preload("res://src/sim/crops/crop.tscn").instantiate() as Crop
	crop.variety_id = str(d.get("variety_id", ""))
	crop.position = d.get("pos", Vector3.ZERO)
	return crop


# Server-only 工厂：通过 spawner 生成 → 自动同步到所有 client。
static func spawn(spawner: MultiplayerSpawner, variety_id: String, world_pos: Vector3) -> Crop:
	assert(RunMode.is_runtime(), "Crop.spawn must run on the runtime server")
	if not Varieties.has_id(variety_id):
		push_warning("[Crop] unknown variety: %s" % variety_id)
		return null
	return spawner.spawn({
		"variety_id": variety_id,
		"pos": world_pos,
	}) as Crop


func _ready() -> void:
	variety = Varieties.by_id(variety_id)
	if variety == null:
		push_warning("[Crop] _ready: unknown variety_id %s" % variety_id)
		return
	_build_visual()
	add_to_group("crops")
	if RunMode.is_runtime() and stage.is_empty():
		spawned_at_game_hour = GameClock.total_game_hours()
		moisture = _current_farm_moisture()
		has_pest = false
		maturity_int = 100
		stage = Varieties.compute_stage(variety_id, spawned_at_game_hour, spawned_at_game_hour)
		# 新 spawn → 写一行 farm_plots。hydrate 路径走的是 apply_persisted_state()
		# （TownWorld 启动时调），那条路径会先建 crop 节点再覆盖字段，这里仍触发
		# 一次写也无妨（覆盖到的就是同样的初值）。
		persist_to_db()
	_apply_visual()


# Hydrate path：TownWorld 启动 spawn 完作物后调，把 db 里的 spawnedAt/care/harvests/pest
# 覆盖到本节点。stage 由 _recompute_stage 重新推算（按当前 game_hour - spawnedAt）。
# spawn() 触发 _ready 时已经写过一行默认值；这里 overwrite 后再 persist_to_db 一次
# 把正确值写回去（同 row 覆盖更新，幂等）。
func apply_persisted_state(fields: Dictionary) -> void:
	spawned_at_game_hour = int(fields.get("spawnedAtGameHour", spawned_at_game_hour))
	care_score_sum = float(fields.get("careScoreSum", 0.0))
	care_score_count = int(fields.get("careScoreCount", 0))
	harvests_done = int(fields.get("harvestsDone", 0))
	has_pest = bool(fields.get("hasPest", false))
	maturity_int = Varieties.compute_maturity(care_score_sum, care_score_count)
	stage = Varieties.compute_stage(variety_id, spawned_at_game_hour, GameClock.total_game_hours())
	persist_to_db()


# 把当前作物状态 UPSERT 到 farm_plots。stage 不写（由 spawnedAt 推导）。
func persist_to_db() -> void:
	if not RunMode.is_runtime():
		return
	var farm := owning_farm()
	if farm == null:
		return
	var idx := _slot_index_in_farm(farm)
	if idx < 0:
		return
	Db.save_farm_plot(farm.effective_farm_id(), idx, {
		"varietyId": variety_id,
		"spawnedAtGameHour": spawned_at_game_hour,
		"stage": stage,
		"careScoreSum": care_score_sum,
		"careScoreCount": care_score_count,
		"harvestsDone": harvests_done,
		"hasPest": has_pest,
	})


# 删除 farm_plots 该 plot 的行（harvest 单收 / max harvest 到 / uproot）。
# 调用必须在 queue_free 之前——节点销毁后 owning_farm 取不到。
func clear_from_db() -> void:
	if not RunMode.is_runtime():
		return
	var farm := owning_farm()
	if farm == null:
		return
	var idx := _slot_index_in_farm(farm)
	if idx < 0:
		return
	Db.clear_farm_plot(farm.effective_farm_id(), idx)


# 用 OCCUPIED_RADIUS 找本作物对应的 slot index（FarmGroup.slots() 顺序稳定）。
func _slot_index_in_farm(farm: FarmGroup) -> int:
	var slots := farm.slots()
	for i in slots.size():
		var slot := slots[i]
		if global_position.distance_to(slot.global_position) <= FarmSlot.OCCUPIED_RADIUS:
			return i
	return -1


func _build_visual() -> void:
	_mesh = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = PLACEHOLDER_RADIUS
	capsule.height = PLACEHOLDER_HEIGHT
	_mesh.mesh = capsule
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mesh.material_override = _material
	_mesh.position.y = PLACEHOLDER_HEIGHT * 0.5
	add_child(_mesh)


func _apply_visual() -> void:
	if variety == null or _mesh == null:
		return
	var idx := variety.stages.find(stage)
	if idx < 0:
		return
	var color := variety.stage_colors[idx] if idx < variety.stage_colors.size() else Color.WHITE
	var scale_factor := variety.stage_scales[idx] if idx < variety.stage_scales.size() else 1.0
	_material.albedo_color = color
	_mesh.scale = Vector3.ONE * scale_factor


func field_status_text() -> String:
	if variety == null or variety.stages.find(stage) < 0:
		return ""
	var stage_cn := Varieties.display_stage_name(variety_id, stage)
	var moisture_pct := int(round(moisture * 100.0))
	var pest_mark := " · 有虫" if has_pest else ""
	var quality := _quality_text(maturity_int)
	return "%s · %s\n水分 %d%%%s · 品质 %s" % [variety.display_name, stage_cn, moisture_pct, pest_mark, quality]


func field_status_anchor() -> Vector3:
	return global_position + Vector3(0.0, 1.45, 0.0)


func _quality_text(q: int) -> String:
	if q <= QUALITY_BAD_MAX:
		return "差%d" % q
	if q <= QUALITY_NORMAL_MAX:
		return "中%d" % q
	if q <= QUALITY_GOOD_MAX:
		return "良%d" % q
	return "优%d" % q


# Server 调，每 game-hour 一次。规则（care 累加、stage 推进、maturity 计算）住在
# data/mechanics/crops.lua 的 on_crop_tick；这里只准备 ctx + 同步 moisture 显示缓存。
# total_hour 是自开服累计 game-hour（GameClock signal 唯一真值，单调递增），不是
# hour-of-day。命名约定见 GameClock 头注。
func apply_hourly_tick(total_hour: int) -> void:
	if variety == null:
		return
	assert(total_hour >= spawned_at_game_hour,
		"crop tick total_hour=%d < spawned_at=%d" % [total_hour, spawned_at_game_hour])
	# moisture 真值在 farm，crop 上只是 display cache
	var field_moisture := _current_farm_moisture()
	moisture = field_moisture
	MechanicHost.invoke("crops", "on_crop_tick", {
		"crop": self,
		"variety_id": variety_id,
		"spawned_at_total_hour": spawned_at_game_hour,
		"care_sum": care_score_sum,
		"care_count": care_score_count,
		"moisture": field_moisture,
		"has_pest": has_pest,
		"current_total_hour": total_hour,
	})


# Public：FarmGroup 用来过滤候选。规则在 lua（pest_eligible_stage query）。
func is_pest_eligible_stage() -> bool:
	if variety == null:
		return false
	return Varieties.pest_eligible_stage(variety_id, stage)


# 兼容入口：现在浇水是整片田级别，直接委托给 owning farm。
func water() -> Dictionary:
	assert(RunMode.is_runtime())
	var farm := owning_farm()
	if farm == null:
		return {"ok": false}
	return farm.water()


# Server 调：除虫。
func remove_pest() -> bool:
	assert(RunMode.is_runtime())
	if variety == null or not has_pest:
		return false
	has_pest = false
	persist_to_db()
	return true


# Server 调。规则（产量公式、multi-harvest 重置、单收销毁）住在 data/mechanics/crops.lua
# 的 on_harvest；这里只准备 ctx + 从 raw_effects 读 give_item 的 yield 信息回报上层。
# 返回 { yields, item_id, quantity, quality, granted, leftover }；不能 harvest 时空 id。
func harvest(harvester: Character) -> Dictionary:
	assert(RunMode.is_runtime())
	if variety == null or stage != variety.stages.back():
		return {"item_id": "", "quantity": 0, "quality": 0}
	var result := MechanicHost.invoke("crops", "on_harvest", {
		"crop": self,
		"harvester": harvester,
		"variety_id": variety_id,
		"maturity_int": maturity_int,
		"harvests_done": harvests_done,
		"current_total_hour": GameClock.total_game_hours(),
	})
	if not bool(result.get("ok", false)):
		return {"item_id": "", "quantity": 0, "quality": 0}
	var yields: Array[Dictionary] = []
	for eff in result.get("raw_effects", []):
		if typeof(eff) == TYPE_DICTIONARY and eff.get("type", "") == "give_item":
			yields.append({
				"item_id": str(eff.get("item_id", "")),
				"quantity": int(eff.get("quantity", 0)),
				"quality": int(eff.get("quality", 0)),
				"granted": int(eff.get("_granted", 0)),
				"leftover": int(eff.get("_leftover", 0)),
			})
	if not yields.is_empty():
		var first: Dictionary = yields[0]
		var total_leftover := 0
		for y in yields:
			total_leftover += int(y.get("leftover", 0))
		return {
			"yields": yields,
			"item_id": str(first.get("item_id", "")),
			"quantity": int(first.get("quantity", 0)),
			"quality": int(first.get("quality", 0)),
			"granted": int(first.get("granted", 0)),
			"leftover": total_leftover,
		}
	return {"item_id": "", "quantity": 0, "quality": 0}


func sync_farm_moisture(value: float) -> void:
	moisture = value


func owning_farm() -> FarmGroup:
	if _cached_farm != null and is_instance_valid(_cached_farm):
		return _cached_farm
	for n in get_tree().get_nodes_in_group("farm_groups"):
		if not n is FarmGroup:
			continue
		var farm := n as FarmGroup
		if farm.contains_crop(self):
			_cached_farm = farm
			return farm
	return null


func _current_farm_moisture() -> float:
	var farm := owning_farm()
	if farm != null:
		return farm.moisture
	return moisture
