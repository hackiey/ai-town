class_name LocationGraph
extends RefCounted

# Location/waypoint 路网图。Bake 一次后，运行时 plan() = 图 A* + 极少 sync query。
#
# 设计：
# - 图节点 = logical location + nav-only waypoint（Waypoints 容器下的 Marker3D）。
# - 边 = 邻近图节点之间 navmesh 可达。
# - plan(start, target):
#     1. 找离 start 最近且可达的入口图节点
#     2. 找离 target 最近的出口图节点
#     3. AStar3D 找图节点路径，末段再尽量靠近目标的 nav 点
#
# 注意：图是 navmesh bake 时刻的快照。引入动态 navmesh（关门/拆墙）需重 bake。

const REACH_TOLERANCE := 1.0
# 只考虑局部邻域内的候选边。图节点的控制力来自"图够稀疏"；
# 如果把 50~60m 内所有可达点都连上，A* 会频繁跳过中间节点。
const EDGE_MAX_DIST := 40.0
# 每处理这么多源图节点 yield 一帧，避免长时间冻帧。
const YIELD_EVERY := 4
# 每个图节点最多保留这么多局部邻居边。路口通常 3~4 条边就够了。
const MAX_NEIGHBOR_EDGES := 4
# 每个图节点最多探测这么多近邻候选，避免为了补满局部边把图又变稠密。
const MAX_NEIGHBOR_PROBES := 8
# 运行时入口选点只优先 probe 最近这么多图节点。大多数情况下前几个近邻就够，
# 没必要每次移动都把整张图逐个做一次 query_path。
const MAX_ENTRY_REACH_PROBES := 8
# 入口候选最多保留这么多可达点给后续 A* 尝试；图很小，3 个候选足够覆盖常见岔路。
const MAX_ENTRY_REACHABLE_CANDIDATES := 3
# 若局部邻居图被裁断成多个连通分量，再做一轮跨分量补桥。
# 只尝试较近的跨分量对，避免退化回“到处乱连”的稠密图。
const BRIDGE_MAX_DIST := 80.0
var baked: bool = false

var _world: TownWorld
var _map_rid: RID
# 子类化 AStar3D 重载 _compute_cost：用 bake 时算出的真实 navmesh 路径长度作边权，
# 而不是默认的端点欧氏距离。否则 A* 偏好"几何短但实际绕远"的边。
var _astar := _LocationAStar.new()
var _node_id_by_idx: PackedStringArray = PackedStringArray()
var _node_pos_by_idx: PackedVector3Array = PackedVector3Array()
var _component_by_idx: PackedInt32Array = PackedInt32Array()


class _LocationAStar:
	extends AStar3D
	# (a,b) -> 真实 navmesh 路径长度，a < b。不在表里的边退化到端点欧氏距离。
	var edge_cost: Dictionary = {}

	func _compute_cost(from_id: int, to_id: int) -> float:
		var key: int = (from_id if from_id < to_id else to_id) * 1000000 + (to_id if from_id < to_id else from_id)
		if edge_cost.has(key):
			return edge_cost[key]
		return get_point_position(from_id).distance_to(get_point_position(to_id))

	func _estimate_cost(from_id: int, to_id: int) -> float:
		# 启发：欧氏距离。Admissible（真实路径 ≥ 欧氏），保证 A* 最优。
		return get_point_position(from_id).distance_to(get_point_position(to_id))

	func set_edge_cost(a: int, b: int, cost: float) -> void:
		var lo: int = a if a < b else b
		var hi: int = b if a < b else a
		edge_cost[lo * 1000000 + hi] = cost


func _init(world: TownWorld, map_rid: RID) -> void:
	_world = world
	_map_rid = map_rid


