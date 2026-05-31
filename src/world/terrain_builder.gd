@tool
class_name TerrainBuilder
extends Node3D

# 装饰性散布器：在自身下按 grid 排列任意 PackedScene 实例（草丛、灌木、小石、装饰泥地等）。
# 注意 FK 的 SM_Env_Ground_Flat_* 不是网格瓦片（边缘不规则、本质上是装饰），
# 不能当地面用——底面用 PlaneMesh + Ground 材质。这个工具适合在 PlaneMesh 上面散点装饰。
# 中心 = 自身原点，散布占 [-W/2, W/2] × [-D/2, D/2]，W = grid_width * tile_size。
# 点 Generate 即清空旧 children 重建。运行时不再生成（bake-once）。

@export var tile_prefabs: Array[PackedScene] = []
@export var tile_size: float = 10.0
@export var grid_width: int = 8
@export var grid_depth: int = 8
@export var rotation_jitter: bool = true       # 随机 0/90/180/270°
@export var scale_jitter: float = 0.0          # ±比例。FK 瓦片本身有微凸，过大缩放会破坏接缝
@export var rng_seed: int = 42

@export_tool_button("Generate", "PlayBack") var generate_action = generate
@export_tool_button("Clear", "Remove") var clear_action = clear


func generate() -> void:
	if tile_prefabs.is_empty():
		push_error("[TerrainBuilder.generate] tile_prefabs is empty"); return
	clear()

	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var origin_x := -float(grid_width) * tile_size * 0.5
	var origin_z := -float(grid_depth) * tile_size * 0.5
	var ok := 0

	for gz in grid_depth:
		for gx in grid_width:
			var prefab: PackedScene = tile_prefabs[rng.randi() % tile_prefabs.size()]
			var inst := prefab.instantiate()
			if inst == null:
				push_warning("[TerrainBuilder] failed to instantiate %s" % prefab.resource_path)
				continue
			add_child(inst)
			inst.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else self

			var cx := origin_x + (float(gx) + 0.5) * tile_size
			var cz := origin_z + (float(gz) + 0.5) * tile_size

			var rot_y := 0.0
			if rotation_jitter:
				rot_y = float(rng.randi() % 4) * (PI * 0.5)

			var s := 1.0 + (rng.randf() * 2.0 - 1.0) * scale_jitter

			var basis := Basis(Vector3.UP, rot_y).scaled(Vector3(s, s, s))
			(inst as Node3D).transform = Transform3D(basis, Vector3(cx, 0, cz))
			(inst as Node3D).name = "Tile_%d_%d" % [gx, gz]
			ok += 1

	print("[TerrainBuilder] generated %d tiles (%dx%d, seed=%d)" % [ok, grid_width, grid_depth, rng_seed])


func clear() -> void:
	for child in get_children():
		child.queue_free()
