# Site / Space / Map refactor plan

> Status: **全部 7 阶段完成，已 Godot 验证** — backend tsc 通过；Godot 4.6 headless `--editor --import` 零脚本/场景错误；runtime 启动实测 sites 表正确 seed（65 行：29 location/19 workstation/10 farm/4 container/3 shelf；26 global=26 zoned；**well 多锚点 6 个**；zone/category 由 site_meta.json 灌入正确）。
> 修过的 bug：`SiteMarker.zone` 原写成 `@export_enum(...,"")` 含空选项 → Godot 拒编译 → 全 SiteMarker 变 placeholder（"Failed to compile depended scripts"）。改成普通 `@export var zone: String`。
> 待人工验证（需跑起 backend 全链路）：城镇地图 prompt 实际文案分组、SpaceVolume 室内外遮挡行为。
>
> ## 完成情况（实测/编译验证）
> - **Phase 1 ✅**：SiteMarker.gd / SpaceVolume.gd / sites 表(+anchorsJson) / save_site / SiteRecordView+SpaceRecordView / site-repo.ts 只读层。
> - **Phase 2 ✅**：16 个预制体 Approach 脚本 → SiteMarker；location_marker.tscn/waypoint_marker.tscn → SiteMarker；well 标 global；node 类 get_site_marker()。
> - **Phase 3 ✅**：town_world registry 认 SiteMarker + _seed_sites_to_db()（多锚点/capabilities/space/global-local）；CharacterPerception 视觉+听觉按 SpaceVolume 跨空间遮挡（无 volume 时 = 旧纯距离行为）；can_perceive_between/space_id_at。
> - **Phase 6 ✅**：NavTestPanel → MapPanel（文件/类/常量/RPC request_move_to_site/i18n ui.map.*/文案"地图"）；去尽 debug/test 命名。
> - **Phase 7 部分 ✅**：删除孤儿 location_marker.gd/approach_marker.gd(+uid)；get_approach_node 别名并入 get_site_marker（全调用方已改）。**location_markers 表保留**——farm-repo LEFT JOIN 取 farm ownerGroup 依赖它，删它会断农田归属。
>
> - **Phase 4/5/7-backend ✅**：地点结构真值切到 Godot 的 sites 表，backend 只渲染+解析。
>   - 新增 `name-resolver/site-catalog.ts`：sites 表快照成内存 catalog，每次 assemble `refreshSiteCatalog`（version 计数令下游 alias 索引失效重建）；db-less 的 resolver/localize/renderTownMap 都读它。
>   - `locationDescriptors()` → 转发 `siteDescriptors()`（zone/category 来自 site；children 由 parentSiteId+ownerGroup 派生、sortOrder 排）。**删 `backend/data/town/locations.json`** + 未用的 `primaryNpcs`。
>   - zone/category 真值移到 **`backend/data/town/site_meta.json`（Godot 读）**，`town_world._seed_sites_to_db` 写进 sites 表；SiteMarker 显式设 zone/category 时以 marker 为准。backend TS 不再读任何地点结构文件。
>   - `location_markers` 表保留（farm-repo ownerGroup 依赖，和 sites 同源 seed）；wire 字段保留 `locationId`（值=siteId）。
>   - **风险**：全链路只过了 tsc，未跑 Godot↔backend；城镇地图分组/排序由 sites 派生，与旧手编排可能有细微差异，需跑起来看 prompt 实际输出。
>
> 决策：一次性按原计划做、含 Space 系统、site 保留 anchors 数组、sites 表由 Godot 建表 backend 只读。
> 两处务实偏差（不缩小重构范围）：①owner_group 继续写在机制节点（避免在 town.tscn 跨节点搬 27 个 override），registry 合成进 SiteRecord；②机制字段真值留机制节点、registry 只读不复制。
> 迁移期保留 get_approach_node() 别名 + location_marker.gd/approach_marker.gd 孤儿脚本，Phase 7 删。
>
> **可验证里程碑（当前）**：游戏照常加载 + sites 表被填充（含多锚点水井/space/map_registration）。
> Phase 2 实际改动：16 个 workstation/shelf/farm 预制体 Approach 脚本 → SiteMarker；location_marker.tscn/waypoint_marker.tscn → SiteMarker；well 预制体 Approach 标 map_registration=global；node 类加 get_site_marker()；town_world registry 认 SiteMarker + _seed_sites_to_db()。town.tscn 无需改（location 用 node 名、3 个 location_id 是 ShelfNode 字段不动）。

## 0. 落地后修订（2026-06，**权威**）

> 下文 §1–§15 是原始规划稿，保留作设计记录。**凡与本节冲突，以本节为准**——本节记录实际落地后又做的几处收口（核心诉求：每个有意义的字段在 town.tscn 显式 authored、可在 inspector 直接 debug、无运行时拼装/推导/兜底、缺值 fail-loud）。

- **`mapRegistration` 枚举改名 `global | local`**（原文写 `dynamic`）。`local` = 不进城镇地图但仍是 site。下文所有 `dynamic`（指地图注册）读作 `local`；"dynamic" 仅在指「runtime 动态生成的人物/地面物品 site」时保留原义。
- **SiteMarker 不再携带机制身份字段**（解耦，组件只管位置/交互/地图/权限）：
  - 删 `defId` / `entityId` —— def 与状态键留在机制本体（`WorkstationNode.workstation_id` / `ContainerNode.container_id` / `FarmGroup.farm_id`），seed 时 `_site_def_id` / `_site_entity_id` 从本体取。§3.4 / §3.3 / §8.1 的「SiteMarker 出 defId/entityId / to_site_record()」作废。
  - 删 `nameKey` / `descriptionKey` —— **名字/描述永远按 `site_id` 查 i18n catalog `data/i18n/<locale>/locations.json` 的 `location.<site_id>.alias/description`**，不落场景字段（否则 zh/en 分叉）。§3.13 / §3 字段表 / §7 解析顺序里的「nameKey 优先」作废，sites 表 `nameKey`/`descriptionKey` 列 seed 时恒空。
  - 删死代码 `to_site_record()` / `effective_entity_id()`（零调用，seed 自己内联组 dict）。
