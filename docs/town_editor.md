# 小镇大厅与地图编辑器

项目运行入口现在是 `res://src2d/lobby/town_lobby.tscn`。大厅负责展示服务器上已发布的小镇、下载地图并进入游戏，也可以进入本地编辑器新建或管理自己的小镇。

本地项目管理器使用 `user://town_project_registry.json` 保存小镇工程路径列表，类似 Unity 或 Godot 的项目启动页。注册表只保存项目地址，不保存地图内容，也不会因为从列表移除项目而删除工程文件。

## 启动

先启动大厅服务器：

```bash
cd backend
pnpm dev
```

然后从 Godot 运行项目。大厅默认连接 `http://127.0.0.1:3000`。需要连接其他服务器时：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . -- --town-api http://服务器地址:端口
```

服务器不可用时仍然可以点击 `新建小镇` 或 `管理我的小镇` 使用本地编辑器，但在线列表、下载和发布不可用。

## 小镇项目包

编辑器中新建的小镇默认位于：

```text
user://towns/<town_id>/
├── town.json
└── map.json
```

通过项目管理器导入的小镇可以位于磁盘上的其他目录。运行和编辑时会先从 `town_project_registry.json` 查找工程路径，再读取该目录中的 `town.json` 和 `map.json`。

`map.json` 是地图数据源。当前 v7 保存：

- 地图尺寸和玩家出生点
- 基础草地、局部草地变体、道路、农田、水面语义图层
- 原有房屋、帐篷、装饰物、地点标记
- 独立 `characters` 人物实例、可复用 `character_profiles` 组件档案，以及实例级 Controller 配置

编辑器不让用户直接选择 Tile 编号。用户从素材库中选择“青绿草地”“灰石道路”等语义材质，Godot 运行时再解析对应的 atlas source 和 Tile。道路的边缘、直线、转角、T 型路口和十字路口由 `TownMapRules2D` 统一处理；相同材质的道路互相连接，不同材质在交界处分别收边。

v7 地形数据示例：

```json
{
  "terrain": {"base_ground": "ground_meadow"},
  "layers": {
    "ground": [
      {"x": 2, "y": 2, "width": 6, "height": 1, "material": "ground_deep"}
    ],
    "roads": [
      {"x": 4, "y": 8, "width": 12, "height": 1, "material": "road_gray_cobble"}
    ]
  }
}
```

旧版没有 `material` 的地形会在加载时自动迁移为默认材质。

## 素材库设计

编辑器侧栏现在使用统一的两级 `素材库`，不再把地形按钮和建筑下拉框分散在两个 Tab。一级分类使用 `环境 / 建筑 / 人物 / 特效 / 物品` 五个固定 Tab，二级分类使用可自动换行的按钮；下方路径会显示当前分类及素材数量。逻辑分类由 `src2d/data/town_asset_library.gd` 管理，外部图片仍保持原始素材包目录结构：

- `环境`：地表、道路、农田、水面、自然、围栏、地面细节
- `建筑`：住宅、帐篷、营地设施
- `人物`：先显示 20 个内置语义预设，再显示在“人物”页保存的小镇居民档案；两者都由组件实时合成，不提供固定成品角色
- `特效`：5 个方向的六帧旗帜，以及火焰/烟雾双层篝火
- `物品`：村庄杂物、箱子容器、灯具、木料

人物使用 CraftPix 分层 PSD 导出的 119 张透明组件 spritesheet。编辑器在“人物”页按肤色、上下装、五官、发型、头饰、配饰和装备实时叠加；配饰和装备支持多选，预览可切换四个方向。保存后只记录稳定的组件 ID，不生成新的成品 PNG。

系统内置 20 个语义预设，作为组件组合的起点：城镇卫兵、老兵队长、村庄铁匠、森林游侠、荒野猎人、苍蓝法师、赤焰术士、苔林德鲁伊、紫夜女巫、城镇炼金师、提灯祭司、王都贵族、蓝衣领主、精灵斥候、兽人战士、哥布林工匠、龙裔教徒、黑甲骑士、旅行商人和吟游诗人。它们保存在 `data/characters/semantic_presets.json`，不复制进每个小镇地图。

在“人物”页选择 `预设 · 城镇卫兵` 后，会载入名称、语义描述和全部组件。用户可以继续替换任意部件，保存时才创建一份属于当前小镇的可编辑 `character_profile`。删除小镇档案不会影响内置预设。

人物动作也使用稳定语义 ID。当前分层 PSD 的真实素材只有 `idle` 和 `walk`：四个方向各有待机、左步、右步三帧。系统另外接入 `guard / forge / gather / attack / cast / brew / pray / trade / perform / talk`，这些动作目前通过统一的位移、缩放、倾斜和发光节奏表现，并明确标记为程序化动作。以后补充同规格分层动作表时，可以在动作目录替换实现，不需要修改预设或地图 JSON。

每个预设包含可用动作集合、默认动作和默认朝向。例如城镇卫兵默认循环播放 `guard`，铁匠播放 `forge`，法师播放 `cast`，商人播放 `trade`，吟游诗人播放 `perform`。人物编辑页会实时播放所选动作；地图中选中人物后，也可以单独设置动作、朝向及是否循环。

人物档案和地图实例分开保存：

```json
{
  "character_profiles": [
    {
      "id": "blacksmith_apprentice",
      "name": "铁匠学徒",
      "description": "在村庄铁匠铺学习锻造的年轻助手。",
	  "source_preset_id": "village_blacksmith",
	  "actions": ["idle", "walk", "forge", "trade", "talk"],
	  "default_action": "forge",
	  "default_direction": "right",
      "appearance": {
        "catalog": "craftpix_rpg_48",
        "catalog_version": 1,
        "groups": {
          "skin_tone": ["skin_tone/pale"],
          "up_vest": ["up_vest/chainmail"],
          "hair": ["hair/short_brown"]
        }
      }
    }
  ],
  "characters": [
    {
      "id": "character_blacksmith_apprentice",
      "asset": "character_composite",
      "character_id": "blacksmith_apprentice",
      "cell": [18, 12],
      "footprint": [1, 1]
	},
	{
	  "id": "character_town_guard",
	  "asset": "character_composite",
      "preset_id": "town_guard",
	  "action": "guard",
	  "direction": "down",
	  "action_loop": true,
	  "controller": {
	    "type": "player",
	    "move_speed": 220,
	    "behavior": "idle",
	    "wander_radius": 4
	  },
	  "appearance": {
	    "catalog": "craftpix_rpg_48",
	    "catalog_version": 1,
	    "groups": {
	      "skin_tone": ["skin_tone/pale"],
	      "down_vest": ["down_vest/plate_pants"],
	      "up_vest": ["up_vest/chainmail"],
	      "war_paint_and_scars": [],
	      "eyes": ["eyes/brown"],
	      "accessories": ["accessories/red_tabard"],
	      "equipments": ["equipments/shield_in_the_back", "equipments/sheathed_sword"],
	      "face": [],
	      "eyebrows": ["eyebrows/brown"],
	      "hair": [],
	      "head": ["head/steel_helmet"],
	      "ear": []
	    }
	  },
	  "cell": [22, 12],
	  "footprint": [1, 1]
    }
  ]
}
```

编辑器居民、运行时居民和玩家移动角色都复用 `CharacterVisual2D`。旧地图中的 `resident_pale_adventurer` 会在加载时迁移到 `characters` 并转换为等价组件配置。

### 人物实例属性与 Controller

人物放到地图后，先按 `Esc` 或点击 `选择 / 编辑实例` 取消鼠标上携带的素材，再左键点击人物。实例属性会显示在地图右侧独立的 `实例编辑` 面板中，不再占用左侧素材库：

- 实例名称，以及只读的实例 ID、外观来源和所在格子
- `静态人物 / Player Controller / AI Controller`
- 移动速度
- AI 的 `原地活动 / 区域漫游` 行为和漫游半径
- 阴影、缩放
- 默认动作、朝向和循环状态
- 通用渲染层与实例绘制顺序

Controller 使用可扩展的嵌套数据保存：

```json
{
  "controller": {
    "type": "ai",
    "move_speed": 90,
    "behavior": "wander",
    "wander_radius": 5
  }
}
```

一个地图只能有一个 `Player Controller`。把另一个实例设为 Player 时，原 Player 会自动变回静态人物。开始游戏后，Player 会从该地图实例继承位置、外观、缩放、阴影和移动速度，并由摄像机跟随；这个实例不会再重复生成一份静态人物。AI Controller 会生成动态 `CharacterBody2D`：`idle` 保持原地动作，`wander` 在初始格附近随机漫游。没有 Controller 的旧地图继续使用 `player_spawn + player_character_id` 作为兼容回退。

项目中的两个 CraftPix 包包含完全相同的基础地形图集，因此素材库只暴露一份 canonical 地形，不把重复文件伪装成两种素材。新增的道路、草地、田地和水面外观是在同一像素拓扑上生成的配色材质变体，这样所有道路仍能复用同一套 16 邻接规则，也不会混入不同画风。以后加入真正的新 tileset 时，只需在素材库中增加 source profile 和 material 条目，不需要修改地图 JSON 的 Tile 编号。

动画对象仍按普通语义对象保存，例如 `{"asset": "flag_1"}` 或 `{"asset": "campfire_lit"}`。`MapObject2D` 会在运行时将横向 spritesheet 切成 6 帧：旗帜以 8 FPS 循环；篝火的烟雾层以 6 FPS、火焰层以 10 FPS 同时播放。素材库缩略图只显示第一帧，不会把整条 192px spritesheet 压进图标。

## 地图叠放层级

编辑器和运行时使用同一套固定绘制层级，不再依赖素材加入节点的先后顺序：

- `0` 基础草地
- `10` 农田
- `20` 水面
- `30` 道路
- `40` 地面贴花（泥土斑块）
- `45` 地图语义栅栏
- `50` 世界对象（建筑、树木、植物、道具、独立栅栏、动画和玩家）
- `60` 前景对象预留层
- `4000` 编辑器放置预览（保留）
- `4095` 编辑器网格、选区和占地提示（保留）

世界对象层启用 Y 排序，并以素材底部中心锚点作为前后判断基准。玩家选中地图中已经放置的对象后，可以修改这个实例的基础层和 `-1000～1000` 自定义绘制顺序。最终遮挡值等于“基础层值 + 自定义顺序”：数值越大越靠前，最终值相同时才按地图 Y 坐标排序。因此同一种树的不同实例也可以分别压在房屋上方或藏到道路下面。编辑器预览和选区占用最高保留层，不会被玩家配置遮住。

实例覆盖会直接保存在地图对象上：

```json
{
  "asset": "tree_1",
  "render_layer": "world",
  "render_order": 75
}
```

编辑器里的“恢复素材默认”会删除这两个实例字段，让对象重新继承素材库设置。

建筑同样按语义对象保存，不直接编辑场景节点：

```json
{
  "id": "building_house_1",
  "name": "小屋 1",
  "asset": "house_1",
  "cell": [20, 15],
  "footprint": [4, 4]
}
```

## 对象编辑

1. 在 `素材库` 选择住宅、营地、自然或道具分类。
2. 点击具体素材后，移动鼠标查看预览；绿色边框表示可以放置，红色表示不可放置。
3. 左键放置对象；完成放置后按 `Esc`，或点击侧栏顶部的 `选择 / 编辑实例`，鼠标上的素材会消失并进入选择模式。
4. 选择模式中左键点击已有对象，会在地图右侧打开独立的 `实例编辑` 面板；点击空地只会取消选择，不会继续放置素材。
5. 需要移动实例时，先选中对象，再点击右侧面板中的 `移动选中实例`，最后左键指定新位置。
6. 右键点击对象，或选中后按 `Delete` / `Backspace`，可以删除实例。放置模式下右键点击空地会取消手持素材。

当前会检查地图边界、水面，以及建筑、装饰物、人物之间的占地重叠。

## 使用

1. 启动项目，默认进入 `AI 小镇大厅`。
2. 点击大厅里的小镇卡片下载地图并进入游戏；下载内容缓存到 `user://towns/remote_<server_id>/`。
3. 点击 `管理我的小镇` 会进入项目管理器；可以新建工程、导入已有工程目录、编辑、运行，或只从地址列表中移除项目。
4. 点击 `新建小镇`，填写小镇 ID、显示名称、宽度和高度，再点击 `创建小镇`。
5. 编辑器左侧栏分为 `项目`、`素材库`、`人物`、`发布` 四个 Tab，右侧是独立的 `实例编辑` 面板。可以从 `素材库 → 人物 → 居民` 直接放置 20 个内置预设，也可以在“人物”页载入预设、继续拼接并保存为小镇人物档案。放置后按 `Esc`，左键选中地图人物，再从右侧面板将 Controller 改为 `Player Controller`，即可在运行时控制它。
6. 地形模式下左键绘制、右键擦除；对象模式分为放置、选择和移动三种状态。`Ctrl+Z` / `Command+Z` 撤销上一步编辑；Mac 触控板双指平移画面，鼠标滚轮或触控板捏合可围绕光标位置缩放；`Ctrl+S` / `Command+S` 保存。
7. 填写镇长名称和简介，点击 `发布到大厅`。首次发布后，本机会在 `town.json` 保存服务器小镇 ID 和编辑令牌。
8. 再次发布同一项目时按钮会显示 `更新大厅地图`，并覆盖服务器上的已有版本。
9. 点击 `运行当前小镇` 查看游戏地图；游戏内可以返回大厅或重新打开编辑器。

内置示例和从服务器下载的缓存地图不能直接发布。需要发布时，请先创建自己的本地小镇项目。

当前内置素材来自项目中的 CraftPix 素材包。素材分类、默认占地和地形材质由 `TownAssetLibrary` 统一管理；`data/mechanics/town_editor.lua` 仍提供默认地图和轻量 palette 接口，编辑器输入、预览和场景绘制由 Godot GDScript 负责。
