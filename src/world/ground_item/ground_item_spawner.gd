class_name GroundItemSpawner

# 地面物品的唯一入口。player + NPC drop / boot hydrate 全走这里，避免
# 任何一边脱离持久化或反重叠逻辑。
#
# 设计原则：
#   - **不是** autoload；纯 static helper，零状态。
#   - 实例化走 current_scene 下的 GroundItemSpawner(MultiplayerSpawner)→ 节点像 Crop
#     一样自动复制到所有 client（含晚加入的 peer），不会只在 server 本地存在。
#     节点统一挂在 spawner 的 spawn_path（GroundItems 容器）下。
#   - spawn 时反重叠（_scatter）：同一个点反复丢会沿环散开，避免 hover 摸瞎。
#   - hydrate 用存盘原位，**不**重新散，否则每次重启位置漂移。

# 反重叠：在 target 周围 _MIN_SEPARATION 米内若有 ground item，按 60° 步长扇形外推。
# 至多 _SCATTER_STEPS 次尝试（环绕一圈），仍冲突则接受最后位置，避免无限循环。
const _MIN_SEPARATION := 0.5
const _SCATTER_STEPS := 6


# Player / NPC drop 调（server-only）。slot 必须已是 inventory normalize 过的 dict；
# 实例化经 MultiplayerSpawner.spawn() → 自动复制到所有 client。返回 server 端新建的
# GroundItem 节点（caller 一般不用，主要测试用）。
static func spawn_for_character(character: Node3D, slot: Dictionary) -> GroundItem:
	assert(RunMode.is_runtime(), "spawn_for_character must run on the runtime server")
	var tree := character.get_tree()
	# 落点：character 脚下 + forward 0.4m，避免穿模 + 不直接踩在脚上。
	# Godot 默认朝向 -Z，所以 forward 是 -basis.z；character 是 Node3D 直接用 transform。
	var target: Vector3 = character.global_position - character.global_transform.basis.z * 0.4
	var pos := _scatter(tree, target)
	var id := "world|%d|%d" % [Time.get_ticks_usec(), randi() & 0xFFFF]
	var node := _find_spawner(tree).spawn({"id": id, "slot": slot, "pos": pos}) as GroundItem
	Db.save_ground_item(id, String(slot.get("item_id", "")), pos, slot)
	return node


# Boot 时由 town.gd._hydrate_persisted_ground_items 调，每行一次。
# 不写 Db（已是源数据）、不 scatter（保留原位）。
static func hydrate_from_db(tree: SceneTree, id: String, pos: Vector3, slot: Dictionary) -> GroundItem:
	return _find_spawner(tree).spawn({"id": id, "slot": slot, "pos": pos}) as GroundItem


# current_scene 下的 GroundItemSpawner（town.tscn 里 spawn_path=../GroundItems，
# spawn_function=GroundItem.from_spawn_data 由 town.gd._ready 装好）。
static func _find_spawner(tree: SceneTree) -> MultiplayerSpawner:
	return tree.current_scene.get_node("GroundItemSpawner") as MultiplayerSpawner


static func _scatter(tree: SceneTree, target: Vector3) -> Vector3:
	var existing: Array = tree.get_nodes_in_group("ground_items")
	var pos := target
	for i in range(_SCATTER_STEPS + 1):
		if not _has_overlap(existing, pos):
			return pos
		# 螺旋外推：先在 _MIN_SEPARATION 半径试 6 个方向，随机扰动 0.3rad 避免完全对齐。
		var angle := TAU * float(i) / float(_SCATTER_STEPS) + randf() * 0.3
		pos = target + Vector3(cos(angle), 0.0, sin(angle)) * _MIN_SEPARATION
	# 兜底：六次都没找到无冲突位，接受当前。极少触发，比无限循环安全。
	return pos


static func _has_overlap(existing: Array, pos: Vector3) -> bool:
	for n in existing:
		if not (n is Node3D):
			continue
		if pos.distance_to((n as Node3D).global_position) < _MIN_SEPARATION:
			return true
	return false