- **`site_id` 显式 authored，无运行时拼装**：工作台原来 `workstation_logical_id(ws)` 拼 `<def>@<group>`（如 `forge@blacksmith_shop`），inspector 里 site_id 是空的。现 town.tscn 每个工作台/容器/货架实例**显式填 `site_id`**（值不变，仍含 `@`），`workstation_logical_id` 改为直接返回 `marker.site_id`、空则 push_error。井 6 个实例继承 base 的 `site_id="well"` 合并多锚点。
- **`parent_site_id` 显式写死，不从场景层级/ownerGroup 推**：seed 改读 `marker.parent_site_id`。town.tscn 39 个子 site 显式填父（4 集市摊位→`market_square`、25 机制对象→所在店铺、10 农田→所属农庄）；25 顶层 zoned 地点 + 公共水井留空（真没父）。**唯一行为变化**：`treasury_vault`（owner=royal_house 非 location，原 backend 推不出父=游离）现显式 `parent_site_id="treasury"`，归位到所在建筑。
- **zone/category 不继承、不推导**：城镇地图只遍历 `mapRegistration=global` 的 site 并按 zone 分组，故 `_validate_fields` **只对 global 强制 zone**（空则 push_error）；`local` 站点（工作台/容器/货架/农田/集市子店）zone 留空合法，**它们在地图上靠 `parent_site_id`→children 嵌套到父店铺下，借父的层级，自己不需要 zone**。backend `siteDescriptors` 直拷 `r.zone/r.category`，不从父补。
- **space 不是 SiteMarker 字段**：删 `space_id`。space 改由几何包含算——`SpaceVolume`（Area3D）挂在**室内地点 SiteMarker 下作子节点**，某 site 的 space = 框住其坐标的那个 volume 所属地点的 `site_id`，没被框住 = `town_outdoor`；seed 时 `TownWorld.space_id_at(point)` 注入 `sites.spaceId`。理由：space 是「物理上在哪个房间」的几何事实，做成字段会与真实坐标 stale；玩家实时 space（每帧按坐标查）走同一套，零分叉。§2.3 / §3.7 / §8.2 据此更新。**现状：town.tscn 一个 SpaceVolume 都没摆 = 系统休眠，全部解析为 `town_outdoor`、跨 space 遮挡恒通过。**
- **半径无默认 / `site_meta.json` 已删**：4 个半径在 5 个 base 预制件（location 10/50/0/3、workstation/container/shelf 3/10/3/1、farm 10/30/1.5/1.5、character 3/50/3/1、item 3/10/3/1）显式填，`eff_*` 直返字段，缺值 push_error。zone/category 原计划经 `backend/data/town/site_meta.json` 灌入（见下方旧状态头），**该文件已删**——zone/category 直接搬进 town.tscn 每个 location 实例（25 顶层填 zone+category，4 个 market_square 子店只 category）。

- **玩家城镇地图只列 global，与 NPC move 全集分开**：`MapPanel` 原用 `known_position_ids()`——那其实是 **NPC `move_to_location` 全集**（含每个工作台/容器/货架/田块），与"城镇地图"被混用，导致玩家地图列出货架等 local site，且货架 def 不在 `workstations.json` → `location_alias` 退回原始英文（"bakery_bread_shelf（黑尔面包店）"）。按本计划 §6.1「城镇地图只遍历 global」收口：town_world 注册时按 `marker.map_registration=="global"` 收集 `_global_map_site_ids`、新增 `global_map_site_ids()`，`MapPanel` 改读它（25 分区地点 + 水井 = 26 项，全中文）；`known_position_ids()` 不动，NPC 仍能 move 到工作台/田。货架/工作台不再上玩家地图——玩家走到所属地点后就近交互（本就是设计意图）。

- **容器 registry 跟上多锚点（水井 6 口共享 "well"）**：`Containers._containers_by_id` 原是 `id→单节点`，6 口井注册同 id 互相覆盖（"duplicate id 'well', replacing"），只剩最后一口——其余 5 口 `nearby_snapshots`/打水距离判定全失效（"太远"/"不在手边"）。改成 `id→节点数组`：注册 append（储物容器撞 id 仍 `push_error`，内容归属不明=真错误；无限源水井多节点合法）；内容/系统操作走 `find_container_node`（取任一，水井内容无差）；**距离校验走新增 `find_container_node_near(id, from)`（取最近节点）**——玩家 take/put/draw/view + NPC `_near_node` + `resolve_for_actor` 全切到它。snapshot 遍历改 `_all_nodes()` 扁平展开，6 口井各按距离进可见列表。这是 site 多锚点概念在容器侧的对齐。

- **工作台 site_id 全部显式 authored（2026-06-08，落地）**：原 `workstation_logical_id(ws)` 运行时拼 `<def>@<group>`，inspector 里 SiteMarker.site_id 是空的。现 `workstation_logical_id` 直接返回 `marker.site_id`、空则 push_error（fail-loud，绝不退 node.name——实例化默认沿用场景根名跨铺必重名）。town.tscn 里 **22 个工作台/货架/容器实例**新增 `SiteMarker` override 块显式填 `site_id`（值 = 旧拼装真值原样保留，如 `forge@blacksmith_shop`/`tavern_bar_shelf@tavern`/`treasury_vault@royal_house`）+ `parent_site_id`（= 所在店铺）；实例覆盖子节点必须同时加 `[editable path="..."]` 条目（否则 override 被忽略）。6 口井继承 base 的 `site_id="well"` 合多锚点、`stove@hale_bakery`/`mill@millward_mill` 之前已填，均不动。owner_group/access 仍由 `_resolve_workstation_owner_group` 单独解析，与 id 无关。**零行为变化**：id 值不变 → backend `@` 拆显示名、workstation_states 主键、DB 行全部不变。

