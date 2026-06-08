class_name FarmGroup
extends Node3D

# 一片 FarmField。N 个 FarmSlot marker 作为直接子节点；group 共享 pest 上限以避免
# "6 slot 6 倍虫害"问题。历史类型名保留 FarmGroup，避免重写 UI / AI / queue 引用。
#
# Pest 触发由 town.gd._on_slow_tick 集中调度（每 game-hour 一次）：
#   group.apply_hourly_tick(total_hour)
#   group.try_pest_tick(total_hour)
#
# Slot 不在 FarmGroup 下的话不会受 pest（也作为"试验田 / 装饰"用法的逃生口）。

const WATERING_WATER_COST := 20.0
const WATERING_MOISTURE_DELTA := 0.2
const DEFAULT_MOISTURE_DECAY_PER_HOUR := 0.05

var moisture: float = 0.6:
	set(value):
		var clamped := clampf(value, 0.0, 1.0)
		if is_equal_approx(moisture, clamped):
			return
		moisture = clamped
		_apply_moisture_to_crops()

# 每 game-day 最多触发的 pest 事件数。1 = 玩家每天巡视 1 次足够。
@export var max_pests_per_game_day: int = 1

# 每 game-hour 触发 pest 的概率（组级，不读 variety.pest_chance_per_hour）。
# 0.04 配 max=1 → 平均 25 game-h 内必触发一次 → 1 game-day 命中 ~63%。
@export var pest_chance_per_hour: float = 0.04

# Slot 小球只用于摆放/调试，默认不进入正常游玩画面。
# 如果想调试某片田的 slot，把这里设 true。
@export var show_slot_debug_markers := false:
	set(value):
		show_slot_debug_markers = value
		_apply_slot_debug_visibility()

var _pest_count_today: int = 0
var _last_processed_day: int = -1


func _ready() -> void:
	add_to_group("farm_groups")
	add_to_group("farm_fields")
	_ensure_moisture_sync()
	_apply_slot_debug_visibility()
	# Hydrate from farm_states：覆盖 moisture / pestCountToday / lastProcessedDay。
	# DB 没行（首次 boot）→ 保留 inspector 默认值（moisture=0.6 等）。
	if RunMode.is_runtime():
		var st := Db.take_farm_state(effective_farm_id())
		if not st.is_empty():
			moisture = float(st.get("moisture", moisture))
			_pest_count_today = int(st.get("pestCountToday", 0))
			_last_processed_day = int(st.get("lastProcessedDay", -1))
	_apply_moisture_to_crops()
	call_deferred("_warn_duplicate_farm_ids")


func _persist_to_db() -> void:
	if not RunMode.is_runtime():
		return
	Db.save_farm_state(effective_farm_id(), moisture, _pest_count_today, _last_processed_day)


func effective_farm_id() -> String:
	var identity := WorldObjectIdentity.for_node(self)
	if identity == null:
		push_error("[FarmGroup] %s 缺 WorldObjectIdentity" % get_path())
		return ""
	var id := identity.effective_object_id()
	if id.is_empty():
		push_error("[FarmGroup] %s 的 WorldObjectIdentity.object_id 未填" % get_path())
	return id


# FarmGroup 既是田又是 logical location；location id 永远等同 farm id（@export
# location_id 已删，下游 town_world / farm_states LEFT JOIN 都用同一个字符串）。
# 保留薄 alias 是因为 town_world.gd 等调用方语义上"取田的 location id"更直观。
func effective_location_id() -> String:
	return effective_farm_id()


func effective_display_name() -> String:
	var id := effective_location_id()
	var world := get_tree().get_first_node_in_group("town_world") as TownWorld
	if world != null and world.has_method("location_alias"):
		var alias := String(world.location_alias(id)).strip_edges()
		if not alias.is_empty():
			return alias
	return id if not id.is_empty() else effective_farm_id()


func matches_farm_id(value: String) -> bool:
	return effective_farm_id() == value.strip_edges()


