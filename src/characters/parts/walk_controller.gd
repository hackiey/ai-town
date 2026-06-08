class_name WalkController
extends RefCounted

# Character / NPC / Player 的分层寻路状态机：
# - corridor planning（以 location/waypoint 图为主的分层寻路）
# - direct navmesh walk（玩家点地自由移动）
# - move_to_location 意图解析（→ position / region / 目标 character / 目标 item）
# - stuck recovery（撞墙 / 卡角时换中转点）
# - 进度监测（一段时间无位移 → 触发 recovery）
#
# **物理 tick 仍由 NPC / Player 自己跑**（动画状态机和 nav agent 接得太紧）。本类提供：
# - 数据 getter（corridor / final_arrival_distance / current_waypoint / active_arrival_distance）
# - 状态 mutator（advance_after_arrival / clear_final_distance / mark_progress / reset）
# - 一次性 stuck 检查（tick_stuck_progress）
# 子类 physics tick 用这些组装自己的"到位 → idle / 切下个点"流程。

const _CORRIDOR_PLANNER := preload("res://src/world/location_corridor_planner.gd")

const STUCK_TIMEOUT := 1.5
const STUCK_PROGRESS_MIN := 0.3
const MAX_RECOVERY_TRIES := 4

var character: Character

var _corridor: Array[Vector3] = []
# 原始计划路径快照：plan 时存一份，recovery 期间不动。re-plan 全失败兜底传送时，
# 用这个找"原路径上还没到的下一个 waypoint"作为传送目标。
var _original_corridor: Array[Vector3] = []
var _blacklist: PackedStringArray = PackedStringArray()
var _planner: RefCounted = null
var _final_arrival_distance: float = 0.0
var _stuck_timer: float = 0.0
var _last_progress_pos: Vector3 = Vector3.ZERO

const ORIGINAL_MATCH_TOLERANCE := 0.5


func _init(owner: Character) -> void:
	character = owner
	_last_progress_pos = character.global_position


# ─── 规划 / 恢复 ─────────────────────────────────────

# 规划 corridor 并把首段图节点喂给 nav。返回错误字符串，"" = 成功。
func plan_to_world_position(raw_target: Vector3, final_arrival_distance: float = 0.0) -> String:
	var nav: NavigationAgent3D = character.nav
	if nav == null:
		return "navigation agent not found"
	var map_rid := nav.get_navigation_map()
	if not map_rid.is_valid():
		return "navigation map is not ready"
	var world: TownWorld = character.get_tree().get_first_node_in_group("town_world") as TownWorld
	if world == null:
		return "TownWorld not found"
	var planner = _CORRIDOR_PLANNER.new(world, map_rid)
	var corridor: Array[Vector3] = planner.plan(character.global_position, raw_target)
	if corridor.is_empty():
		var graph := world.location_graph
		if graph == null:
			push_warning("[WalkController] plan empty: location_graph is null (bake never ran or skipped)")
			return "location graph is not ready yet"
		if not graph.baked:
			push_warning("[WalkController] plan empty: location_graph exists but baked=false (bake still in progress or skipped)")
			return "location graph is not ready yet"
		return "target is not reachable (no location graph corridor path): %s" % str(raw_target)
	_corridor = corridor
	_original_corridor = corridor.duplicate()
	_blacklist = PackedStringArray()
	_planner = planner
	_final_arrival_distance = final_arrival_distance
	_stuck_timer = 0.0
	_last_progress_pos = character.global_position
	nav.set_target_position(corridor[0])
	return ""