- **人物 / 地面物品 = 动态 site（2026-06-08，落地；§8.7 / §5.11 / §5.12 从设想变实现）**：「动态静态全用一套逻辑」收口。Godot 在 runtime **动态生成 site_id** 并注册进与静态地点同一个 registry（`TownWorld._anchors_by_id`）：
  - id 约定单一来源：`TownWorld.character_site_id(id)` = `character:<id>`、`ground_item_site_id(item_id)` = `ground_item:<模板 item_id>`。地面物品按模板多锚点（同 6 口井共享 "well"，move wire 本就按模板 itemId 找最近）。
  - 注册 API：`register_dynamic_site(site_id, marker)` / `unregister_dynamic_site(...)` / `nearest_anchor_marker(...)`；marker = 实体场景里的 `SiteMarker` 子节点（随实体移动 = 实时位置 + 半径来源）。动态 site 进 `_anchors_by_id` 但**不进 `_logical_ids`**：不 seed 进 sites 表、不参与地点感知 / move_to_location enum（人物/物品感知与可交互由 CharacterPerception 实时另算）。
  - 生命周期 self-register：`Character.register_world_site()`（NPC runtime `_ready` 调，`_exit_tree` unregister；Player 同）、`GroundItem._register_world_site()`（server-only `_ready`，`_exit_tree` unregister）。全 server-only（client puppet 不跑 AI/nav）。
  - 解析收敛成一条路：`WalkController.resolve_move_to_location_request` 把 characterId/itemId 合成动态 site_id，与静态地点一样走 `has_position` + `get_nearest_position_world`/`nearest_anchor_marker`，**删掉 `_far_character/item/node_target_position` 三个按 group 扫节点的旧 helper**；move-range 守卫（已 near / 超 far）改读该实体 SiteMarker 自己的可见半径（单一来源，不再用 CharacterPerception.*_RADIUS 常量）。
  - **未做（明确边界，非缺陷）**：move wire 仍发 characterId/itemId（= 实体 id，在 Godot 边缘确定性合成 site_id），未折叠成单一 siteId 字段；talk/pickup 仍按实体 id 直接作用于节点（act-on-entity 与 nav-as-site 是不同关切，不强塞进 site nav registry）。

验证：Godot 4.6 headless `--editor --import` 零错误；runtime seed = 65 行（29 location / 19 workstation / 10 farm / 4 container / 3 shelf；well 多锚点 6 anchors），**工作台 site_id fail-loud 全清零**；defId/entityId 仍从本体喂、nameKey/descKey 全空、parent 树正确（treasury_vault parent=treasury / owner=royal_house）；`mapRegistration=global` 恰 26 行（25 location + well），3 个货架均 local（不上玩家地图）；动态 site 注册/反注册无 fail-loud。

## 1. 要解决的问题

当前“地点 / 工作台 / 容器 / 货架 / 农田 / 人物 / 地上物品”几条链路分散维护位置、名字和可交互范围，导致同一个世界对象在不同系统里表现不一致。

已暴露的问题：

- 水井改成 `ContainerNode` 后，附近容器目标走 `containerName("well")`，但 `containers.json` 没有 `well`，于是 prompt / resolver 可能显示或只识别 `well`，不识别“水井”。
- `move_to_location`、`put_take`、`view_container`、craft 工具各自调用不同 resolver，目标名称解析规则不一致。
- `LocationMarker`、`ApproachMarker`、`WorkstationNode.get_approach_node()`、`FarmGroup.get_approach_node()` 各自维护位置锚点，职责重叠。
- 工作台、容器、农田、货架是否出现在城镇地图、周围地点、可交互列表中，隐含依赖实体类型，而不是显式配置。
- 室内 / 室外没有统一空间模型，导致“室外能看到室内灶台 / 人物 / 地上物品”“室内说话被室外听到”等问题难以一致处理。
- 玩家 UI 仍叫 `NavTestPanel` / `前往`，带 debug/test 语义，且不是以 NPC prompt 同源的数据模型呈现地图。

重构目标：

- Godot 统一注册所有可命名、可导航、可交互的世界锚点。
- Backend 只解析一种目标：`site`。
- 玩家地图 UI 和 NPC prompt 使用同一份 site 数据、同一套名字解析、同一套层级和可见规则。
- 城镇地图不再臃肿，只显示注册为全局地图项的 site。
- 局部地点可无限层级，例如“灰石农圃 -> 谷仓（灰石农圃） -> 种子仓库 / 小麦仓库”。

## 2. 核心概念

### 2.1 Site

`Site` 是“可被命名、可被导航 / 感知 / 交互系统寻址的世界锚点”。

Site 不是地点，也不是容器，也不是工作台。它是这些实体面向导航、prompt、地图和工具解析的统一入口。

示例：

```text
well                         // 水井，机制上是 container，地图上是公共地点
tavern                       // 酒馆，真实可到达点，位置是酒馆门口 / 外部锚点
tavern_hall                  // 酒馆大厅，室内 site，不进城镇地图
stove@hale_bakery            // 面包店灶台，机制上是 workstation
treasury_vault               // 国库，机制上是 container
ground_item:abc123           // 地上物品动态 site
character:edda_hale          // 人物动态 site
```

### 2.2 SiteMarker

Godot 中新增 `SiteMarker.gd`：

```gdscript
@tool
class_name SiteMarker
extends Marker3D
```

`SiteMarker` 替代 `ApproachMarker` 和 `LocationMarker`。它本身就是到达点，编辑器里可拖动，可显示 label / 小球，并在运行时注册到 `SiteRegistry`。

静态对象在编辑器里挂 `SiteMarker`：

