class_name LocationCorridorPlanner
extends RefCounted

# Null-safe shim around TownWorld.location_graph。正常 move 不再在 graph 缺席时偷偷
# 退化成 direct-walk；调用方若要兜底直走，应显式在上层做（如 plan_to_world_position_or_direct）。
# 保留这层是因为 npc.gd / player.gd 把它当成可空 state 持有（_walk_planner = null
# 表示"当前未规划"），直接用 world.location_graph 不方便表达这个状态。

var _world: TownWorld


func _init(world: TownWorld, _map_rid: RID) -> void:
	# _map_rid 历史参数，现在 LocationGraph 自己持有；保留签名兼容 caller。
	_world = world


func plan(start: Vector3, target_world: Vector3, blacklist: PackedStringArray = PackedStringArray()) -> Array[Vector3]:
	var graph := _graph()
	if graph == null:
		return [] as Array[Vector3]
	return graph.plan(start, target_world, blacklist)


func nearest_reachable_location(from: Vector3, exclude: PackedStringArray = PackedStringArray()) -> Dictionary:
	# 历史命名保留。现在返回的是最近可达的 recovery 图节点。
	var graph := _graph()
	if graph == null:
		return {}
	return graph.nearest_reachable(from, exclude)


func _graph() -> LocationGraph:
	if _world == null:
		return null
	var g: LocationGraph = _world.location_graph
	if g == null or not g.baked:
		return null
	return g