# Stuck 后调：找一个未试过的、当前位置 NavMesh 可达的最近 recovery 图节点当中转，
# 走过去再重新规划到原 final target。耗尽 MAX_RECOVERY_TRIES 才放弃。
func recover() -> String:
	if _corridor.is_empty():
		return ""
	push_warning("[WalkController] %s stuck at %s (try %d/%d), heading to %s" % [
		String(character.name), str(character.global_position),
		_blacklist.size() + 1, MAX_RECOVERY_TRIES, str(_corridor[0])
	])
	if _planner == null:
		_final_arrival_distance = 0.0
		return "stuck during direct nav move"
	if _blacklist.size() >= MAX_RECOVERY_TRIES:
		# 4 次 corridor 重规划仍找不到绕路 → 兜底：传送到原始计划路径上
		# "还没走到的下一个 waypoint"。原 corridor 是 navmesh 保证可走的，
		# 跳过当前卡死段后，从下个 waypoint 继续按原路径走就能到终点。
		# 用 _original_corridor 而不是 _corridor[0]——后者在 recovery 期间被
		# 改成了绕路 graph 节点，传过去会偏离原路线。
		var teleport_target: Vector3
		if not _original_corridor.is_empty():
			teleport_target = _original_corridor[0]
		else:
			teleport_target = _corridor[_corridor.size() - 1]
		character.global_position = teleport_target
		var restored: Array[Vector3] = []
		if not _original_corridor.is_empty():
			restored.assign(_original_corridor)
		else:
			restored.append(teleport_target)
		_corridor = restored
		_blacklist = PackedStringArray()
		_last_progress_pos = teleport_target
		_stuck_timer = 0.0
		character.nav.set_target_position(_corridor[0])
		push_warning("[WalkController] %s exhausted %d recovery tries, teleported to original waypoint %s" % [
			String(character.name), MAX_RECOVERY_TRIES, str(teleport_target)
		])
		return ""
	var final_target: Vector3 = _corridor[_corridor.size() - 1]
	var recovery: Dictionary = _planner.nearest_reachable_location(character.global_position, _blacklist)
	if recovery.is_empty():
		_final_arrival_distance = 0.0
		return "stuck and no recovery graph node reachable"
	_blacklist.append(String(recovery["id"]))
	var new_corridor: Array[Vector3] = [recovery["pos"]]
	var rest: Array[Vector3] = _planner.plan(recovery["pos"], final_target, _blacklist)
	if rest.is_empty():
		new_corridor.append(final_target)
	else:
		new_corridor.append_array(rest)
	_corridor = new_corridor
	character.nav.set_target_position(_corridor[0])
	_last_progress_pos = character.global_position
	return ""


# NPC 农事队列用：找不到 corridor 时直接朝目标走（不返回错误）。和 plan_to_world_position
# 区别：那个调用是 backend action 严格模式，找不到路就返回错；这里是 queue 接管模式，
# 走不到就靠 stuck timeout / cancel 兜底。
func plan_to_world_position_or_direct(target: Vector3) -> void:
	var nav: NavigationAgent3D = character.nav
	if nav == null:
		return
	var map_rid := nav.get_navigation_map()
	if not map_rid.is_valid():
		return
	var world: TownWorld = character.get_tree().get_first_node_in_group("town_world") as TownWorld
	if world == null:
		return
	var planner = _CORRIDOR_PLANNER.new(world, map_rid)
	var corridor: Array[Vector3] = planner.plan(character.global_position, target)
	if corridor.is_empty():
		nav.set_target_position(target)
		_corridor = [target]
	else:
		_corridor = corridor
		nav.set_target_position(corridor[0])
	_original_corridor = _corridor.duplicate()
	_blacklist = PackedStringArray()
	_planner = planner
	_final_arrival_distance = 0.0
	_stuck_timer = 0.0
	_last_progress_pos = character.global_position


# 玩家点地自由移动：直接把 target snap 到 navmesh，然后沿 navmesh 走，不经过 location graph。
# 只做一次 reachability 校验；若行走中仍卡住，则直接停止，不再切回 graph recovery。
func plan_direct_to_world_position(raw_target: Vector3, final_arrival_distance: float = 0.0) -> String:
	var nav: NavigationAgent3D = character.nav
	if nav == null:
		return "navigation agent not found"
	var map_rid := nav.get_navigation_map()
	if not map_rid.is_valid():
		return "navigation map is not ready"
	var target := NavigationServer3D.map_get_closest_point(map_rid, raw_target)
	if _path_length(character.global_position, target) <= 0.0:
		return "target is not reachable on navmesh: %s" % str(raw_target)
	_corridor = [target]
	_original_corridor = [target]
	_blacklist = PackedStringArray()
	_planner = null
	_final_arrival_distance = final_arrival_distance
	_stuck_timer = 0.0
	_last_progress_pos = character.global_position
	nav.set_target_position(target)
	return ""


func reset() -> void:
	_corridor = []
	_original_corridor = []
	_blacklist = PackedStringArray()
	_planner = null
	_final_arrival_distance = 0.0
	_stuck_timer = 0.0
	_last_progress_pos = character.global_position