# 异步 bake：调用方 await 之即可。
func bake() -> void:
	if not _map_rid.is_valid():
		push_warning("[LocationGraph] map_rid invalid; skipping bake")
		return
	if not _map_ready():
		push_warning("[LocationGraph] nav map not ready; skipping bake")
		return
	NavigationServer3D.map_force_update(_map_rid)
	_astar.clear()
	_node_id_by_idx = PackedStringArray()
	_node_pos_by_idx = PackedVector3Array()

	var idx := 0
	for id in _world.navigation_node_ids():
		for raw_pos in _world.all_anchor_positions(id):
			# Snap 到 polygon：手摆锚点略偏 navmesh 时防止 bake/runtime 行为不一致。
			var snapped: Vector3 = NavigationServer3D.map_get_closest_point(_map_rid, raw_pos)
			_astar.add_point(idx, snapped)
			_node_id_by_idx.append(id)
			_node_pos_by_idx.append(snapped)
			idx += 1

	var n := _node_pos_by_idx.size()
	var tree := Engine.get_main_loop() as SceneTree
	for i in n:
		var pi: Vector3 = _node_pos_by_idx[i]
		var candidates: Array = []
		for j in n:
			if i == j:
				continue
			var pj: Vector3 = _node_pos_by_idx[j]
			var dist := pi.distance_to(pj)
			if dist > EDGE_MAX_DIST:
				continue
			candidates.append({"j": j, "d": dist})
		candidates.sort_custom(func(a, b): return a["d"] < b["d"])

		var connected := 0
		var cand_lim := mini(candidates.size(), MAX_NEIGHBOR_PROBES)
		for k in cand_lim:
			var j: int = candidates[k]["j"]
			if _astar.are_points_connected(i, j):
				continue
			var pj: Vector3 = _node_pos_by_idx[j]
			var path_len := _path_length(pi, pj)
			if path_len > 0.0:
				_astar.connect_points(i, j)
				_astar.set_edge_cost(i, j, path_len)
				connected += 1
				if connected >= MAX_NEIGHBOR_EDGES:
					break
		if tree != null and (i + 1) % YIELD_EVERY == 0:
			await tree.process_frame

	_rebuild_components()
	_bridge_components()
	_rebuild_components()
	baked = true


# start → target 的图节点序列，末尾是 target_world。空数组 = 无路。
# blacklist 按图节点 id 过滤；图节点的 id 命中就跳过。
func plan(start: Vector3, target_world: Vector3, blacklist: PackedStringArray = PackedStringArray()) -> Array[Vector3]:
	if not baked or not _map_ready():
		return [] as Array[Vector3]
	if _node_pos_by_idx.is_empty():
		return [] as Array[Vector3]

	var target_nav: Vector3 = _snap_to_nav(target_world)
	var blacklist_set: Dictionary = {}
	for s in blacklist:
		blacklist_set[str(s)] = true

	var entry_candidates := _collect_reachable_endpoint_nodes(start, blacklist_set, true)
	if entry_candidates.is_empty():
		return [] as Array[Vector3]

	var path_idx := PackedInt64Array()
	for candidate in entry_candidates:
		var entry: int = int(candidate["i"])
		var entry_component := _component_at(entry)
		var exit := _pick_nearest_graph_node(target_nav, blacklist_set, entry_component)
		if exit < 0:
			continue
		path_idx = _astar.get_id_path(entry, exit)
		if not path_idx.is_empty():
			break
	if path_idx.is_empty():
		return [] as Array[Vector3]
	var corridor: Array[Vector3] = []
	for i in path_idx:
		if blacklist_set.has(_node_id_by_idx[i]):
			return [] as Array[Vector3]
		corridor.append(_astar.get_point_position(i))
	var tail: Vector3 = corridor[corridor.size() - 1]
	if tail.distance_to(target_nav) > REACH_TOLERANCE and _reachable(tail, target_nav):
		corridor.append(target_nav)
	return corridor


# Stuck recovery：当前位置可达的、不在 exclude 里的最近图节点。
func nearest_reachable(from: Vector3, exclude: PackedStringArray = PackedStringArray()) -> Dictionary:
	if not baked or not _map_ready():
		return {}
	var excluded: Dictionary = {}
	for s in exclude:
		excluded[str(s)] = true
	var order: Array = []
	for i in _node_pos_by_idx.size():
		if excluded.has(_node_id_by_idx[i]):
			continue
		order.append({"i": i, "d": from.distance_squared_to(_node_pos_by_idx[i])})
	order.sort_custom(func(a, b): return a["d"] < b["d"])
	for k in order.size():
		var i: int = order[k]["i"]
		var node_pos: Vector3 = _node_pos_by_idx[i]
		var path_len := _path_length(from, node_pos)
		if path_len > 0.0:
			return {"id": _node_id_by_idx[i], "pos": node_pos}
	return {}


func node_count() -> int:
	return _node_pos_by_idx.size()


# ---- internals ----

# Probe 顺序：按纯欧氏距离从近到远试，直到命中第一个可达图节点。
# 先 probe 最近的一小撮近邻；只有这些全失败时才继续往后扫兜底，避免每次 plan 都
# 对整张图做 query_path。
func _collect_reachable_endpoint_nodes(pos: Vector3, blacklist_set: Dictionary, from_pos_to_node: bool) -> Array:
	var by_dist: Array = []
	for i in _node_pos_by_idx.size():
		if blacklist_set.has(_node_id_by_idx[i]):
			continue
		var np: Vector3 = _node_pos_by_idx[i]
		var d: float = pos.distance_to(np)
		by_dist.append({"i": i, "k": d})
	by_dist.sort_custom(func(a, b): return a["k"] < b["k"])

	var reachable: Array = []
	var probe_limit := mini(by_dist.size(), MAX_ENTRY_REACH_PROBES)
	for k in probe_limit:
		var i: int = by_dist[k]["i"]
		var node_pos: Vector3 = _node_pos_by_idx[i]
		var path_len := (
			_path_length(pos, node_pos) if from_pos_to_node
			else _path_length(node_pos, pos)
		)
		if path_len <= 0.0:
			continue
		reachable.append({"i": i})
		if reachable.size() >= MAX_ENTRY_REACHABLE_CANDIDATES:
			return reachable
	if not reachable.is_empty():
		return reachable

	for k in range(probe_limit, by_dist.size()):
		var i: int = by_dist[k]["i"]
		var node_pos: Vector3 = _node_pos_by_idx[i]
		var path_len := (
			_path_length(pos, node_pos) if from_pos_to_node
			else _path_length(node_pos, pos)
		)
		if path_len <= 0.0:
			continue
		reachable.append({"i": i})
		if reachable.size() >= MAX_ENTRY_REACHABLE_CANDIDATES:
			break
	return reachable