# 归属 group。最终值由 TownWorld._register_farms 写进 _owner_group_by_id；这里 getter
# 转一道。注册时 owner_group_literal 必填（"public" 或 group id），不允许默默继承——
# dev 阶段：fallback 容易藏 bug，强制 inspector 显式写。
var owner_group: String:
	get:
		var world := get_tree().get_first_node_in_group("town_world") as TownWorld
		if world == null:
			var identity := WorldObjectIdentity.for_node(self)
			return identity.owner_group if identity != null else ""
		return world.owner_group_for(effective_location_id())
	set(_value): pass


# site 位置/交互组件（子节点 "SiteMarker"，组合模式）。FarmGroup 自身位置 = 可交互基准；
# 寻路到达点由 SiteMarker.approach_position() 给（可选 "Approach" 子节点，没有则回退自身）。
# Dev 阶段不做 fallback：找不到 SiteMarker 直接 push_error + 返回 null，
# 让 farm_action_runner 立刻 _record_completed 失败而不是默默走 farm origin 卡死。
func get_site_marker() -> Node3D:
	var marker := get_node_or_null("SiteMarker") as Node3D
	if marker == null:
		push_error("[FarmGroup %s] 缺 SiteMarker 子节点；plan_farm_work water 将失败。在 town.tscn 里加一个 SiteMarker 组件。" % effective_farm_id())
	return marker


# NPC 寻路到达点（世界坐标）。SiteMarker 组件的可选 Approach 子节点优先，否则自身位置。
func approach_world_position() -> Vector3:
	var m := get_node_or_null("SiteMarker") as SiteMarker
	return m.approach_position() if m != null else global_position


# 该角色能不能在本片田动土（种 / 浇 / 收 / 铲 / 除虫）。语义见 Access.can_be_used_by。
func can_be_used_by(character: Node) -> bool:
	return Access.can_be_used_by(character, owner_group)


func _warn_duplicate_farm_ids() -> void:
	var wanted := effective_farm_id()
	if wanted.is_empty():
		return
	var duplicates := 0
	for n in get_tree().get_nodes_in_group("farm_groups"):
		if n is FarmGroup and (n as FarmGroup).matches_farm_id(wanted):
			duplicates += 1
	if duplicates > 1:
		push_warning("[FarmGroup %s] duplicate farm_id '%s' detected (%d matches)" % [
			name, wanted, duplicates,
		])


# 直接子节点里的 FarmSlot 列表，按摆放顺序。Panel/queue 用这个寻址 slot_index。
func slots() -> Array[FarmSlot]:
	var out: Array[FarmSlot] = []
	for child in get_children():
		if child is FarmSlot:
			out.append(child as FarmSlot)
	return out


func slot_by_index(idx: int) -> FarmSlot:
	var arr := slots()
	if idx < 0 or idx >= arr.size():
		return null
	return arr[idx]


func _apply_slot_debug_visibility() -> void:
	for slot in slots():
		slot.set_field_marker_visible(show_slot_debug_markers)


func _ensure_moisture_sync() -> void:
	if Engine.is_editor_hint() or has_node("MoistureSync"):
		return
	var sync := MultiplayerSynchronizer.new()
	sync.name = "MoistureSync"
	sync.root_path = NodePath("..")
	var config := SceneReplicationConfig.new()
	var path := NodePath(".:moisture")
	config.add_property(path)
	config.property_set_spawn(path, true)
	config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	add_child(sync)


func apply_hourly_tick(_total_hour: int) -> void:
	# 规则（取田里所有 crop 的 max decay → 衰减 moisture）住在 data/mechanics/crops.lua
	# 的 on_farm_moisture_tick；这里只准备 ctx + 给当前值。
	MechanicHost.invoke("crops", "on_farm_moisture_tick", {
		"farm": self,
		"moisture": moisture,
		"decay_per_hour": _effective_moisture_decay_per_hour(),
	})


# 给 Effects.apply_farm_state 用：lua 端通过 affect.farm_state 声明字段更新。
func set_mechanic_field(key: String, value: Variant) -> void:
	match key:
		"moisture":
			moisture = float(value)
		"pest_count_today":
			_pest_count_today = int(value)
		"last_processed_day":
			_last_processed_day = int(value)
		_:
			push_warning("[FarmGroup] unknown mechanic field: %s" % key)