```text
City_Well (ContainerNode)
  SiteMarker

Smithy_Anvil (WorkstationNode)
  SiteMarker

north_wall_field_1 (FarmGroup)
  SiteMarker

tavern (SiteMarker)              // 纯地点可直接用 SiteMarker 节点
```

人物、地上物品由 Godot 运行时生成动态 site record，或者动态添加等价 `SiteMarker`。

### 2.3 Space

> **已修订（见 §0）**：space 不是 SiteMarker 字段。`SpaceVolume` 挂在室内地点 SiteMarker 下作子节点，site 的 space = 框住其坐标的 volume 所属地点 site_id，没框住 = `town_outdoor`，由 `TownWorld.space_id_at` 注入 `sites.spaceId`。目前未摆任何 volume = 休眠。

`Space` 是室内 / 室外空间分区，用来判断视觉、听觉、交互是否跨空间传播。

新增 `SpaceVolume.gd`：

```gdscript
class_name SpaceVolume
extends Area3D
```

第一版规则简单固定：

```text
同一个 space_id：按距离判断可见 / 可听 / 可交互
不同 space_id，且双方都是 outdoor：按距离判断
不同 space_id，任一方 indoor：不可见、不可听
```

第一版室内外完全隔音、完全遮挡视觉。不做门、窗、开关门、弱传播。未来需要时再引入 `Portal`。

### 2.4 SiteRegistry

`SiteRegistry` 可以先放在 `TownWorld`，但概念上是一个统一 registry。

它负责：

- 注册 / 反注册静态和动态 site。
- 维护 site id 到 `SiteRecord` 的映射。
- 根据 actor 的位置和 `space_id` 判断可见 site。
- 根据 direct interaction range 判断可直接交互 site。
- 向 SQLite seed 静态 site。
- 向 perception manifest 输出 actor 当前能感知到的 site id 和 band。

## 3. SiteRecord 字段

> **已修订（见 §0）**：`mapRegistration` 枚举为 `global | local`（非 `dynamic`）。`SiteMarker` 不含 `defId`/`entityId`（机制本体提供）、不含 `nameKey`/`descriptionKey`（名字按 site_id 查 locations.json）、不含 `spaceId` 字段（几何包含算）。`parentSiteId` 显式 authored，不从层级推。

Godot runtime 和 SQLite 中统一使用下面的字段形状。

```ts
type SiteRecord = {
  id: string;

  entityKind: "location" | "workstation" | "container" | "shelf" | "farm" | "character" | "ground_item";
  entityId: string;
  defId?: string;

  mapRegistration: "global" | "dynamic";
  parentSiteId?: string;
  spaceId: string;

  capabilities: string[];

  // 主锚点（地图坐标 / 单锚点 site 的到达点）。
  posX: number;
  posY: number;
  posZ: number;

  // 多锚点支持（决策：site 保留 anchors 数组）。
  // 同一逻辑 site 可有多个物理到达点：6 口共享 "well" 的水井、市集多入口等。
  // 为空时退化为 [ {posX,posY,posZ} ]；导航取离 actor 最近的 anchor。
  // 持久化：anchors 存为 sites 行的 JSON 列（见 §9），不另开表，保持单一 site 主键。
  anchors?: Array<{ x: number; y: number; z: number }>;

  arrivalRadius: number;
  visibleNearRadius: number;
  visibleFarRadius: number;
  directInteractionRadius: number;

  ownerGroup?: string;
  lockItemId?: string;
  groupGatedCapabilities?: string[];

  zone?: string;
  category?: string;
  sortOrder?: number;

  nameKey?: string;
  descriptionKey?: string;
};
```

### 3.1 `id`

Site 主键。Backend resolver、Godot move、玩家地图点击最终都使用这个 id。

要求稳定、唯一、可长期保存。

示例：

```text
well
tavern
tavern_hall
anvil@blacksmith_shop
stove@hale_bakery
seed_storage@graystone_farmstead
ground_item:abc123
character:edda_hale
```

### 3.2 `entityKind`

背后的机制实体类型。

它只表示“它是什么”，不决定城镇地图显示、不决定层级、不决定是否能被前往。

示例：

```text
well.entityKind = container
stove@hale_bakery.entityKind = workstation
north_wall_field_1.entityKind = farm
tavern.entityKind = location
```

### 3.3 `entityId`

对应机制系统里的实体 id。

示例：

```text
well -> container_states.containerId = well
treasury_vault -> container_states.containerId = treasury_vault
north_wall_field_1 -> farm_states.farmId = north_wall_field_1
edda_hale -> character id
```

### 3.4 `defId`

模板 / 定义 id。

工作台和物品常用：

```text
anvil@blacksmith_shop.defId = anvil
stove@hale_bakery.defId = stove
ground_item:abc123.defId = wood_bucket
```

### 3.5 `mapRegistration`

控制是否注册到城镇地图。

```text
global  -> 进入 # 城镇地图
dynamic -> 不进入 # 城镇地图，但仍是 site，可导航、可感知、可交互、可被 resolver 解析
```

这个字段只决定城镇地图是否显示，不决定层级，不决定能不能移动。

水井是容器，但 `mapRegistration = global`，所以显示在城镇地图。

酒馆大厅 `mapRegistration = dynamic`，所以不显示在城镇地图，但仍可以 `move_to_location("酒馆大厅")`。

### 3.6 `parentSiteId`

Site 层级父节点。只表达结构关系，不决定是否显示在城镇地图。

层级可以无限嵌套：

```text
graystone_farmstead
  granary@graystone_farmstead
    seed_storage@graystone_farmstead
    wheat_storage@graystone_farmstead
```

示例：

```text
stove@hale_bakery.parentSiteId = hale_bakery_interior
tavern_hall.parentSiteId = tavern
seed_storage@graystone_farmstead.parentSiteId = granary@graystone_farmstead
```

### 3.7 `spaceId`