# 终点侧只取"最近图节点"本身；是否能从这个节点再靠近目标，留给 corridor
# 末段自己决定。这样不会因为目标锚点偏到建筑里就整条返空。
func _pick_nearest_graph_node(pos: Vector3, blacklist_set: Dictionary, required_component: int = -1) -> int:
	var by_dist: Array = []
	for i in _node_pos_by_idx.size():
		if blacklist_set.has(_node_id_by_idx[i]):
			continue
		if required_component >= 0 and _component_at(i) != required_component:
			continue
		by_dist.append({"i": i, "k": pos.distance_to(_node_pos_by_idx[i])})
	by_dist.sort_custom(func(a, b): return a["k"] < b["k"])
	if by_dist.is_empty():
		return -1
	return int(by_dist[0]["i"])


func _map_ready() -> bool:
	return NavigationServer3D.map_get_iteration_id(_map_rid) > 0


func _snap_to_nav(pos: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(_map_rid, pos)


func _component_at(i: int) -> int:
	if i < 0 or i >= _component_by_idx.size():
		return -1
	return _component_by_idx[i]


func _reachable(from: Vector3, to: Vector3) -> bool:
	return _path_length(from, to) > 0.0


# 返回 navmesh 上 from→to 的实际路径总长（米）。-1 = 不可达。
# Bake 期间用它同时做可达性 + 边权计算（一次 query_path 拿两个结果）。
func _path_length(from: Vector3, to: Vector3) -> float:
	var src := NavigationServer3D.map_get_closest_point(_map_rid, from)
	var dst := NavigationServer3D.map_get_closest_point(_map_rid, to)
	var params := NavigationPathQueryParameters3D.new()
	params.map = _map_rid
	params.start_position = src
	params.target_position = dst
	params.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(params, result)
	var path := result.path
	if path.is_empty():
		return -1.0
	if path[path.size() - 1].distance_to(dst) > REACH_TOLERANCE:
		return -1.0
	var total := 0.0
	for k in range(1, path.size()):
		total += path[k - 1].distance_to(path[k])
	return total


func _rebuild_components() -> int:
	_component_by_idx = PackedInt32Array()
	_component_by_idx.resize(_node_pos_by_idx.size())
	for i in _component_by_idx.size():
		_component_by_idx[i] = -1
	var component := 0
	for i in _node_pos_by_idx.size():
		if _component_by_idx[i] >= 0:
			continue
		var stack: Array[int] = [i]
		_component_by_idx[i] = component
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			for next in _astar.get_point_connections(cur):
				var j := int(next)
				if _component_by_idx[j] >= 0:
					continue
				_component_by_idx[j] = component
				stack.append(j)
		component += 1
	return component


func _bridge_components() -> Dictionary:
	var components := _rebuild_components()
	if components <= 1:
		return {"added": 0, "probes": 0}
	var candidates: Array = []
	for i in _node_pos_by_idx.size():
		for j in range(i + 1, _node_pos_by_idx.size()):
			if _component_at(i) == _component_at(j):
				continue
			var d := _node_pos_by_idx[i].distance_to(_node_pos_by_idx[j])
			if d > BRIDGE_MAX_DIST:
				continue
			candidates.append({"a": i, "b": j, "d": d})
	candidates.sort_custom(func(a, b): return a["d"] < b["d"])
	var added := 0
	var probes := 0
	for candidate in candidates:
		var a := int(candidate["a"])
		var b := int(candidate["b"])
		if _component_at(a) == _component_at(b):
			continue
		probes += 1
		var path_len := _path_length(_node_pos_by_idx[a], _node_pos_by_idx[b])
		if path_len <= 0.0:
			continue
		_astar.connect_points(a, b)
		_astar.set_edge_cost(a, b, path_len)
		added += 1
		var components_left := _rebuild_components()
		if components_left <= 1:
			break
	return {"added": added, "probes": probes}
