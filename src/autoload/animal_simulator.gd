extends Node

# Autoload: AnimalSimulator
#
# 畜牧动物的小时级模拟，**单一写者**（镜像 PassiveSimulator 的设计，但订阅
# GameClock.slow_tick 而不是各反应自带 tick_seconds —— 生命周期是按游戏小时推进的）：
#   1. 每头：fed 衰减 + 成长推进（young→adult）+ 持久化（Animal.lifecycle_tick）
#   2. 孕期到点：母体产仔（用 town 的 AnimalSpawner spawn 一只 young，与 crop 同机制 + 同步给 client）
#   3. 自动繁殖：同物种 ≥2 头成年、喂饱、邻近、未超 herd_cap → 发起一胎
#
# server-only（client 是 puppet，动物状态靠 MultiplayerSynchronizer 推）。野外动物 /
# 非 livestock 物种不参与（Animal.is_livestock()=false）。

const BREED_RADIUS := 6.0   # 两头成年在此半径内才配对

var _birth_counter: int = 0


func _ready() -> void:
	if Engine.is_editor_hint() or not RunMode.is_runtime():
		return
	GameClock.slow_tick.connect(_on_slow_tick)


func _on_slow_tick(total_hour: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	# 快照当前存活的畜牧动物（产仔会往组里加新节点，先快照避免本拍迭代到新生儿）。
	var animals: Array = []
	for n in tree.get_nodes_in_group("animals"):
		var a := n as Animal
		if a != null and a.is_livestock() and a.alive:
			animals.append(a)

	# 1) 逐头：fed 衰减 + 成长 + 持久化
	for a in animals:
		a.lifecycle_tick(total_hour)

	# 2) 孕期到点 → 产仔
	for a in animals:
		if a.gestation_due(total_hour):
			_give_birth(a, total_hour)

	# 3) 自动繁殖发起
	_try_breeding(animals, total_hour)


func _give_birth(mother: Animal, total_hour: int) -> void:
	mother.clear_pregnancy()
	var spawner := _find_spawner()
	if spawner == null:
		push_warning("[AnimalSimulator] 找不到 AnimalSpawner，无法产仔")
		return
	_birth_counter += 1
	var new_id := "born_%s_%d_%d" % [mother.species_id, total_hour, _birth_counter]
	var pos := mother.global_position + Vector3(randf_range(-1.0, 1.0), 0.5, randf_range(-1.0, 1.0))
	# 出生即 spawn；calf._ready → _init_lifecycle 无 saved 行 → 初始化为 young + 持久化。
	var calf := Animal.spawn(spawner, mother.species_id, pos, new_id)
	if calf == null:
		push_warning("[AnimalSimulator] 产仔 spawn 失败: %s" % mother.species_id)


# 同物种成年配对：每物种每 tick 最多发起一胎，群已满（herd_cap）则不繁殖。
func _try_breeding(animals: Array, total_hour: int) -> void:
	var by_species: Dictionary = {}
	for a in animals:
		var arr: Array = by_species.get(a.species_id, [])
		arr.append(a)
		by_species[a.species_id] = arr
	for species in by_species.keys():
		var herd: Array = by_species[species]
		var cap := int(AnimalSpecies.life_of(species).get("herd_cap", 6))
		if herd.size() >= cap:
			continue
		var ready_list: Array = []
		for a in herd:
			if a.can_breed(total_hour):
				ready_list.append(a)
		# 找一对邻近的可繁殖成年 → 一方受孕、另一方进入冷却。
		var bred := false
		for i in ready_list.size():
			if bred:
				break
			for j in range(i + 1, ready_list.size()):
				var m := ready_list[i] as Animal
				var f := ready_list[j] as Animal
				if m.global_position.distance_to(f.global_position) <= BREED_RADIUS:
					m.begin_pregnancy(total_hour)
					f.mark_sired(total_hour)
					bred = true
					break


func _find_spawner() -> MultiplayerSpawner:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("AnimalSpawner") as MultiplayerSpawner