func persist_mechanic_state() -> void:
	_persist_to_db()


func water(delta: float = WATERING_MOISTURE_DELTA) -> Dictionary:
	var before := moisture
	moisture = moisture + delta
	_persist_to_db()
	return {
		"ok": true,
		"before": before,
		"after": moisture,
		"occupied_crops": occupied_crop_count(),
		"too_wet_crops": too_wet_crop_count(),
	}


func occupied_crop_count() -> int:
	return _crops_on_field().size()


func too_wet_crop_count() -> int:
	var count := 0
	for crop in _crops_on_field():
		if _crop_too_wet(crop):
			count += 1
	return count


func contains_crop(crop: Crop) -> bool:
	if crop == null or not is_instance_valid(crop):
		return false
	for slot in slots():
		if crop.global_position.distance_to(slot.global_position) <= FarmSlot.OCCUPIED_RADIUS:
			return true
	return false


func _apply_moisture_to_crops() -> void:
	# 只在 server 推。Client 的 crop.moisture 走 crop.tscn 的
	# SceneReplicationConfig 由 server 端 crop.moisture 直接复制下来，
	# 不再依赖 client 端 FarmGroup 重复回填（避免 spawn / 复制时序竞态）。
	if not RunMode.is_runtime():
		return
	for crop in _crops_on_field():
		crop.sync_farm_moisture(moisture)


func _crops_on_field() -> Array[Crop]:
	var out: Array[Crop] = []
	var seen := {}
	for slot in slots():
		var crop := _crop_on_slot(slot)
		if crop == null:
			continue
		var key := crop.get_instance_id()
		if seen.has(key):
			continue
		seen[key] = true
		out.append(crop)
	return out


func _effective_moisture_decay_per_hour() -> float:
	var decay := 0.0
	for crop in _crops_on_field():
		if crop.variety == null:
			continue
		decay = maxf(decay, crop.variety.moisture_decay_per_hour)
	return decay if decay > 0.0 else DEFAULT_MOISTURE_DECAY_PER_HOUR


# 给 backend agent context 的 dump：每个 slot 的占用 / crop 状态。NPC LLM 看这个决定下哪批工。
func describe_for_context() -> Dictionary:
	var slot_dicts: Array[Dictionary] = []
	var arr := slots()
	var total_slots := arr.size()
	var occupied_slots := 0
	var empty_slots := 0
	var ripe_slots := 0
	var pest_slots := 0
	var dry_slots := 0
	var wet_slots := 0
	var farm_moisture_percent := int(round(moisture * 100.0))
	for i in arr.size():
		var slot := arr[i]
		var crop := _crop_on_slot(slot)
		var entry := {
			"index": i,
			"slot_name": String(slot.name),
			"occupied": crop != null,
		}
		if crop == null:
			empty_slots += 1
			entry["status_tags"] = ["空地", "可种植"]
			entry["status_text"] = "空地，可种植"
			slot_dicts.append(entry)
			continue
		var ripe := _crop_is_ripe(crop)
		var needs_water := _crop_needs_water(crop)
		var too_wet := _crop_too_wet(crop)
		var stage_display := _crop_stage_display(crop)
		var status_tags: Array[String] = []
		if ripe:
			status_tags.append("可收获")
			ripe_slots += 1
		if crop.has_pest:
			status_tags.append("有虫")
			pest_slots += 1
		if needs_water:
			status_tags.append("缺水")
			dry_slots += 1
		if too_wet:
			status_tags.append("过湿")
			wet_slots += 1
		if status_tags.is_empty():
			status_tags.append("正常")
		occupied_slots += 1
		entry["variety"] = crop.variety.id if crop.variety != null else ""
		entry["display_name"] = crop.variety.display_name if crop.variety != null else ""
		entry["stage"] = crop.stage
		entry["stage_display"] = stage_display
		entry["moisture"] = moisture
		entry["moisture_percent"] = farm_moisture_percent
		entry["has_pest"] = crop.has_pest
		entry["maturity"] = crop.maturity_int
		entry["ripe"] = ripe
		entry["needs_water"] = needs_water
		entry["too_wet"] = too_wet
		entry["can_harvest"] = ripe
		entry["needs_pest_control"] = crop.has_pest
		entry["status_tags"] = status_tags
		entry["status_text"] = "%s · %s · 水分%d%% · %s" % [
			entry["display_name"],
			stage_display,
			farm_moisture_percent,
			", ".join(status_tags),
		]
		slot_dicts.append(entry)
	var summary_parts: Array[String] = ["共%d格" % total_slots]
	summary_parts.append("土壤水分%d%%" % farm_moisture_percent)
	if empty_slots > 0:
		summary_parts.append("空地%d格" % empty_slots)
	if ripe_slots > 0:
		summary_parts.append("可收%d格" % ripe_slots)
	if pest_slots > 0:
		summary_parts.append("有虫%d格" % pest_slots)
	if dry_slots > 0:
		summary_parts.append("缺水%d格" % dry_slots)
	if wet_slots > 0:
		summary_parts.append("过湿%d格" % wet_slots)
	if occupied_slots > 0 and ripe_slots == 0 and pest_slots == 0 and dry_slots == 0 and wet_slots == 0:
		summary_parts.append("已种植%d格（状态稳定）" % occupied_slots)
	return {
		"id": effective_farm_id(),
		"location_id": effective_location_id(),
		"moisture": moisture,
		"moisture_percent": farm_moisture_percent,
		"total_slots": total_slots,
		"occupied_slots": occupied_slots,
		"empty_slots": empty_slots,
		"ripe_slots": ripe_slots,
		"pest_slots": pest_slots,
		"dry_slots": dry_slots,
		"wet_slots": wet_slots,
		"status_summary": "，".join(summary_parts),
		"slots": slot_dicts,
	}