Site 所属空间。

示例：

```text
well.spaceId = town_outdoor
blacksmith_shop.spaceId = town_outdoor
tavern_hall.spaceId = tavern_hall
stove@hale_bakery.spaceId = hale_bakery_interior
```

角色和地上物品的 `spaceId` 由 runtime 根据当前位置更新。

### 3.8 `capabilities`

Site 能力列表。工具根据能力判断目标能否使用，而不是看 `entityKind`。

常用值：

```text
move
container
craft
farm
shop
water_source
pickup
talk
sleep
read
write
```

示例：

```text
well.capabilities = [move, container, water_source]
anvil@blacksmith_shop.capabilities = [move, craft]
bakery_bread_shelf.capabilities = [move, container, shop]
north_wall_field_1.capabilities = [move, farm]
character:edda_hale.capabilities = [move, talk]
ground_item:abc123.capabilities = [move, pickup]
```

### 3.9 位置和范围字段

`posX / posY / posZ` 是 `SiteMarker.global_position`。

`arrivalRadius` 是 `move_to_location` 到达判定范围。

`visibleNearRadius` 是可被看见的 near 范围。

`visibleFarRadius` 是可被看见的 far 范围。

`directInteractionRadius` 是可直接交互范围。

现有范围要收口到这些字段：

```text
地点：visibleNear=10, visibleFar=50
人物：visibleNear=3, visibleFar=10
地上物品：visibleNear=3, visibleFar=10, direct=1
工作台：visibleNear=3, visibleFar=10, direct=1
容器 / 货架：visibleNear=3, visibleFar=10, direct=3
农田：visibleNear=10, visibleFar=30, direct=1.5 或 3
```

### 3.10 `ownerGroup`

归属 group。用于招牌、社会语义、部分权限判断。

规则：

```text
""       -> 继承父 site；root 下为空就是 public
"public" -> 显式公共
其他     -> 具体 group id
```

### 3.11 `lockItemId`

需要钥匙的 site 使用该字段。

示例：

```text
treasury_vault.lockItemId = royal_key
```

### 3.12 `groupGatedCapabilities`

哪些能力真的受 group 硬权限限制。

示例：

```text
north_wall_field_1.groupGatedCapabilities = [farm]
anvil@blacksmith_shop.groupGatedCapabilities = []
```

工作台归属不再默认硬拦 group。

### 3.13 展示字段

`zone` 用于城镇地图分区：

```text
upper_city
lower_city
outer_city
castle
south_outskirts
public
```

`category` 用于展示分类：

```text
civic
commerce
workshop
storage
farm
resource
social
interior
```

`sortOrder` 控制同区排序。

`nameKey` 和 `descriptionKey` 是可选 i18n key。没有时 backend 用统一 resolver 推导名字。

## 4. SpaceVolume 字段

```ts
type SpaceRecord = {
  id: string;
  environment: "outdoor" | "indoor";
  blocksVisionToOtherSpaces: boolean;
  blocksSpeechToOtherSpaces: boolean;
  defaultVisibleNearRadius?: number;
  defaultVisibleFarRadius?: number;
};
```

示例：

```text
town_outdoor.environment = outdoor
tavern_hall.environment = indoor
hale_bakery_interior.environment = indoor
graystone_granary.environment = indoor
```

第一版规则：室内外之间完全不可见、完全不可听。

## 5. 示例配置

### 5.1 水井

```text
id = well
entityKind = container
entityId = well
mapRegistration = global
parentSiteId = ""
spaceId = town_outdoor
capabilities = [move, container, water_source]
visibleNearRadius = 10
visibleFarRadius = 50
directInteractionRadius = 3
arrivalRadius = 1
zone = public
category = civic
nameKey = location.well.alias
descriptionKey = location.well.description
```

水井机制上是容器，但因为 `mapRegistration = global`，所以它显示在城镇地图。

### 5.2 酒馆

```text
id = tavern
entityKind = location
entityId = tavern
mapRegistration = global
parentSiteId = ""
spaceId = town_outdoor
capabilities = [move]
visibleNearRadius = 10
visibleFarRadius = 50
arrivalRadius = 3
zone = lower_city
category = social
```

`tavern` 不是抽象父节点。它是实际可到达的酒馆门口 / 外部锚点。

### 5.3 酒馆大厅

```text
id = tavern_hall
entityKind = location
entityId = tavern_hall
mapRegistration = dynamic
parentSiteId = tavern
spaceId = tavern_hall
capabilities = [move]
visibleNearRadius = 10
visibleFarRadius = 10
arrivalRadius = 2
category = interior
```

`move_to_location("酒馆大厅")` 可以直接解析并前往。它不显示在城镇地图，因为 `mapRegistration = dynamic`。

### 5.4 酒馆灶台

```text
id = stove@tavern
entityKind = workstation
entityId = stove@tavern
defId = stove
mapRegistration = dynamic
parentSiteId = tavern_hall
spaceId = tavern_hall
capabilities = [move, craft]
visibleNearRadius = 3
visibleFarRadius = 10
directInteractionRadius = 1
arrivalRadius = 1
```

### 5.5 面包店

```text
id = hale_bakery
entityKind = location
entityId = hale_bakery
mapRegistration = global
spaceId = town_outdoor
capabilities = [move]
zone = upper_city
category = commerce
```

### 5.6 面包店室内

```text
id = hale_bakery_interior
entityKind = location
entityId = hale_bakery_interior
mapRegistration = dynamic
parentSiteId = hale_bakery
spaceId = hale_bakery_interior
capabilities = [move]
```

### 5.7 面包店灶台

```text
id = stove@hale_bakery
entityKind = workstation
entityId = stove@hale_bakery
defId = stove
mapRegistration = dynamic
parentSiteId = hale_bakery_interior
spaceId = hale_bakery_interior
capabilities = [move, craft]
```

室外角色看不到这个灶台，也看不到室内人物和室内地上物品。