func default_arrival_distance() -> float:
	var nav: NavigationAgent3D = character.nav
	return nav.target_desired_distance if nav != null else 0.0


# 当前段使用的 arrival 距离：到最后一段 + 给了 final_arrival_distance 时用 final，否则用默认。
func active_arrival_distance(default: float) -> float:
	if _corridor.size() <= 1 and _final_arrival_distance > 0.0:
		return _final_arrival_distance
	return default


# 走到当前 waypoint 之后调：pop 首项，返回 { finished, next_target }。
# next_target 仅 finished=false 时有效。pop 后 reset 进度跟踪。
func advance_after_arrival() -> Dictionary:
	if not _corridor.is_empty():
		var reached: Vector3 = _corridor[0]
		_corridor.remove_at(0)
		# 真正走到了原路径上的某个 waypoint → 同步 pop 原路径头部，避免
		# 兜底传送时把已经过的 waypoint 当成"还没到"。
		if not _original_corridor.is_empty() and _original_corridor[0].distance_to(reached) < ORIGINAL_MATCH_TOLERANCE:
			_original_corridor.remove_at(0)
	if _corridor.is_empty():
		return {"finished": true}
	mark_progress(character.global_position)
	return {"finished": false, "next_target": _corridor[0]}


func clear_final_distance() -> void:
	_final_arrival_distance = 0.0


# 进度跟踪：每帧 walking 状态下调，累计 STUCK_TIMEOUT 内位移 < STUCK_PROGRESS_MIN
# 视为 stuck，返回 true（同时 reset timer，调用方自己决定要不要 recover）。
func tick_stuck_progress(pos: Vector3, delta: float) -> bool:
	var progress := pos.distance_to(_last_progress_pos)
	if progress >= STUCK_PROGRESS_MIN:
		_last_progress_pos = pos
		_stuck_timer = 0.0
		return false
	_stuck_timer += delta
	if _stuck_timer >= STUCK_TIMEOUT:
		_stuck_timer = 0.0
		return true
	return false


func mark_progress(pos: Vector3) -> void:
	_last_progress_pos = pos
	_stuck_timer = 0.0


func _path_length(from: Vector3, to: Vector3) -> float:
	var nav: NavigationAgent3D = character.nav
	if nav == null:
		return -1.0
	var map_rid := nav.get_navigation_map()
	if not map_rid.is_valid():
		return -1.0
	var src := NavigationServer3D.map_get_closest_point(map_rid, from)
	var dst := NavigationServer3D.map_get_closest_point(map_rid, to)
	var params := NavigationPathQueryParameters3D.new()
	params.map = map_rid
	params.start_position = src
	params.target_position = dst
	params.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(params, result)
	var path := result.path
	if path.is_empty():
		return -1.0
	if path[path.size() - 1].distance_to(dst) > 1.0:
		return -1.0
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


# 数据 getter（NPC / Player physics 读）
func corridor() -> Array[Vector3]:
	return _corridor


func final_arrival_distance() -> float:
	return _final_arrival_distance


func has_corridor() -> bool:
	return not _corridor.is_empty()


func current_waypoint() -> Vector3:
	return _corridor[0] if not _corridor.is_empty() else character.global_position


# ─── move_to_location 意图解析 ────────────────────────

