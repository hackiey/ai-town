@tool
class_name NavmeshTiler
extends Node3D

const TILE_GROUP: StringName = &"_navmesh_tiler_tile"
const TILE_NAME_PREFIX := "Tile_"

# Tiled navmesh generator: 把世界切成等距方格，每格一个 NavigationRegion3D，
# 各自的 NavigationMesh 用 filter_baking_aabb 限制只看本格 AABB 内的几何。
#
# 这样即使整个 demo 几百米跨度+成千节点，单格 bake 只处理小盒子内的体素，
# 既绕过 Godot 的"source geometry too big"防崩检查，又是 AAA 开放世界标准做法
# （Recast 原生支持这种 tile 模式）。
#
# 用法：
#   1. 配 grid 参数（tile_size、grid_min/max、y_min/max）
#   2. 点 Generate Tiles → 创建子节点（每个 NavigationRegion3D + 嵌入 navmesh）
#   3. 点 Bake All → 顺序 bake 每片（编辑器会冻几十秒到几分钟）
#
# Bake 结果存进 .tscn 子资源，运行时零开销；NavigationServer3D 自动拼接相邻片。

@export_group("Grid")
## 一格边长（米）。30–50m 是平衡点：太小 tile 数爆炸，太大 bake 又会触发 too-big。
@export var tile_size: float = 30.0
## 网格 X 索引范围（包含端点）。tile (ix, iz) 占 X∈[ix*tile_size, (ix+1)*tile_size]，Z 同理。
@export var grid_min: Vector2i = Vector2i(-3, -1)
@export var grid_max: Vector2i = Vector2i(0, 2)
## navmesh AABB 的 Y 范围（世界坐标）。覆盖你期望 NPC 能站立的高度区间即可。
@export var y_min: float = -30.0
@export var y_max: float = 10.0

@export_group("Bake")
## 模板：每个 tile 复制它的 cell_size / agent_* / parsed_geometry_type 等参数。
## filter_baking_aabb / source_geometry_mode / source_group_name 由 tiler 覆盖，模板里设啥都行。
@export var navmesh_template: NavigationMesh
## 参与 bake 的几何节点所在 group（递归到所有后代）。
@export var source_group: StringName = &"navmesh"
## 相邻 tile bake AABB 的重叠量（米，每边）。0 时相邻 tile 之间会留下 agent_radius 宽的
## 不可达缝（缩进），路径过不去；默认 0.5 让两边 navmesh 重叠形成共享边，
## NavigationServer3D 自动 stitch。建议 ≥ agent_radius * 2。
## 1.0 时 stitch 区域 edge 太密会触发 navmesh_edge_merge_errors warning（>2 edges
## 落同 voxel），0.5 缓解；如果 character scale 让 agent_radius 变大，要相应调大。
@export var tile_overlap: float = 0.5
## runtime 把 NavigationServer3D 的 edge_connection_margin 调到这个值（米）。
## 默认 0.25 太严：相邻 tile bake 出来的 navmesh 边即使 overlap，因为 voxel 化误差
## 边的端点也可能差 > 0.25m → 不 stitch。0.5–1.0 通常就够。
@export var edge_connection_margin: float = 0.5

@export_group("Actions")
@export_tool_button("Generate Tiles", "Add") var gen_action = generate_tiles
@export_tool_button("Bake All", "PlayBack") var bake_action = bake_all
@export_tool_button("Clear Tiles", "Remove") var clear_action = clear_tiles


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# 等一帧确保 NavigationServer 的 default map 已经 ready
	await get_tree().physics_frame
	var map: RID = get_world_3d().navigation_map
	NavigationServer3D.map_set_edge_connection_margin(map, edge_connection_margin)


func _is_generated_tile(node: Node) -> bool:
	return node.is_in_group(TILE_GROUP) or (
		node is NavigationRegion3D and str(node.name).begins_with(TILE_NAME_PREFIX)
	)


func clear_tiles() -> void:
	var cleared := 0
	for c in get_children():
		if not _is_generated_tile(c):
			continue
		remove_child(c)
		c.queue_free()
		cleared += 1
	print("[NavmeshTiler] cleared %d tiles" % cleared)


func generate_tiles() -> void:
	if navmesh_template == null:
		push_error("[NavmeshTiler] navmesh_template required"); return
	var scene_root := get_tree().edited_scene_root
	if scene_root == null:
		push_error("[NavmeshTiler] not in an edited scene"); return

	clear_tiles()

	var n := 0
	for ix in range(grid_min.x, grid_max.x + 1):
		for iz in range(grid_min.y, grid_max.y + 1):
			var x_min := float(ix) * tile_size
			var z_min := float(iz) * tile_size
			var nav: NavigationMesh = navmesh_template.duplicate()
			nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
			nav.geometry_source_group_name = source_group
			# AABB 比 tile 自身往四周外扩 tile_overlap 米，让相邻 tile bake 出来的 navmesh
			# 在边界有重叠 → NavigationServer3D 能 auto-stitch
			var aabb_size := Vector3(tile_size + 2.0 * tile_overlap, y_max - y_min, tile_size + 2.0 * tile_overlap)
			nav.filter_baking_aabb = AABB(Vector3.ZERO, aabb_size)
			nav.filter_baking_aabb_offset = Vector3(x_min - tile_overlap, y_min, z_min - tile_overlap)

			var region := NavigationRegion3D.new()
			region.name = "%s%d_%d" % [TILE_NAME_PREFIX, ix, iz]
			region.navigation_mesh = nav
			region.add_to_group(TILE_GROUP, true)
			add_child(region)
			region.owner = scene_root
			n += 1
	print("[NavmeshTiler] generated %d tiles (%dx%d, %.0fm each)" % [
		n, grid_max.x - grid_min.x + 1, grid_max.y - grid_min.y + 1, tile_size,
	])


func bake_all() -> void:
	var tiles: Array[NavigationRegion3D] = []
	for c in get_children():
		if c is NavigationRegion3D and _is_generated_tile(c):
			tiles.append(c)
	if tiles.is_empty():
		push_warning("[NavmeshTiler] no tiles; click Generate Tiles first"); return

	var ok := 0
	for i in tiles.size():
		var t := tiles[i]
		print("[NavmeshTiler] baking %s (%d/%d)..." % [t.name, i + 1, tiles.size()])
		t.bake_navigation_mesh(false)  # synchronous; editor freezes per tile
		ok += 1
	print("[NavmeshTiler] baked %d tiles" % ok)