### 5.8 铁匠铺

```text
id = blacksmith_shop
entityKind = location
entityId = blacksmith_shop
mapRegistration = global
spaceId = town_outdoor
capabilities = [move]
zone = upper_city
category = workshop
```

铁匠铺只有室外，不拆室内 / 门口。

### 5.9 铁砧（巴克利铁匠铺）

```text
id = anvil@blacksmith_shop
entityKind = workstation
entityId = anvil@blacksmith_shop
defId = anvil
mapRegistration = dynamic
parentSiteId = blacksmith_shop
spaceId = town_outdoor
capabilities = [move, craft]
ownerGroup = blacksmith_shop
groupGatedCapabilities = []
```

### 5.10 灰石农圃 -> 谷仓 -> 仓库

```text
id = graystone_farmstead
entityKind = location
entityId = graystone_farmstead
mapRegistration = global
spaceId = town_outdoor
capabilities = [move]
zone = outer_city
category = farm
```

```text
id = granary@graystone_farmstead
entityKind = location
entityId = granary@graystone_farmstead
mapRegistration = dynamic
parentSiteId = graystone_farmstead
spaceId = graystone_granary
capabilities = [move]
category = storage
```

```text
id = seed_storage@graystone_farmstead
entityKind = container
entityId = seed_storage@graystone_farmstead
mapRegistration = dynamic
parentSiteId = granary@graystone_farmstead
spaceId = graystone_granary
capabilities = [move, container]
category = storage
```

```text
id = wheat_storage@graystone_farmstead
entityKind = container
entityId = wheat_storage@graystone_farmstead
mapRegistration = dynamic
parentSiteId = granary@graystone_farmstead
spaceId = graystone_granary
capabilities = [move, container]
category = storage
```

### 5.11 人物动态 site

```text
id = character:edda_hale
entityKind = character
entityId = edda_hale
mapRegistration = dynamic
spaceId = runtime_current_space
capabilities = [move, talk]
visibleNearRadius = 3
visibleFarRadius = 10
```

### 5.12 地上物品动态 site

```text
id = ground_item:abc123
entityKind = ground_item
entityId = abc123
defId = wood_bucket
mapRegistration = dynamic
spaceId = runtime_current_space
capabilities = [move, pickup]
visibleNearRadius = 3
visibleFarRadius = 10
directInteractionRadius = 1
arrivalRadius = 1
```

## 6. Prompt 和玩家地图规则

### 6.1 城镇地图

城镇地图只遍历：

```text
mapRegistration = global
```

不递归显示 dynamic 子节点。

示例输出只包含：

```text
酒馆
黑尔面包店
灰石农圃
水井
铁匠铺
```

不显示：

```text
酒馆大厅
面包店室内
灶台
谷仓
种子仓库
小麦仓库
```

### 6.2 动态上下文

动态上下文根据 actor 当前空间、距离、层级关系和可见规则展开。

原则：

```text
同空间可见 site 按 visible radius 出现
室内外互相不可见
到达某个 global site 后，可以显示它的 dynamic 子节点
进入某个 dynamic site 后，可以继续显示它的子节点
```

### 6.3 可交互列表

可交互列表来自可见 site，并按 `capabilities` 显示可用工具。

示例：

```text
capabilities includes container -> put_take / view_container
capabilities includes craft -> 对应 craft axis 工具
capabilities includes farm -> plan_farm_work
capabilities includes shop -> 货架商品和标价
```

### 6.4 玩家地图 UI

玩家地图 UI 必须和 NPC prompt 同源。

当前 `NavTestPanel` 是调试面板，计划正式迁移为地图面板。

命名迁移：

```text
NavTestPanel -> MapPanel 或 TownMapPanel
src/ui/dev/nav_test_panel.gd -> src/ui/map/map_panel.gd
src/ui/dev/nav_test_panel.tscn -> src/ui/map/map_panel.tscn
NAV_TEST_PANEL_SCENE -> MAP_PANEL_SCENE
_nav_test_panel -> _map_panel
request_test_move_to -> request_map_move_to 或 request_move_to_site
ui.nav_test.* -> ui.map.*
```

文案迁移：

```text
📍 前往 ▼ -> 地图 ▼
📍 前往 ▲ -> 地图 ▲
```

去除 UI、类名、文件路径、注释、日志中的 debug/test 说法。

地图面板分区应和 NPC prompt 对齐：

```text
全城地点：mapRegistration=global
周围地点：当前可见 dynamic/global site
可交互地点：当前可见且有 capability 的 site
```

点击地图条目走正式 site move，不走 test move：

```gdscript
request_move_to_site(site_id)
```

## 7. Backend 统一 resolver

新增统一 `SiteResolver`。

核心函数：

```ts
siteDisplayName(site: SiteContext): string
siteDescription(site: SiteContext): string | undefined
resolveSiteByName(name: string, context: AgentCurrentContext, opts?: { capability?: string }): SiteContext | undefined
```

名字解析顺序：

```text
1. site.nameKey
2. site id 对应显式 site catalog
3. location.<siteId>.alias
4. workstation.<defId>.name + owner suffix
5. container.<entityId>.name
6. item / character display name for dynamic site
7. siteId fallback
```

所有工具都用同一个入口：

```text
move_to_location -> resolveSiteByName(name, capability=move)
put_take -> resolveSiteByName(name, capability=container)
view_container -> resolveSiteByName(name, capability=container)
smith/cook/... -> resolveSiteByName(name, capability=craft + axis filter)
plan_farm_work -> resolveSiteByName(name, capability=farm)
```

需要删除或内联旧入口：

```text
resolveNavigableSiteIdByName
resolveContainerOrShelfTarget
resolvePlanFarm 的独立名字链
workstation-only navigation fallback
container-only target parsing
```

## 8. Godot 实施计划

### 8.1 新增 `SiteMarker.gd`