# 返回：{ok, action_id, position?, arrival_distance?, region_id?, done?, error?}
func resolve_move_to_location_request(action_request: Dictionary) -> Dictionary:
	# Wire contract: move_to_location target is exactly one of locationId / characterId / itemId / regionId.
	# See backend/src/godot-link/actions.ts MoveToLocationTarget.
	#
	# 动态静态一套逻辑：人物 / 地面物品在 runtime 注册成动态 site（characterId→"character:<id>"、
	# itemId→"ground_item:<模板>"），与静态地点完全同一套解析——has_position + get_nearest_position_world，
	# 不再有"按 group 扫节点"的第二条路径。
	var target: Variant = action_request.get("target")
	var action_id := str(action_request.get("id", ""))
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "error": "move_to_location target must be object"}
	var target_dict: Dictionary = target as Dictionary
	var world: TownWorld = character.get_tree().get_first_node_in_group("town_world") as TownWorld
	if world == null:
		return {"ok": false, "error": "TownWorld not found"}

	# 动态实体目标（人物 / 地面物品）：合成动态 site_id，走统一 registry。
	var target_character_id := str(target_dict.get("characterId", "")).strip_edges()
	if not target_character_id.is_empty():
		return _resolve_dynamic_site_move(world, TownWorld.character_site_id(target_character_id),
			action_id, "character %s" % target_character_id)
	var target_item_id := str(target_dict.get("itemId", "")).strip_edges()
	if not target_item_id.is_empty():
		return _resolve_dynamic_site_move(world, TownWorld.ground_item_site_id(target_item_id),
			action_id, "item %s" % target_item_id)

	# 静态地点 / region。
	var location_id := str(target_dict.get("locationId", target_dict.get("regionId", ""))).strip_edges()
	if location_id.is_empty():
		return {"ok": false, "error": "move_to_location target is empty"}
	if location_id in ["current_location", "current location", "当前位置"]:
		return {"ok": true, "action_id": action_id, "done": true}
	var resolved_location := world.resolve_location_id(location_id) if world.has_method("resolve_location_id") else location_id
	if world.has_position(resolved_location):
		# 寻路目标点（approach_position）与到达阈值（arrival_radius）取自同一个最近锚点，
		# 保证「走去的点」和「到达圈」来自同一 SiteMarker，多锚点站点不会错配。
		var marker := world.nearest_nav_anchor(resolved_location, character.global_position)
		if marker == null:
			return {"ok": false, "error": "no anchor for location: %s" % resolved_location}
		return {
			"ok": true,
			"action_id": action_id,
			"position": marker.approach_position(),
			"arrival_distance": marker.eff_arrival_radius(),
		}
	if world.has_region(resolved_location):
		return {"ok": true, "action_id": action_id, "region_id": resolved_location}
	return {"ok": false, "error": "unknown location: %s" % location_id}


# 给 region 目标试候选点：按距离排序，第一个走得通的胜出。start_walk 是 NPC/Player 的
# Callable(action_id, target_pos) → 错误字符串。
func start_walk_to_region_common(region_id: String, action_id: String, start_walk: Callable) -> String:
	var world: TownWorld = character.get_tree().get_first_node_in_group("town_world") as TownWorld
	if world == null:
		return "TownWorld not found"
	if not world.has_region(region_id):
		return "unknown region: %s" % region_id
	var candidates: Array[Vector3] = world.region_candidate_points_world(region_id)
	if candidates.is_empty():
		return "region has no candidate points: %s" % region_id
	var origin: Vector3 = character.global_position
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return origin.distance_squared_to(a) < origin.distance_squared_to(b)
	)
	var last_error := ""
	for target_position in candidates:
		last_error = str(start_walk.call(action_id, target_position))
		if last_error.is_empty():
			return ""
	return last_error


# move_to_location 字段抽取 helper 已删除 —— wire contract 锁定 characterId / itemId /
# locationId / regionId，resolve_move_to_location_request 直接读 dict key。


# ─── private ────────────────────────────────────────

# 动态 site（人物 / 地面物品）move 解析：取离自己最近的锚点 SiteMarker，按它自己的可见半径
# 做 move-range 守卫（已在 near 内 = 无需移动；超出 far = 看不见）。半径单一来源 = 该实体的
# SiteMarker（不再读散落的 CharacterPerception.*_RADIUS 常量），位置走与静态地点同一个
# approach_position。site_id 未注册（实体已 despawn / 不存在）= unknown target。
func _resolve_dynamic_site_move(world: TownWorld, site_id: String, action_id: String, label: String) -> Dictionary:
	var marker := world.nearest_anchor_marker(site_id, character.global_position)
	if marker == null:
		return {"ok": false, "error": "unknown move target: %s" % label}
	var distance := character.global_position.distance_to(marker.global_position)
	if distance <= marker.eff_visible_near_radius():
		return {"ok": false, "error": "%s is already within near range" % label}
	if distance > marker.eff_visible_far_radius():
		return {"ok": false, "error": "%s is outside far range" % label}
	return {
		"ok": true,
		"action_id": action_id,
		"position": marker.approach_position(),
		"arrival_distance": marker.eff_arrival_radius(),
	}
