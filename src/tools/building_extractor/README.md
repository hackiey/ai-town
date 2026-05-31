# building_extractor

把一个 demo 场景里的"顶层 Node3D groups"各自打成独立 PackedScene 文件。

典型用途：从 FK 的 `Demo_Layout_Houses_With_Interiors.tscn` 一键提取 30 栋"可进的房子"成为可复用 prefab。

## 用法

1. 任意 Godot 场景里加个 `Node`，把 `extractor.gd` 挂上去
2. Inspector 配置：
   - `source_demo`：拖入 demo 场景文件（如 `third-party/polygon-fantasy-kingdom/Assets/PolygonFantasyKingdom/Scenes/Demo_Layout_Houses_With_Interiors.tscn`）
   - `output_dir`：输出目录（默认 `res://assets/buildings`，不存在会自动建）
   - `node_prefix`：只提取顶层 Node3D 中名字以此开头的（默认 `Preset_`）
   - `lowercase_output`：文件名是否小写（默认 true，"Preset_House_01_A" → `house_01_a.tscn`）
3. Inspector 顶上点 **Extract** 按钮

输出每个 .tscn = 一栋建筑，root 是 Node3D，下面挂原 demo 里的所有零件（墙、地板、屋顶碎片等）。

## 重要细节

- **transform 会被清零**：每个 prefab root 的 transform 重置为 identity。子节点保持原 local 坐标——也就是说 prefab 的"原点"位于 demo 中艺术家放置该 group 的 pivot 位置（不一定是建筑几何中心）。后面在 town 里 instance 这个 prefab 时，它会出现在你设置的 transform 处
- **owner 重写**：Godot 的 `PackedScene.pack(node)` 只 pack `owner == node` 的子节点。本工具递归把 sub-tree 所有节点的 owner 设为新 root，否则 pack 出来是空的
- **不修改原 demo 文件**：源场景仅 instantiate 进内存，遍历完即销毁

## 提取后

每栋房子的子节点结构形如（以 House_01_A 为例，~453 个节点）：

```
Preset_House_01_A_<from_extractor>
├── SM_Bld_House_Base_Wall_01 (1)        StaticBody3D + visual
├── SM_Bld_House_Base_Wall_01 (2)
├── ... (其余墙)
├── SM_Bld_House_Floor_Wood_01 (1)       地板
├── SM_Bld_House_Roof_Tile_Half_02 (1)   ★ 屋顶（按"Roof"过滤可批量隐藏）
├── SM_Bld_House_Roof_Tile_Half_02 (2)
├── ... (其余屋顶碎片)
└── SM_Bld_House_Door_01 (1)             门
```

要在运行时隐藏屋顶：遍历建筑的子节点，名字含 `Roof` 的设 `visible = false`。