功能：

```text
编辑器可视化小球和 label
导出 SiteRecord 字段
to_site_record()
is_visible_to(actor)
is_directly_interactable(actor)
is_arrived(actor)
运行时注册 / 反注册到 SiteRegistry
```

### 8.2 新增 `SpaceVolume.gd`

功能：

```text
编辑器配置 space_id / environment
运行时判断 actor / item / site 当前所属 space
提供 vision / speech cross-space 判断
```

第一版不做 portal。

### 8.3 重构 `TownWorld` 为 SiteRegistry

替换旧字段：

```text
_anchors_by_id
_parent_location_by_id
_child_locations_by_id
_top_level_location_ids
_logical_ids
_workstation_location_ids
_owner_group_by_id
```

新字段：

```text
_sites_by_id
_site_children_by_id
_site_anchors_by_id
_global_map_site_ids
_dynamic_site_ids
_nav_only_site_ids
_spaces_by_id
```

核心 API：

```gdscript
register_site(marker: SiteMarker)
unregister_site(marker: SiteMarker)
has_site(site_id: String) -> bool
site_record(site_id: String) -> Dictionary
site_position(site_id: String, from: Vector3) -> Vector3
site_arrival_radius(site_id: String) -> float
global_map_site_ids() -> PackedStringArray
visible_site_refs_for(actor: Character) -> Array
interactive_site_refs_for(actor: Character) -> Array
resolve_site_id(name_or_id: String) -> String
```

### 8.4 删除 `ApproachMarker`

所有 `Approach` 节点迁成 `SiteMarker`。

旧调用：

```gdscript
get_approach_node()
```

新调用：

```gdscript
get_site_marker()
site_marker.global_position
site_marker.arrival_radius
site_marker.direct_interaction_radius
```

涉及：

```text
WorkstationNode
ContainerNode
ShelfNode
FarmGroup
WorkstationActionRunner
Containers
TownWorld seed
CharacterPerception
WalkController
```

### 8.5 删除 `LocationMarker`

`Positions/*` 下的地点节点迁成 `SiteMarker`。

旧字段迁移：

```text
location_id -> site_id
owner_group -> ownerGroup
hide_at_runtime -> SiteMarker visual/editor flag
```

### 8.6 机制节点瘦身

`WorkstationNode` 只保留工作台机制：

```text
workstation_id
lock_item_id
verbs / interaction_mode from .tres
busy / concurrency
```

`ContainerNode` 只保留容器机制：

```text
slot_count
passive_tags
infinite_content
```

`FarmGroup` 只保留农田机制：

```text
farm_id
moisture
pest
slots
```

位置、层级、地图、空间、范围全部交给 `SiteMarker`。

### 8.7 动态 site

人物和地上物品在 runtime 生成动态 site record。

它们不进入城镇地图，但进入统一 resolver 和感知系统。

## 9. DB 实施计划

> **建表归属（修正）**：`sites` 是 game-world 表，由 **Godot `src/autoload/db.gd` 的 `_GAME_WORLD_SCHEMA` 建表并 seed**，和 `location_markers`/`farm_states` 同源。Backend 只读写、不 `CREATE`（见架构约定「Backend 不是 game DB schema owner」）。第 11 节的 `site-repo.ts` 只能是只读访问层。
>
> **多锚点列（修正）**：`anchors` 存为单个 JSON 列（`anchorsJson TEXT`），不另开表，保持 `(townId, siteId)` 单主键。`posX/Y/Z` 仍存主锚点（地图坐标）；`anchorsJson` 为空时退化为只用主锚点。

新增 `sites` 表，替代 `location_markers`：

```sql
CREATE TABLE IF NOT EXISTS sites (
  townId TEXT NOT NULL,
  siteId TEXT NOT NULL,
  entityKind TEXT NOT NULL,
  entityId TEXT NOT NULL,
  defId TEXT,
  mapRegistration TEXT NOT NULL,
  parentSiteId TEXT,
  spaceId TEXT NOT NULL,
  ownerGroup TEXT,
  posX REAL NOT NULL,
  posY REAL NOT NULL,
  posZ REAL NOT NULL,
  arrivalRadius REAL NOT NULL,
  visibleNearRadius REAL NOT NULL,
  visibleFarRadius REAL NOT NULL,
  directInteractionRadius REAL NOT NULL,
  capabilities TEXT NOT NULL,
  anchorsJson TEXT,
  zone TEXT,
  category TEXT,
  sortOrder INTEGER NOT NULL DEFAULT 0,
  nameKey TEXT,
  descriptionKey TEXT,
  lockItemId TEXT,
  groupGatedCapabilities TEXT,
  updatedAt TEXT NOT NULL,
  PRIMARY KEY (townId, siteId)
)
```

新增 `spaces` 表可选。第一版也可以只在 Godot 内存里维护 space，manifest 输出时只传已经过滤后的结果。

机制状态表保留：

```text
workstation_states
container_states
shelves
farm_states
item_instances
character_states
```

这些表不再负责导航、名字、层级、地图注册。

## 10. Protocol / manifest 计划

Perception manifest 从按实体分组改为 site refs 为主。

建议新增：

```ts
type SiteRef = {
  id: string;
  band: "near" | "far" | "direct";
};

type PerceptionManifestPayload = {
  knownSiteIds: string[];
  perceivedSites: SiteRef[];
  dynamicSites: SiteRecord[];
  currentSiteId: string;
  currentSpaceId: string;
};
```

机制详情仍按 id SELECT：

```text
entityKind=container -> container_states
entityKind=workstation -> workstation_states
entityKind=farm -> farm_states
entityKind=shelf -> shelves
```

`move_to_location` wire 建议从 `locationId` 改成 `siteId`：

```ts
type MoveToLocationTarget =
  | { siteId: string }
  | { characterId: string }
  | { itemId: string };
```