func _crop_on_slot(slot: FarmSlot) -> Crop:
	for n in get_tree().get_nodes_in_group("crops"):
		if not n is Crop:
			continue
		var crop := n as Crop
		if crop.global_position.distance_to(slot.global_position) <= FarmSlot.OCCUPIED_RADIUS:
			return crop
	return null


func _crop_is_ripe(crop: Crop) -> bool:
	return crop != null and crop.variety != null and not crop.variety.stages.is_empty() and crop.stage == crop.variety.stages.back()


func _crop_needs_water(crop: Crop) -> bool:
	return crop != null and crop.variety != null and moisture < crop.variety.optimal_moisture_min


func _crop_too_wet(crop: Crop) -> bool:
	return crop != null and crop.variety != null and moisture > crop.variety.optimal_moisture_max


func _crop_stage_display(crop: Crop) -> String:
	if crop == null:
		return ""
	return Varieties.display_stage_name(crop.variety_id, crop.stage)


func try_pest_tick(total_hour: int) -> void:
	# 规则（每日重置、概率、随机选 crop）住在 data/mechanics/crops.lua 的 on_pest_tick；
	# 这里准备物理候选（按 stage 易感 + 距离过滤）+ 把当前计数 / 配置传过去。
	# game_day 在这里由 total_hour 派生：pest 规则按"日"做计数重置，不能直接吃 total_hour。
	MechanicHost.invoke("crops", "on_pest_tick", {
		"farm": self,
		"eligible_crops": _eligible_crops(),
		"pest_count_today": _pest_count_today,
		"max_per_day": max_pests_per_game_day,
		"last_processed_day": _last_processed_day,
		"game_day": GameClock.day_for_hour(total_hour),
		"prob": pest_chance_per_hour,
	})


# 在本 group 的 slot 范围内、stage 进入易感期、尚未中虫的 Crop。
func _eligible_crops() -> Array[Crop]:
	var out: Array[Crop] = []
	var crops := get_tree().get_nodes_in_group("crops")
	for child in get_children():
		if not child is FarmSlot:
			continue
		var slot := child as FarmSlot
		for n in crops:
			if not n is Crop:
				continue
			var c := n as Crop
			if c.has_pest or not c.is_pest_eligible_stage():
				continue
			if c.global_position.distance_to(slot.global_position) <= FarmSlot.OCCUPIED_RADIUS:
				out.append(c)
				break  # 一个 slot 顶多对应一个 crop
	return out
