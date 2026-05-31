# src/world

镇的空间数据：网格坐标系、命名区域、运行时查询。

## 文件

| 文件 | 类型 | 用途 |
|---|---|---|
| `map_grid.gd` | `MapGrid` Resource | 网格几何：原点、cell 大小、宽高。提供 `world_to_cell` / `cell_to_world_*` 转换 |
| `map_region.gd` | `MapRegion` Resource | 一个命名区域：id、显示名、颜色、parent_id（树占位） |
| `region_rect.gd` | `RegionRect` Resource | 把一片矩形 cell 范围归给某 region |
| `region_map.gd` | `RegionMap` Resource | grid + regions[] + rects[] + baked `cell_region: PackedInt32Array`。提供 `region_at_cell` / `region_at_world` |
| `town_world.gd` | `TownWorld` Node3D | 运行时镇 root；持有 RegionMap，给系统层提供 lookup |
| `terrain_builder.gd` | `TerrainBuilder` `@tool` Node3D | 装饰散布器（草丛/小石/泥地装饰），不是底面 |
| `navmesh_tiler.gd` | `NavmeshTiler` `@tool` Node3D | Tiled navmesh 生成器：把世界切方格，每格独立 bake 一片 NavigationRegion3D |
| `debug/grid_renderer.gd` | `GridRenderer` `@tool` MeshInstance3D | 用 ImmediateMesh 画 cell 线框 |
| `debug/region_renderer.gd` | `RegionRenderer` `@tool` MeshInstance3D | 用 ImmediateMesh 画区域半透明色块 |
| `presets/town_demo_grid.tres` | MapGrid | demo grid：origin (-40,0,-40)、cell 1m、80×80 |
| `presets/town_demo_regions.tres` | RegionMap | demo 5 区：town_center / north_meadow / south_meadow / west_woods / east_woods |

## 使用

**第一次打开主项目**：等 Godot 把 FK 资产 import 完（5–15 分钟）。

**地形**：是单个 PlaneMesh 80×80 + FK `Mat_Ground_Grass_01_mat`，在 `town.tscn` 里直接看得到，不需要点按钮。

**散播装饰**（可选）：要在草地上散点草丛/小石/泥地装饰时，加一个 Node3D 挂 `terrain_builder.gd` 脚本，配 `tile_prefabs`，点 `Generate`。FK 的 `SM_Env_Ground_Flat_*` 边缘是不规则曲线、不能当地面拼接，但作装饰小块挺合适。

**Bake navmesh**（NPC 寻路依赖）：`town.tscn` 里 `NavmeshTiler` 节点，配好 `tile_size`、`grid_min/max`、`y_min/max`、`navmesh_template` → 点 `Generate Tiles`（产生 N 个 `NavigationRegion3D` 子节点）→ 点 `Bake All`（顺序 bake，每片几秒到几十秒）。需要 bake 的几何节点（如 `Demo`、`Buildings`）必须加进 `navmesh` group（在节点 inspector → Node → Groups 加）。Tiled 模式绕开了 Godot 单 navmesh 的 source-too-big 防崩检查，是开放世界标准做法。

**Bake 区域**：选 `town_demo_regions.tres`（FileSystem 双击或在 Inspector 里）→ 改 grid / regions / rects → 点 `Bake`。`cell_region` 数组会被刷新；GridRenderer/RegionRenderer 自动重画（监听 `Resource.changed`）。

**运行时查询**：
```gdscript
var tw: TownWorld = $World     # town.tscn 里的 World 节点
var region := tw.region_at_world(player.global_position)
if region != null:
    print("player in: ", region.display_name)
```

## 坐标约定

- 世界 (0,0,0) = 镇中心
- demo grid origin = (-40, 0, -40)，所以世界 (0,0,0) 对应 cell (40, 40)
- cell.x 沿世界 +X，cell.y 沿世界 +Z
- 高度（Y）目前不参与；地形几乎平坦

## 加新区域

1. 在 `town_demo_regions.tres` 的 `regions` 里加 `MapRegion`（id 不能重复）
2. 在 `rects` 里加一个或多个 `RegionRect` 引用该 id
3. 点 `Bake`

后写入的 rect 覆盖先前的，所以"中心 town_center 30×30"放在 4 个外圈 rect 之后就能覆盖外圈在中心的部分。

## strict tree 约束

每个 cell **只能属于一个 leaf region**。`MapRegion.parent_id` 留作未来组织（"north_meadow.parent_id = outdoors"），v1 不做运行时校验，author 自觉。

## 后续

- 区域转换 signal（EventBus.region_changed）
- 多边形区域（rect 不够时）
- 高度图 / Y 维度
- 区域级 metadata（resource spawn rules、ambient sound 等）