如果要保留字段兼容，会继续制造歧义。彻底重构建议直接改名。

## 11. Backend 实施计划

新增：

```text
backend/src/services/world-state/site-repo.ts
backend/src/agent-shared/name-resolver/site.ts
backend/src/agent-shared/prompt-context/site-assembler.ts
```

重构：

```text
assemble-from-manifest.ts -> 以 SiteContext 为中心组装
sections.ts -> 城镇地图、周围地点、可交互列表从 site 渲染
targets.ts -> 所有 target resolver 走 resolveSiteByName
tool-factories.ts -> move / put_take / craft / farm 全部传 siteId / entityRef
```

逐步删除：

```text
location-repo.ts 对 location_markers 的依赖
containerName-only target resolver
workstationName-only target resolver
resolveNavigableSiteIdByName
backend/data/town/locations.json 作为地图结构真值的角色
```

`backend/data/town/locations.json` 可以保留为历史文案 / 迁移输入，但最终地图结构真值来自 `sites`。

## 12. 玩家 UI 实施计划

玩家 UI 与 NPC prompt 同源。

迁移：

```text
src/ui/dev/nav_test_panel.gd -> src/ui/map/map_panel.gd
src/ui/dev/nav_test_panel.tscn -> src/ui/map/map_panel.tscn
NavTestPanel -> MapPanel
NAV_TEST_PANEL_SCENE -> MAP_PANEL_SCENE
_nav_test_panel -> _map_panel
request_test_move_to -> request_move_to_site
ui.nav_test.* -> ui.map.*
```

文案：

```json
"map": {
  "toggle": "地图 ▼",
  "toggle_open": "地图 ▲",
  "global": "全城地点",
  "nearby": "周围地点",
  "interactive": "可交互地点"
}
```

去除 debug/test/nav_test 说法。

地图面板展示：

```text
全城地点：mapRegistration=global
周围地点：当前可见 dynamic/global site
可交互地点：当前可见且有 capability 的 site
```

玩家点击条目触发：

```gdscript
request_move_to_site(site_id)
```

不再走测试语义。

## 13. 分阶段落地

### Phase 1: 类型和文档落地

- 新增 `SiteMarker.gd` 和 `SpaceVolume.gd`，暂不接入所有逻辑。
- 定义 `SiteRecord` / `SpaceRecord` TS 类型。
- 新增 `sites` 表 schema 和 repo 草稿。

### Phase 2: 场景锚点迁移

- 批量把 `Approach` 改为 `SiteMarker`。
- 批量把 `LocationMarker` 改为 `SiteMarker`。
- 给水井、容器、工作台、农田、货架补全 site 字段。
- 删除 `ApproachMarker` 和 `LocationMarker` 运行时路径。

### Phase 3: Godot registry 和感知

- `TownWorld` 改为统一 `SiteRegistry`。
- `CharacterPerception` 改为按 site + space + range 产出 manifest。
- `WalkController` 改为按 `siteId` 移动。
- 说话受 `SpaceVolume` 遮挡影响。

### Phase 4: Backend site assembly

- Backend 读取 `sites`。
- `AgentCurrentContext` 以 `SiteContext` 为中心。
- 城镇地图、周围地点、可交互列表全部由 site 渲染。

### Phase 5: Resolver 收口

- 所有工具目标解析改为 `resolveSiteByName`。
- `move_to_location`、`put_take`、`view_container`、craft、farm 使用 capability filter。
- 删除旧 resolver 分支。

### Phase 6: 玩家地图 UI 正式化

- `NavTestPanel` 改为 `MapPanel`。
- 文案改“地图”。
- 去除 debug/test 命名。
- UI 展示与 NPC prompt 同源。

### Phase 7: 清理旧表和旧数据源

- 停用 `location_markers`。
- 停用 `backend/data/town/locations.json` 的结构真值角色。
- 清理旧注释、fallback、兼容字段。

## 14. 验证用例

必须覆盖：

```text
# 城镇地图 只显示 mapRegistration=global 的 site
酒馆大厅 不出现在城镇地图，但 move_to_location("酒馆大厅") 成功
水井 出现在城镇地图，且 put_take(from.container="水井") 命中同一个 site
面包店室外看不到室内灶台 / 室内人物 / 室内地上物品
室内说话室外听不到，室外说话室内听不到
铁匠铺是室外，室外角色能看到铁砧 / 熔炉 / 工作台
灰石农圃 -> 谷仓 -> 种子仓库 / 小麦仓库 层级能逐级展开
move_to_location("铁砧（巴克利铁匠铺）") 命中 anvil@blacksmith_shop
smith(workstation="铁砧（巴克利铁匠铺）") 命中同一个 site
view_container("领主国库") 命中 treasury_vault
plan_farm_work("北墙麦圃1号农田") 命中 farm site
地上物品在室内时室外不可见，在室外时远处可作为移动目标
玩家地图 UI 和 NPC prompt 的全城地点 / 周围地点 / 可交互地点一致
玩家地图 UI 不再出现 debug/test/nav_test 文案
```

## 15. 风险和注意事项

最大风险是场景迁移量大。必须作为一次破坏性重构做彻底，不能保留 `ApproachMarker fallback` 或 `LocationMarker fallback`，否则会再次变成两套系统并存。

需要特别注意：

- `.tscn` 批量迁移要可审查，避免丢失原 `Approach.transform`。
- `siteId` 必须稳定，不能依赖可变 node name。
- 室内外遮挡由 Godot 权威判断，backend 不复算。
- `mapRegistration=dynamic` 不表示运行时动态生成，只表示不进城镇地图。
- 人物和地上物品是 runtime dynamic site，不写静态 `sites` 表。
- 玩家 UI 是正式地图，不是 debug 面板。
- `entityKind` 不决定地图展示，`mapRegistration` 才决定是否进城镇地图。
- `parentSiteId` 不决定地图展示，只决定层级。
