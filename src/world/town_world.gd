@tool
class_name TownWorld
extends Node3D

# 运行时的镇 root：持有 RegionMap，给 NPC/系统提供 region lookup。
# 后期会发 EventBus signal（region_entered / region_changed）。

@export var region_map: RegionMap
@export var positions_root: Node3D
# 途径点容器：下面的 Marker3D 仅供 LocationCorridorPlanner 当补充跳点用，
# 不会进入 backend agent context（位置 / nearest / visible 都不会暴露）。
@export var waypoints_root: Node3D

# logical_id -> Array[Node3D]。Positions 下每个 Marker3D 都是一个 logical location；
# 父子关系来自场景树，用于裁剪 agent context：默认只暴露顶层地点，抵达某个
# 顶层地点附近后才暴露它的子地点。
# 公用 WorkstationNode（owner_group == ""）也作为 Node3D anchor 写进来，当顶层地点。
var _anchors_by_id: Dictionary = {}
var _parent_location_by_id: Dictionary = {}
var _child_locations_by_id: Dictionary = {}
var _top_level_location_ids: PackedStringArray = PackedStringArray()
var _logical_ids: PackedStringArray = PackedStringArray()
# 城镇地图（玩家 MapPanel）专用：仅 WorldObjectIdentity.map_registration=="global" 的 object。
# 是 _logical_ids（NPC move 全集）的真子集——工作台/容器/货架/田块都是 local，不进城镇地图。
# 注册时按 identity.map_registration 收集（见 _register_* 各处）。
var _global_map_site_ids: PackedStringArray = PackedStringArray()
# nav-only waypoint id 集；锚点本身仍写入 _anchors_by_id。LocationGraph 会同时使用
# 这些 waypoint 和 _logical_ids；backend context 仍只暴露 logical location。
var _nav_only_ids: PackedStringArray = PackedStringArray()
# 运行时动态 site id 集（人物 / 地面物品）。锚点写进 _anchors_by_id，与静态地点共用
# has_position / get_nearest_position_world / resolve_location_id 同一套解析逻辑——
# 「动态静态一套逻辑」就靠这个。不进 _logical_ids：动态 site 不 seed 进 sites 表、不参与
# 地点感知与 move_to_location enum（人物/物品的感知与可交互由 CharacterPerception 实时另算）。
var _dynamic_site_ids: Dictionary = {}
var _object_def_by_id: Dictionary = {}
# 公用工作台 location id -> display_name（中文别名），给 location_alias() 反查用。
var _workstation_aliases: Dictionary = {}
# location id -> true。只要某个 logical location 挂了 WorkstationNode anchor，就按工作台语义
# 处理（例如 well 既有普通地点 marker，又有工作台交互点）。
var _workstation_location_ids: Dictionary = {}
# location id -> 归属 group（"" = public）。注册时 WorldObjectIdentity.owner_group 经过继承解析。
# 仅供 access 校验使用；visibility 由 perceived_position_names_for 按距离决定，不查此表。
var _owner_group_by_id: Dictionary = {}
# site id -> {"kind": String, "node": Node}。kind ∈ location/workstation/container/shelf/farm。
# node 是机制节点（WorkstationNode/ContainerNode/ShelfNode/FarmGroup）或 location SiteMarker，
# 供 _seed_sites_to_db 合成 SiteRecord（机制字段真值留在机制节点，registry 只读不复制）。
# 同 id 多次注册（公共工作台合并）以首次为准。
var _site_meta_by_id: Dictionary = {}
# 场景里所有 SpaceVolume，boot 时收集一次。空 = 没有室内外分区，感知全按距离（旧行为）。
var _space_volumes: Array = []

# 预 bake 的可达图，启动后由 _bake_location_graph_async 填充。bake 完成前
# LocationCorridorPlanner 退化成"直接 target"，跟旧版"map 没 ready"行为一致。
var location_graph: LocationGraph


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		add_to_group("town_world")


func _ready() -> void:
	_resolve_positions_root()
	_resolve_waypoints_root()
	_rebuild_anchor_index()
	if Engine.is_editor_hint():
		return
	if region_map == null:
		push_error("[TownWorld] region_map not assigned")
		return
	# Region/Location 图都只服务于 server 上的 NPC AI、context snapshot、寻路；
	# client 只渲染 MultiplayerSynchronizer 推回来的状态，bake 是纯浪费 + 开局
	# 几秒主线程卡顿（n*(n-1)/2 次 navmesh query）。
	if not RunMode.is_runtime():
		return
	if region_map.cell_region.is_empty():
		push_warning("[TownWorld] region_map not baked; baking now (run-time fallback)")
		region_map.bake()
	_collect_space_volumes()
	_seed_workstation_states_to_db()
	_seed_container_states_to_db()
	_seed_shelf_states_to_db()
	_seed_location_markers_to_db()
	_seed_sites_to_db()
	_seed_item_defs_to_db()
	_seed_farm_static_to_db()
	_seed_initial_crops_to_db()
	_bake_location_graph_async()


# 把场景里 WorkstationNode 的静态配置写进 Db.workstation_states，给 backend perception 用。
# 幂等：每次 server 启动都全量覆盖。运行时占用（currentOperatorId / busy）由
# WorkstationActionRunner 在 start/stop 时单独 UPSERT，不在此处。
func _seed_workstation_states_to_db() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# 崩溃恢复：上次 server 异常退出可能留下 busy=1 / currentOperatorId 行，
	# 而本次启动 WorkstationNode 全部空闲——seed 前先清零保持镜像一致。
	Db.clear_all_workstation_operators()
	var nodes := scene.find_children("*", "WorkstationNode", true, false)
	# workstation_states / perception manifest 的主键 = 复合逻辑 id（workstation_logical_id），
	# 与 _register_workstations 的 anchor id 同源。绝不再用 node.name —— 实例化工作台默认沿用
	# 场景根名（如 4 个 StoveWorkstationNode），跨铺子必然重名，后 seed 的行会覆盖前者，
	# backend 按 id 反查就拿到错铺子的 owner（曾让巴克利熔炉显示成"霍洛锻造场"）。
	# 复合 id 含 owner_group，结构上保证有主工作台唯一；公共工作台（无 group）按 def 合并是预期行为。
	var seen_ids := {}
	for n in nodes:
		var ws := n as WorkstationNode
		if ws == null:
			continue
		# 容器是 WorkstationNode 子类，但持久化到独立的 container_states 表（含 items）。
		# Backend 拼 nearbyWorkstations 时从两张表合并，避免一行写两份。
		if ws is ContainerNode:
			continue
		var node_id := workstation_logical_id(ws)
		# 有主工作台（id 含 "@"）撞 id = 同一 group 里放了两台同类工作台，多半是内容错误，fail loud；
		# 公共工作台（无 "@"，如多口水井）撞 id 是合并语义，静默。
		if seen_ids.has(node_id) and node_id.contains("@"):
			push_error("[TownWorld] 工作台复合 id '%s' 重复（%s 与 %s）；同 group 内同类工作台会互相覆盖" % [
				node_id, seen_ids[node_id], ws.get_path(),
			])
		seen_ids[node_id] = ws.get_path()
		var def_id := ws.world_object_def_id()
		var location_id := node_id
		# posX = SiteMarker 组件自身位置（= 本体原点 = 可交互基准）；NPC 寻路点在 sites.anchorsJson 单列。
		var pos := ws.get_site_marker().global_position
		var ws_def: Workstation = Workstations.by_id(def_id) if not def_id.is_empty() else null
		var verbs: Array = []
		var mode: String = ""
		var slot_count: int = 0
		if ws_def != null:
			for v in ws_def.verbs:
				verbs.append(String(v))
			mode = ws_def.interaction_mode
			slot_count = ws_def.slot_count
		Db.save_workstation_state(node_id, {
			"workstationDefId": def_id,
			"locationId": location_id,
			"ownerGroup": _resolve_workstation_owner_group(ws),
			"posX": pos.x,
			"posY": pos.y,
			"posZ": pos.z,
			"interactionMode": mode,
			"slotCount": slot_count,
			"verbs": verbs,
			"busy": false,
		})


# 把场景里可储物的 WorkstationNode/ContainerNode 静态配置写进 Db.container_states，给 backend perception 用。
# 幂等：每次 server 启动都全量覆盖。内容物在 item_instances 表（ownerKind='container'），不在此处。
func _seed_container_states_to_db() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var nodes := scene.find_children("*", "WorkstationNode", true, false)
	for n in nodes:
		var c := n as WorkstationNode
		if c == null:
			continue
		# 货架是 ContainerNode 子类，但额外写进 shelves 表（标记 + 命名）。这里跳过，避免
		# 同一个 id 既出现在 container_states 又出现在 shelves，被 backend 重复渲染。
		if c is ShelfNode:
			continue
		var cid := c.effective_container_id()
		if cid.is_empty():
			continue
		var pos := c.global_position
		Db.save_container_state(cid, {
			"lockItemId": c.world_object_lock_item_id(),
			"ownerGroup": _resolve_workstation_owner_group(c),
			"slotCount": c.slot_count,
			"interactionRadius": SiteMarker.interaction_radius_of(c),
			"posX": pos.x,
			"posY": pos.y,
			"posZ": pos.z,
		})


# 把场景里 ShelfNode 的静态配置写进 Db.shelves，给 backend perception 用。
# 幂等：每次 server 启动都全量覆盖。内容物在 item_instances(ownerKind='container')，标价在槽位
# listingPriceCenti，不在此处。posX = SiteMarker 组件自身位置（= 可交互基准）。
func _seed_shelf_states_to_db() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var nodes := scene.find_children("*", "ShelfNode", true, false)
	for n in nodes:
		var s := n as ShelfNode
		if s == null:
			continue
		var sid := s.effective_shelf_id()
		if sid.is_empty():
			continue
		var pos := s.get_site_marker().global_position
		Db.save_shelf_state(sid, {
			"ownerGroup": _resolve_workstation_owner_group(s),
			"locationId": s.effective_location_id(),
			"slotCount": s.slot_count,
			"interactionRadius": SiteMarker.interaction_radius_of(s),
			"posX": pos.x,
			"posY": pos.y,
			"posZ": pos.z,
		})


# 把场景里所有 FarmGroup 的静态字段（locationId / totalSlots）写进 Db.farm_states。
# 不动 moisture/pest/lastDay —— 老 DB 有持久化值会保留；空 plot 不影响。
# 让 backend SELECT farm_states 时能拿到 locationId 用于 name resolve + totalSlots 用于"共N格"。
func _seed_farm_static_to_db() -> void:
	# 用 find_children 而不是 group lookup —— 后者依赖 FarmGroup._ready 已跑（add_to_group），
	# 跟 TownWorld._ready 的相对顺序无保证。class 查找在节点 _enter_tree 后即可工作。
	var scene := get_tree().current_scene
	if scene == null:
		return
	for n in scene.find_children("*", "FarmGroup", true, false):
		var farm := n as FarmGroup
		if farm == null:
			continue
		var fid := farm.effective_farm_id()
		if fid.is_empty():
			continue
		Db.seed_farm_static(fid, farm.effective_location_id(), farm.slots().size())


# boot 初始种植：value 是 variety_id → 权重；权重和不必为 1，random pick
# 按归一化概率选。米尔沃德纯小麦；灰石/北墙小麦为主；圣钟草药园混种药草。
const _INITIAL_FARM_PLANTINGS := {
	"north_wall_field_1": {"wheat": 0.7, "tomato": 0.3},
	"north_wall_field_2": {"wheat": 0.7, "tomato": 0.3},
	"north_wall_field_3": {"wheat": 0.7, "tomato": 0.3},
	"greystone_field_1": {"wheat": 0.7, "tomato": 0.3},
	"greystone_field_2": {"wheat": 0.7, "tomato": 0.3},
	"greystone_field_3": {"wheat": 0.7, "tomato": 0.3},
	"millward_field_1": {"wheat": 1.0},
	"millward_field_2": {"wheat": 1.0},
	"saint_bell_field_1": {"mint": 0.30, "mugwort": 0.25, "plantain": 0.25, "ginger": 0.20},
	"saint_bell_field_2": {"calendula": 0.35, "valerian": 0.25, "mint": 0.20, "mugwort": 0.20},
}

# 每 plot 已生长 game-hour 的候选档（用户规约：24h / 48h 随机）。
const _INITIAL_CROP_ELAPSED_HOURS := [24, 48]


# Boot 时给上面这些田写入初始作物。一次性：farm_states.cropsSeeded=1 后不再 seed，
# 玩家收完也不会被刷回去。Variety per-plot 随机（按 _INITIAL_FARM_PLANTINGS 权重混种），
# elapsed hours 整块田统一一次抽取（24 / 48），让同田作物处于相同成熟度。
# spawned_at = now - elapsed，stage 由 Varieties.compute_stage 推算后落盘。
# town.gd._init_runtime → _hydrate_persisted_crops 会读 farm_plots cache 再 spawn 节点。
# 安全网：cropsSeeded=0 但该田已有任意 farm_plots 行（迁移自老存档）→ 只标记，不 seed，
# 避免覆盖玩家手种的作物。
func _seed_initial_crops_to_db() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var farms_by_id: Dictionary = {}
	for n in scene.find_children("*", "FarmGroup", true, false):
		var farm := n as FarmGroup
		if farm == null:
			continue
		farms_by_id[farm.effective_farm_id()] = farm
	var existing_plots := Db.all_farm_plots()
	var current_hour := GameClock.total_game_hours()
	for farm_id in _INITIAL_FARM_PLANTINGS.keys():
		var fid := String(farm_id)
		if Db.farm_crops_seeded(fid):
			continue
		var existing: Dictionary = existing_plots.get(fid, {}) as Dictionary
		if not existing.is_empty():
			# 老存档已有作物：不 seed，但标记 seeded 防下次启动再触发。
			Db.mark_farm_crops_seeded(fid)
			continue
		var farm: FarmGroup = farms_by_id.get(fid) as FarmGroup
		if farm == null:
			push_warning("[TownWorld] seed_initial_crops: farm '%s' not in scene" % fid)
			continue
		var mix: Dictionary = _INITIAL_FARM_PLANTINGS[farm_id]
		var slot_total := farm.slots().size()
		var elapsed := int(_INITIAL_CROP_ELAPSED_HOURS[randi() % _INITIAL_CROP_ELAPSED_HOURS.size()])
		var spawned_at := current_hour - elapsed
		for plot_index in slot_total:
			var variety_id := _pick_weighted_variety_id(mix)
			if variety_id.is_empty():
				continue
			var stage := Varieties.compute_stage(variety_id, spawned_at, current_hour)
			Db.seed_farm_plot(fid, plot_index, {
				"varietyId": variety_id,
				"spawnedAtGameHour": spawned_at,
				"stage": stage,
				"careScoreSum": 0.0,
				"careScoreCount": 0,
				"harvestsDone": 0,
				"hasPest": false,
			})
		Db.mark_farm_crops_seeded(fid)


# 按权重字典 {variety_id: weight} 随机选一个 variety_id。权重和不必为 1。
func _pick_weighted_variety_id(mix: Dictionary) -> String:
	var total := 0.0
	for w in mix.values():
		total += float(w)
	if total <= 0.0:
		return ""
	var roll := randf() * total
	var acc := 0.0
	for k in mix.keys():
		acc += float(mix[k])
		if roll <= acc:
			return String(k)
	return String(mix.keys()[mix.size() - 1])


# 把 Items autoload 的所有 def dump 到 Db.item_defs。
# kind + baseEffects（typed dict）+ staticJson（渲染需要的模板级数值）。
# display 渲染由 backend item-display 模块处理；name 走 i18n catalog。
# staticJson 当前装：
#   capacity        容器型物品（如桶）总容量，给"容量：水 19/20"的 /20 用
#   serving_liters  饮品型物品每份对应的桶装液体升数（如 beer 0.5L/份）
#   max_durability  工具耐久上限，给"耐久 42/50"的 /50 用
#   max_stack       backend 估算堆叠空间用
#   weight          单件重量（kg），给负重展示用
# 新增字段在这里加一行 + backend item-display 读一行即可。
func _seed_item_defs_to_db() -> void:
	for id_v in Items.all_ids():
		var id := String(id_v)
		var item: Item = Items.by_id(id)
		if item == null:
			continue
		# fail-loud：每个物品必须填 weight（kg）。缺值不静默兜底，直接报错暴露漏填的 .tres。
		if item.weight <= 0.0:
			push_error("[item_defs] %s 缺 weight（.tres 必须填 weight > 0）" % id)
		var base_effects: Variant = item.base_effects.duplicate() if not item.base_effects.is_empty() else null
		var static_dict := {
			"max_stack": int(item.max_stack),
			"weight": float(item.weight),
		}
		var capacity := float(item.properties.get("capacity", 0.0))
		if capacity > 0.0:
			static_dict["capacity"] = capacity
		var serving_liters := float(item.properties.get("serving_liters", 0.0))
		if serving_liters > 0.0:
			static_dict["serving_liters"] = serving_liters
		var max_durability := int(item.properties.get("max_durability", 0))
		if max_durability > 0:
			static_dict["max_durability"] = max_durability
		Db.save_item_def(id, {
			"kind": String(item.kind),
			"baseEffects": base_effects,
			"staticJson": static_dict,
		})


# 把已解析的 logical location 写进 Db.location_markers。依赖 _rebuild_anchor_index 已跑完
# （_logical_ids / _owner_group_by_id / _parent_location_by_id / _anchors_by_id 都已填）。
# 首 anchor 的 global_position 当代表点；isWorkstation 用 _workstation_location_ids 判定。
func _seed_location_markers_to_db() -> void:
	for id_v in _logical_ids:
		var id := String(id_v)
		if id.is_empty():
			continue
		var anchors: Array = _anchors_by_id.get(id, [])
		var pos := Vector3.ZERO
		for a_v in anchors:
			var a := a_v as Node3D
			if a != null and is_instance_valid(a):
				pos = a.global_position
				break
		Db.save_location_marker(id, {
			"parentLocationId": parent_location_id(id),
			"ownerGroup": owner_group_for(id),
			"posX": pos.x,
			"posY": pos.y,
			"posZ": pos.z,
			"isWorkstation": bool(_workstation_location_ids.get(id, false)),
		})


# 把所有 logical site 写进统一 sites 表（替代 location_markers 的角色）。机制字段真值留在
# 机制节点：registry 只读 _site_meta_by_id 里登记的节点 + anchor SiteMarker 的展示/空间 override，
# 合成 SiteRecord。anchors 收录该 id 全部物理锚点（多口井 / 多入口）。依赖 _rebuild_anchor_index
# 已跑完。名字不写这里——backend SiteResolver 走 i18n 推导。
func _seed_sites_to_db() -> void:
	for id_v in _logical_ids:
		var id := String(id_v)
		if id.is_empty():
			continue
		var meta: Dictionary = _site_meta_by_id.get(id, {})
		var identity := meta.get("identity", null) as WorldObjectIdentity
		if identity == null:
			push_error("[TownWorld] site '%s' 缺 WorldObjectIdentity，无法播种" % id)
			continue
		var kind := identity.effective_kind()
		var node: Node = meta.get("node", null)
		var marker := _site_marker_for(node)
		if marker == null:
			push_error("[TownWorld] site '%s' 没有 SiteMarker，无法播种（半径/分区/地图全缺）" % id)
			continue
		# anchors = NPC 寻路到达点（approach）；posX/Y/Z = 自身位置（可交互基准）。两者拆开。
		var anchor_positions := all_anchor_positions(id)
		var main_pos: Vector3 = site_self_position(id)
		Db.save_site(id, {
			"entityKind": kind,
			"entityId": _site_entity_id(id, kind, node, identity),
			"defId": identity.effective_def_id(),
			"mapRegistration": _resolve_map_registration(identity, id),
			# parentSiteId 由 WorldObjectIdentity.parent_object_id 提供。
			# 方便 debug；顶层与公共设施留空。
			"parentSiteId": identity.parent_object_id,
			# space = 包含本 site 位置的「室内地点体积」，无则 town_outdoor（见 SpaceVolume）。
			"spaceId": space_id_at(main_pos),
			"capabilities": _site_capabilities(identity, kind, node),
			"anchors": anchor_positions,
			"posX": main_pos.x,
			"posY": main_pos.y,
			"posZ": main_pos.z,
			"arrivalRadius": marker.eff_arrival_radius(),
			"visibleNearRadius": marker.eff_visible_near_radius(),
			"visibleFarRadius": marker.eff_visible_far_radius(),
			"directInteractionRadius": marker.eff_direct_interaction_radius(),
			"ownerGroup": owner_group_for(id),
			"lockItemId": identity.lock_item_id,
			"groupGatedCapabilities": Array(identity.effective_group_gated_capabilities()),
			"zone": identity.zone,
			"category": identity.category,
			"sortOrder": identity.sort_order,
# 名字/描述不落 SiteMarker 字段：backend 永远按 object_id 查 locations.<id>.alias/description。
			"nameKey": "",
			"descriptionKey": "",
		})


# 该 site 承载位置/范围/分区/空间配置的 SiteMarker：location 就是节点本身；机制节点取其
# SiteMarker 子组件（get_site_marker）。取不到返回 null（_seed 处 fail-loud）。
func _site_marker_for(node: Node) -> SiteMarker:
	if node is SiteMarker:
		return node as SiteMarker
	if node != null and node.has_method("get_site_marker"):
		return node.get_site_marker() as SiteMarker
	return null


# map_registration 完全由 WorldObjectIdentity 显式声明（无 auto 推导）。
func _resolve_map_registration(identity: WorldObjectIdentity, id: String) -> String:
	var raw := String(identity.map_registration)
	if raw == "global" or raw == "local":
		return raw
	push_error("[TownWorld] site '%s' map_registration='%s' 非法（只能 global/local）" % [id, raw])
	return "local"


# 注册一个新 site 时收集进城镇地图集（仅 global）。
func _track_global_map_site(identity: WorldObjectIdentity, id: String) -> void:
	if identity != null and _resolve_map_registration(identity, id) == "global":
		_global_map_site_ids.append(id)


func _site_capabilities(identity: WorldObjectIdentity, kind: String, node: Node) -> Array:
	var caps := identity.effective_capabilities()
	if not caps.is_empty():
		var out := Array(caps)
		if kind == "container" and node != null and not String(node.get("infinite_content")).is_empty() and not out.has("water_source"):
			out.append("water_source")
		return out
	match kind:
		"workstation":
			return ["move", "craft"]
		"container":
			var container_caps := ["move", "container"]
			if node != null and not String(node.get("infinite_content")).is_empty():
				container_caps.append("water_source")
			return container_caps
		"shelf":
			return ["move", "container", "shop"]
		"farm":
			return ["move", "farm"]
		_:
			return ["move"]


func _site_entity_id(id: String, kind: String, node: Node, identity: WorldObjectIdentity) -> String:
	if node == null:
		return id
	match kind:
		"container":
			return String(node.call("effective_container_id")) if node.has_method("effective_container_id") else id
		"shelf":
			return String(node.call("effective_shelf_id")) if node.has_method("effective_shelf_id") else id
		"farm":
			return String(node.call("effective_farm_id")) if node.has_method("effective_farm_id") else id
		_:
			return identity.effective_object_id()


# 收集场景里所有 SpaceVolume，缓存供 boot seeding + 每帧感知用。
func _collect_space_volumes() -> void:
	_space_volumes.clear()
	var scene := get_tree().current_scene
	if scene == null:
		return
	for n in scene.find_children("*", "SpaceVolume", true, false):
		var vol := n as SpaceVolume
		if vol != null:
			_space_volumes.append(vol)


# 包含该点的 space id（无匹配 = town_outdoor）。
func space_id_at(point: Vector3) -> String:
	for v in _space_volumes:
		if (v as SpaceVolume).contains_point(point):
			return (v as SpaceVolume).effective_space_id()
	return SpaceVolume.FALLBACK_SPACE_ID


# 包含该点的 space record（无匹配 = 默认室外、不遮挡）。
func space_record_at(point: Vector3) -> Dictionary:
	for v in _space_volumes:
		if (v as SpaceVolume).contains_point(point):
			return (v as SpaceVolume).to_space_record()
	return {
		"id": SpaceVolume.FALLBACK_SPACE_ID,
		"environment": "outdoor",
		"blocksVisionToOtherSpaces": false,
		"blocksSpeechToOtherSpaces": false,
	}


# 两点之间 channel（"vision"/"speech"）能否传播。没有任何 SpaceVolume 时恒 true（旧行为）。
# 室内外遮挡是 Godot 权威，backend 不复算（见 [[feedback_godot_is_authority]]）。
func can_perceive_between(from_p: Vector3, to_p: Vector3, channel: String) -> bool:
	if _space_volumes.is_empty():
		return true
	return SpaceVolume.can_propagate(space_record_at(from_p), space_record_at(to_p), channel)


# 等 NavigationServer 把所有 navmesh tile 注册好后 bake 可达图。
# 仅看 iteration_id > 0 不够：map 刚创建时 id 就 = 1（空 map），polygon 还没注册。
# 改用 canary：跑真实 map_get_closest_point，snap 落到锚点附近才算 ready。
func _bake_location_graph_async() -> void:
	const MAX_WAIT_FRAMES := 1200  # ~20s @60fps 兜底
	const SNAP_TOLERANCE := 5.0   # canary 锚点 snap 后允许的 XZ 偏差
	await get_tree().physics_frame
	# 从一个 NavigationRegion3D 子节点拿真实使用的 map RID。NPC 也是用
	# nav.get_navigation_map() 取，确保两端 RID 一致。
	var sample_region := _find_sample_nav_region()
	if sample_region == null:
		push_warning("[TownWorld] no NavigationRegion3D found; skipping LocationGraph bake")
		return
	var map_rid: RID = sample_region.get_navigation_map()

	# Canary：找一个有锚点的地点，poll map_get_closest_point 直到 snap 落到合理距离内。
	# iteration_id 在 map 刚创建时就 = 1（空 map），稳定计数会被骗；用真实 query 才靠谱。
	var canary_pos: Vector3 = _pick_canary_anchor()
	var waited := 0
	while waited < MAX_WAIT_FRAMES:
		# 先看 iteration_id 至少 ≥ 1 再 query，避免 NavMap 抛"made before first sync"错误
		if NavigationServer3D.map_get_iteration_id(map_rid) > 0:
			NavigationServer3D.map_force_update(map_rid)
			var snap: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, canary_pos)
			var dx: float = abs(snap.x - canary_pos.x)
			var dz: float = abs(snap.z - canary_pos.z)
			if (snap != Vector3.ZERO or canary_pos.is_zero_approx()) and dx < SNAP_TOLERANCE and dz < SNAP_TOLERANCE:
				break
		await get_tree().physics_frame
		waited += 1
	if waited >= MAX_WAIT_FRAMES:
		push_warning("[TownWorld] nav map never serviced canary snap; skipping LocationGraph bake")
		return
	location_graph = LocationGraph.new(self, map_rid)
	var bake_start_msec := Time.get_ticks_msec()
	print("[TownWorld] location graph bake starting (canary waited %d frames)" % waited)
	await location_graph.bake()
	var bake_elapsed_msec := Time.get_ticks_msec() - bake_start_msec
	if location_graph.baked:
		print("[TownWorld] location graph baked: %d nodes in %.2fs" % [location_graph.node_count(), bake_elapsed_msec / 1000.0])
	else:
		push_warning("[TownWorld] location graph bake returned but baked=false after %.2fs" % (bake_elapsed_msec / 1000.0))


# 找第一个 logical id 的第一个 anchor 当 canary。
func _pick_canary_anchor() -> Vector3:
	for id in _logical_ids:
		var anchors := all_anchor_positions(id)
		if not anchors.is_empty():
			return anchors[0]
	return Vector3.ZERO


func _find_sample_nav_region() -> NavigationRegion3D:
	# 找场景里任意一个 NavigationRegion3D，用来取 map RID。
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node == null:
			continue
		if node is NavigationRegion3D:
			return node as NavigationRegion3D
		for child in node.get_children():
			stack.append(child)
	return null


func _resolve_positions_root() -> void:
	if positions_root != null:
		return
	var fallback := get_node_or_null("../Positions") as Node3D
	if fallback == null:
		var parent := get_parent()
		if parent != null:
			fallback = parent.find_child("Positions", false, false) as Node3D
	if fallback == null:
		push_warning("[TownWorld] positions_root not assigned and no sibling 'Positions' node found")
		return
	positions_root = fallback


func _resolve_waypoints_root() -> void:
	if waypoints_root != null:
		return
	var fallback := get_node_or_null("../Waypoints") as Node3D
	if fallback == null:
		var parent := get_parent()
		if parent != null:
			fallback = parent.find_child("Waypoints", false, false) as Node3D
	# 没配也没找到不报错——waypoints 是可选的。
	waypoints_root = fallback


# 把 Positions 下的 Marker3D 场景树当作 location tree。顶层 Marker3D 是大地点；
# 子 Marker3D 是抵达父地点后才可见的局部地点。
# Waypoints 下的 Marker3D 单独建索引，仅作为额外寻路图节点，不进入 backend context。
func _rebuild_anchor_index() -> void:
	_anchors_by_id.clear()
	_parent_location_by_id.clear()
	_child_locations_by_id.clear()
	_top_level_location_ids = PackedStringArray()
	_logical_ids = PackedStringArray()
	_global_map_site_ids = PackedStringArray()
	_nav_only_ids = PackedStringArray()
	_workstation_aliases.clear()
	_workstation_location_ids.clear()
	_owner_group_by_id.clear()
	_site_meta_by_id.clear()
	_object_def_by_id.clear()
	if positions_root != null:
		for child in positions_root.get_children():
			if not (child is Marker3D):
				continue
			_register_location_tree(child as Marker3D, "", "")
	if waypoints_root != null:
		_register_waypoint_subtree(waypoints_root)
	_register_workstations()
	_register_farms()


# 所有 WorkstationNode 都注册为顶层 location（owner_group 仅作归属/招牌元数据）：
# - workstation_id 已有同名地点时，把工作站追加为该地点 anchor（如 well）
# - 否则 location id 用节点名（设计师在 town.tscn 里给的名字，跨实例唯一）
# - alias 用 display_name（中文标签）
# - owner_group 解析见 _resolve_workstation_owner_group：节点字面值为空时从父链上最近的
#   LocationMarker 继承（场景树即真值），无需在每个工作台节点上手填。
# 用 find_children 而不是 get_nodes_in_group：WorkstationNode._ready 顺序与 TownWorld._ready
# 之间没强保证，class 查找在场景实例化后立刻可用，不依赖 _ready 已跑完。
func _register_workstations() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var nodes := scene.find_children("*", "WorkstationNode", true, false)
	for n in nodes:
		var ws := n as WorkstationNode
		if ws == null:
			continue
		var identity := _identity_for_node(ws, "workstation")
		if identity == null:
			continue
		var site_marker := ws.get_site_marker() as SiteMarker
		var resolved_group := _resolve_workstation_owner_group(ws)
		# 逻辑 id 同源走 workstation_logical_id：有主工作台按 owner 拆成独立逻辑地点
		# （id = "<def>@<group>"），公共工作台（owner_group 空，如各处水井）按 def 合并、move 选最近锚点。
		var id := workstation_logical_id(ws)
		# anchor 存 Approach marker 而非 ws 本身：NPC 寻路目标走 marker.global_position，
		# 子类 .tscn 可以 override Approach.transform 把到达点推到工作台 collider 外，
		# 避免本体落在 navmesh 洞里导致 corridor planner unreachable。
		var approach_node: Node3D = ws.get_site_marker()
		if _anchors_by_id.has(id):
			var existing_is_workstation: bool = _workstation_location_ids.get(id, false)
			if not existing_is_workstation:
				push_warning("[TownWorld] workstation '%s' id collides with existing location; skipping" % id)
				continue
			(_anchors_by_id[id] as Array).append(approach_node)
			# 仅公共工作台（resolved_group 空）存通用别名；owned 走烘焙的 location.<id>.alias。
			if resolved_group.is_empty() and not ws.display_name.is_empty() and not _workstation_aliases.has(id):
				_workstation_aliases[id] = ws.display_name
			continue
		_anchors_by_id[id] = [approach_node]
		_workstation_location_ids[id] = true
		var parent_id := identity.parent_object_id.strip_edges()
		_parent_location_by_id[id] = parent_id
		_child_locations_by_id[id] = []
		_logical_ids.append(id)
		_top_level_location_ids.append(id)
		if not parent_id.is_empty():
			_append_child_location(parent_id, id)
		_track_global_map_site(identity, id)
		_owner_group_by_id[id] = resolved_group
		_site_meta_by_id[id] = {"kind": identity.effective_kind(), "node": ws, "identity": identity}
		_object_def_by_id[id] = identity.effective_def_id()
		# owned 工作台（id 形如 "anvil@blacksmith_shop"）不存 _workstation_aliases，显示名走
		# 烘焙进 catalog 的 location.<id>.alias；公共工作台（水井）仍存通用别名供反查。
		if resolved_group.is_empty() and not ws.display_name.is_empty():
			_workstation_aliases[id] = ws.display_name


# 工作台对象 id —— anchor 注册 / workstation_states seed / perception manifest / busy
# 占用镜像四处共用同一函数。唯一来源是 WorldObjectIdentity.object_id。
func workstation_logical_id(ws: WorkstationNode) -> String:
	if ws == null:
		return ""
	return ws.world_object_id()


# WorkstationNode.owner_group 解析（语义对齐 LocationMarker）：
#   ""        → 从父链上最近的 LocationMarker 继承解析后的 owner_group；找不到 = public
#   "public"  → 显式公用，覆盖继承（私有园子里放公用水井等）
#   其他字符串 → 该 group 名
# 依赖 _register_location_tree 已跑完（_owner_group_by_id 对所有 LocationMarker 已填）。
func _resolve_workstation_owner_group(ws: WorkstationNode) -> String:
	var identity := WorldObjectIdentity.for_node(ws)
	var literal := identity.owner_group.strip_edges() if identity != null else ""
	if literal == "public":
		return ""
	if not literal.is_empty():
		return literal
	return ""


# FarmGroup 注册：跟 WorkstationNode 同形——把每片田当成 logical location，
# anchor 存其 SiteMarker 组件（get_site_marker），寻路点由 approach_position() 给（NPC 走
# Approach 而不是 farm origin，origin 常在 plot collider 中央 / 围栏内导致 navmesh 不可达）。
func _register_farms() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var nodes := scene.find_children("*", "FarmGroup", true, false)
	for n in nodes:
		var farm := n as FarmGroup
		if farm == null:
			continue
		var identity := _identity_for_node(farm, "farm")
		if identity == null:
			continue
		var id := farm.effective_location_id()
		if id.is_empty():
			continue
		var site_marker := farm.get_site_marker() as SiteMarker
		var approach_node: Node3D = farm.get_site_marker()
		var resolved_group := _resolve_farm_owner_group(farm)
		if _anchors_by_id.has(id):
			# 已有同 id 注册（典型：迁移期 Positions/.../<farm_id> LocationMarker 还在）。
			# 追加 FarmGroup.Approach 作为新 anchor —— get_nearest_position_world
			# 在 NPC 路径规划时挑最近的，通常 Approach 离 NPC 更近故胜出。
			(_anchors_by_id[id] as Array).append(approach_node)
			continue
		_anchors_by_id[id] = [approach_node]
		var parent_id := identity.parent_object_id.strip_edges()
		_parent_location_by_id[id] = parent_id
		_child_locations_by_id[id] = []
		_logical_ids.append(id)
		_top_level_location_ids.append(id)
		if not parent_id.is_empty():
			_append_child_location(parent_id, id)
		_track_global_map_site(identity, id)
		_owner_group_by_id[id] = resolved_group
		_site_meta_by_id[id] = {"kind": identity.effective_kind(), "node": farm, "identity": identity}
		_object_def_by_id[id] = identity.effective_def_id()


# FarmGroup.owner_group_literal 解析。语义：
#   "public"  → public（空 owner_group）
#   非空       → 该 group id
# Dev 阶段：literal 空必须 push_error —— 不再静默回 public 或继承 LocationMarker，
# 那种 fallback 容易让设计师漏填后表现成"全员可访问"，bug 难定位。
func _resolve_farm_owner_group(farm: FarmGroup) -> String:
	var identity := WorldObjectIdentity.for_node(farm)
	var literal := identity.owner_group.strip_edges() if identity != null else ""
	if literal == "public":
		return ""
	if not literal.is_empty():
		return literal
	push_error("[TownWorld] FarmGroup '%s' WorldObjectIdentity.owner_group 未填；请在 town.tscn 里写 'public' 或 group id（如 'millward_mill'）" % farm.effective_farm_id())
	return ""


# nav-only 图节点（waypoint）注册：扁平进 _anchors_by_id + _nav_only_ids，不建父子、不进
# backend/zone。判据是 SiteMarker.nav_only（语义自带），与节点摆在哪个容器无关。
func _register_nav_only(marker: SiteMarker) -> void:
	var id := String(marker.name)
	if _anchors_by_id.has(id):
		# 同 id 重复注册，追加 anchor。但避免重复进 _nav_only_ids。
		(_anchors_by_id[id] as Array).append(marker)
	else:
		_anchors_by_id[id] = [marker]
		_nav_only_ids.append(id)


# 递归收集 waypoints_root 下所有 nav_only SiteMarker 当 nav-only 图节点。
# 用 subtree 方式而不是只看一级子节点，是为了允许编辑器里按区域分组（比如 "MainRoad" 容器）。
func _register_waypoint_subtree(node: Node) -> void:
	for child in node.get_children():
		var marker := child as SiteMarker
		if marker != null:
			_register_nav_only(marker)
		_register_waypoint_subtree(child)


func _register_location_tree(marker: Marker3D, parent_id: String, parent_group: String) -> void:
	# nav_only SiteMarker 无论摆在哪（含 Positions 下）都按 waypoint 处理：扁平注册、不当 location、
	# 不递归子节点。让 nav_only 标志成为「是不是 waypoint」的唯一真值。
	var nav_marker := marker as SiteMarker
	if nav_marker != null and nav_marker.nav_only:
		_register_nav_only(nav_marker)
		return
	var identity := _identity_for_node(marker, "location")
	if identity == null:
		return
	var id := identity.effective_object_id()
	var explicit_parent_id := identity.parent_object_id.strip_edges()
	var effective_parent_id := explicit_parent_id if not explicit_parent_id.is_empty() else parent_id
	var effective_group := _resolve_owner_group(identity, parent_group)
	var recurse_parent := id
	if _anchors_by_id.has(id):
		# 已注册：仅追加 anchor，不再建独立 location（owner_group 以首次注册为准）
		(_anchors_by_id[id] as Array).append(marker)
	else:
		_anchors_by_id[id] = [marker]
		_parent_location_by_id[id] = effective_parent_id
		_child_locations_by_id[id] = []
		_logical_ids.append(id)
		_owner_group_by_id[id] = effective_group
		_site_meta_by_id[id] = {"kind": identity.effective_kind(), "node": marker, "identity": identity}
		_object_def_by_id[id] = identity.effective_def_id()
		_track_global_map_site(identity, id)
		if effective_parent_id.is_empty():
			_top_level_location_ids.append(id)
		else:
			_append_child_location(effective_parent_id, id)
	for child in marker.get_children():
		if child is Marker3D:
			_register_location_tree(child as Marker3D, recurse_parent, effective_group)


# LocationMarker.owner_group 解析：
#   ""        → 继承父 effective group（root 即 ""）
#   "public"  → 显式公用，覆盖继承
#   其他       → 字面 group 名
# 非 LocationMarker 的普通 Marker3D 没有 owner_group，按"继承父"处理。
func _resolve_owner_group(identity: WorldObjectIdentity, parent_group: String) -> String:
	var literal := identity.owner_group.strip_edges() if identity != null else ""
	if literal == "public":
		return ""
	if literal.is_empty():
		return parent_group
	return literal


func _append_child_location(parent_id: String, child_id: String) -> void:
	var siblings: Array = _child_locations_by_id.get(parent_id, [])
	if not siblings.has(child_id):
		siblings.append(child_id)
	_child_locations_by_id[parent_id] = siblings


func _identity_for_node(node: Node, context: String) -> WorldObjectIdentity:
	var identity := WorldObjectIdentity.for_node(node)
	if identity == null:
		push_error("[TownWorld] %s '%s' 缺 WorldObjectIdentity" % [context, node.get_path()])
		return null
	if not identity.validate_identity(str(node.get_path())):
		return null
	return identity


func region_at_world(p: Vector3) -> MapRegion:
	if region_map == null:
		return null
	return region_map.region_at_world(p)


func region_at_cell(cell: Vector2i) -> MapRegion:
	if region_map == null:
		return null
	return region_map.region_at_cell(cell)


func region_center_world(region_id: String) -> Vector3:
	var points := region_candidate_points_world(region_id)
	if points.is_empty():
		return Vector3.ZERO
	return points[0]


func region_candidate_points_world(region_id: String) -> Array[Vector3]:
	if region_map == null or region_map.grid == null:
		return []

	var found := false
	var min_cell := Vector2i(region_map.grid.width, region_map.grid.depth)
	var max_cell := Vector2i(-1, -1)

	for rect in region_map.rects:
		if rect.region_id != region_id:
			continue
		found = true
		min_cell.x = min(min_cell.x, rect.min.x)
		min_cell.y = min(min_cell.y, rect.min.y)
		max_cell.x = max(max_cell.x, rect.max.x)
		max_cell.y = max(max_cell.y, rect.max.y)

	if not found:
		push_warning("[TownWorld] unknown region id: %s" % region_id)
		return []

	var grid: MapGrid = region_map.grid
	var fractions: Array[float] = [0.5, 0.25, 0.75, 0.1, 0.9]
	var points: Array[Vector3] = []
	for fx in fractions:
		for fz in fractions:
			var cell_x: float = lerp(float(min_cell.x), float(max_cell.x + 1), fx)
			var cell_z: float = lerp(float(min_cell.y), float(max_cell.y + 1), fz)
			points.append(grid.origin + Vector3(cell_x * grid.cell_size, 0.0, cell_z * grid.cell_size))
	return points


func has_region(region_id: String) -> bool:
	if region_map == null:
		return false
	for region in region_map.regions:
		if region.id == region_id:
			return true
	return false


func has_position(position_name: String) -> bool:
	return _anchors_by_id.has(position_name)


func resolve_location_id(location_name: String) -> String:
	var raw := location_name.strip_edges()
	if raw.is_empty():
		return raw
	if has_position(raw) or has_region(raw):
		return raw
	var normalized := raw.to_lower().replace("-", "_").replace(" ", "_")
	if has_position(normalized) or has_region(normalized):
		return normalized
	# 只用已注册 site 的现有显示名反查；不再维护 Godot 端硬编码别名表。
	for location_id in _logical_ids:
		var alias := location_alias(location_id)
		var alias_normalized := alias.strip_edges().to_lower().replace("-", "_").replace(" ", "_")
		if not alias.is_empty() and alias_normalized == normalized:
			return location_id
	return raw


func location_alias(location_id: String) -> String:
	# 有主工作台组合 id "<def>@<group>"：拼成"铁砧（巴克利铁匠铺）"。Godot 与 backend 各在
	# 自己运行时拼（GDScript/TS 没法共享代码）——但都读同一份 workstations/groups i18n
	# catalog、同样的全角括号格式（镜像 backend ownerSuffixedSiteName），与"每个名字本就在
	# 两端各 tr()/t() 一遍"的常态一致。供 debug「前往」面板等显示。见 [[project_town_map_zones]]。
	var at := location_id.find("@")
	if at > 0:
		var ws_name := _i18n_or(("workstation.%s.name" % location_id.substr(0, at)), location_id.substr(0, at))
		var grp_name := _i18n_or(("group.%s.name" % location_id.substr(at + 1)), location_id.substr(at + 1))
		return "%s（%s）" % [ws_name, grp_name]
	if _workstation_aliases.has(location_id):
		return str(_workstation_aliases[location_id])
	var key := "location.%s.alias" % location_id
	var translated := tr(key)
	if translated != key and not translated.is_empty():
		return translated
	return ""


# tr() 查 i18n key，命中返回译文，否则返回 fallback（tr 未命中会原样返回 key）。
func _i18n_or(key: String, fallback: String) -> String:
	var v := tr(key)
	return v if v != key and not v.is_empty() else fallback


func parent_location_id(location_id: String) -> String:
	return str(_parent_location_by_id.get(location_id, ""))


func child_location_ids(location_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	var children: Array = _child_locations_by_id.get(location_id, [])
	for child_id in children:
		out.append(str(child_id))
	return out


func location_root_id(location_id: String) -> String:
	var current := location_id
	while _parent_location_by_id.has(current):
		var parent_id := str(_parent_location_by_id.get(current, ""))
		if parent_id.is_empty():
			return current
		current = parent_id
	return current


# 给定 location_id 返回它继承解析后的 owner_group（"" = public）。
# 农田权限、地点归属展示和工作台招牌共用这份数据，避免重复维护。
func owner_group_for(location_id: String) -> String:
	return str(_owner_group_by_id.get(location_id, ""))


func is_workstation_location(location_name: String) -> bool:
	var resolved := resolve_location_id(location_name)
	return bool(_workstation_location_ids.get(resolved, false))


func location_use_radius(location_name: String, default_radius: float) -> float:
	# 工作台 location 的感知 near-band 收紧到 Containers.INTERACTION_RADIUS（扫描距离常量，
	# 与各 SiteMarker 的 direct_interaction_radius 同值 3.0；非 site 字段兜底）。
	return Containers.INTERACTION_RADIUS if is_workstation_location(location_name) else default_radius


func nearest_location_id(from: Vector3, max_distance: float) -> String:
	var best_id := ""
	var best_distance_sq := max_distance * max_distance
	for location_id in _logical_ids:
		var target := get_nearest_position_world(location_id, from)
		var distance_sq := from.distance_squared_to(target)
		if distance_sq <= best_distance_sq:
			best_distance_sq = distance_sq
			best_id = location_id
	return best_id


func is_position_near(position_name: String, from: Vector3, max_distance: float) -> bool:
	var resolved := resolve_location_id(position_name)
	if not has_position(resolved):
		return false
	return from.distance_to(get_nearest_position_world(resolved, from)) <= max_distance


# 地点可见性 = 纯物理感知，按每个 SiteMarker 自己的 visible_*_radius 过滤。
# fallback far_radius 只给缺 SiteMarker 的旧锚点兜底；正常地点/工作台/农田/货架都吃 prefab 上的范围。
# 不再有"顶层永远可见"bypass：曾经的 bypass 把 FarmGroup / WorkstationNode 全部纳入"地标"，
# 导致 NPC 隔半张地图也能"看到"私人麦圃。NPC 知道哪些地点存在（用于 move_to_location enum）
# 走 known_position_ids() 另一条路径，与感知解耦。
func perceived_position_names_for(self_pos: Vector3, far_radius: float = 50.0) -> PackedStringArray:
	var out := PackedStringArray()
	for location_id in _logical_ids:
		var ref := _perceived_position_ref_for(String(location_id), self_pos, 0.0, far_radius)
		if not ref.is_empty():
			out.append(location_id)
	return out


# Manifest 专用：返回 [{id, band}]，band ∈ {"near", "far"}。
# 超出该 site 的 visible_far_radius 不进列表；visible_near_radius 内归 near 否则归 far。
# near_radius / far_radius 只给缺 SiteMarker 的旧锚点兜底。
func perceived_position_refs_for(self_pos: Vector3, near_radius: float, far_radius: float) -> Array:
	var out := []
	for location_id in _logical_ids:
		var ref := _perceived_position_ref_for(String(location_id), self_pos, near_radius, far_radius)
		if not ref.is_empty():
			out.append(ref)
	return out


func _perceived_position_ref_for(location_id: String, self_pos: Vector3, fallback_near_radius: float, fallback_far_radius: float) -> Dictionary:
	if not _anchors_by_id.has(location_id):
		return {}
	var best_band := ""
	var best_distance_sq := INF
	for anchor_v in _anchors_by_id[location_id]:
		var anchor := anchor_v as Node3D
		if anchor == null:
			continue
		var marker := anchor as SiteMarker
		var target := marker.global_position if marker != null else anchor.global_position
		var far_r := marker.eff_visible_far_radius() if marker != null else fallback_far_radius
		if far_r <= 0.0:
			far_r = fallback_far_radius
		if far_r <= 0.0:
			continue
		var d_sq := self_pos.distance_squared_to(target)
		if d_sq > far_r * far_r:
			continue
		var near_r := marker.eff_visible_near_radius() if marker != null else location_use_radius(location_id, fallback_near_radius)
		if near_r <= 0.0:
			near_r = location_use_radius(location_id, fallback_near_radius)
		var direct_r := marker.eff_direct_interaction_radius() if marker != null else 0.0
		if direct_r > near_r:
			near_r = direct_r
		var band := "near" if near_r > 0.0 and d_sq <= near_r * near_r else "far"
		if band == "near":
			if best_band != "near" or d_sq < best_distance_sq:
				best_band = band
				best_distance_sq = d_sq
		elif best_band.is_empty() or (best_band == "far" and d_sq < best_distance_sq):
			best_band = band
			best_distance_sq = d_sq
	if best_band.is_empty():
		return {}
	return {"id": location_id, "band": best_band}


# "NPC 知道哪些地点存在"——全部 top-level location id（含 LocationMarker 顶层、
# WorkstationNode、FarmGroup）。仅给 manifest.knownLocationIds 用，驱动 backend
# 的 move_to_location enum / visibleLocations alias 表，跟实时感知（距离过滤）解耦。
# 返回拷贝以避免外部误改内部数组。
func known_position_ids() -> PackedStringArray:
	return PackedStringArray(_top_level_location_ids)


# 城镇地图（玩家 MapPanel）用：仅 map_registration=global 的 site（地点 + 水井），
# 不含工作台/容器/货架/田块（那些是 local）。与 known_position_ids（NPC move 全集）区分。
func global_map_site_ids() -> PackedStringArray:
	return PackedStringArray(_global_map_site_ids)


func perceived_location_snapshots_for(self_pos: Vector3, far_radius: float = 50.0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var visible_ids := perceived_position_names_for(self_pos, far_radius)
	for location_id in visible_ids:
		var parent_id := parent_location_id(location_id)
		var children := child_location_ids(location_id)
		var child_id_list: Array[String] = []
		for child_id in children:
			child_id_list.append(str(child_id))
		# ownerGroup 仍随 snapshot 上报，但只用于 access 标记，不影响是否被列出。
		var entry := {
			"id": location_id,
			"alias": location_alias(location_id),
			"parentId": parent_id,
			"ownerGroup": str(_owner_group_by_id.get(location_id, "")),
			"childIds": child_id_list,
		}
		out.append(entry)
	return out


# 父锚点（top-level Marker3D / WorkstationNode 自身）的世界坐标。给不关心选哪个锚点的 caller 用。
func get_position_world(position_name: String) -> Vector3:
	if not _anchors_by_id.has(position_name):
		push_warning("[TownWorld] unknown position: %s" % position_name)
		return Vector3.ZERO
	var anchors: Array = _anchors_by_id[position_name]
	return (anchors[0] as Node3D).global_position


# 锚点的"寻路到达点"：SiteMarker 组件用 approach_position()（可选 Approach 子节点，
# 没有则回退自身位置）。锚点现已全是 SiteMarker（location/workstation/farm/waypoint 同源）；
# 非 SiteMarker = fail-loud（不静默回退自身，否则错配难定位）。
func _anchor_nav_pos(anchor: Node3D) -> Vector3:
	var m := anchor as SiteMarker
	if m == null:
		push_error("[TownWorld] anchor %s 不是 SiteMarker，无法取寻路到达点" % anchor)
		return anchor.global_position
	return m.approach_position()


# 在该 logical id 的所有锚点里挑离 from 最近（按寻路到达点距离）的 SiteMarker。
# 寻路目标点 + arrival_radius 基准都从这同一个锚点取（approach_position / eff_arrival_radius），
# 保证「走去的点」和「到达阈值」来自同一锚点，多锚点站点（井/市集多入口）不会错配。
func nearest_nav_anchor(position_name: String, from: Vector3) -> SiteMarker:
	if not _anchors_by_id.has(position_name):
		return null
	var best: SiteMarker = null
	var best_d := INF
	for a in _anchors_by_id[position_name]:
		var m := a as SiteMarker
		if m == null:
			continue
		var d := from.distance_squared_to(m.approach_position())
		if d < best_d:
			best_d = d
			best = m
	return best


# 在该 logical id 的所有锚点里挑离 from 最近的寻路到达点（世界坐标）。
func get_nearest_position_world(position_name: String, from: Vector3) -> Vector3:
	var m := nearest_nav_anchor(position_name, from)
	if m == null:
		push_warning("[TownWorld] unknown position: %s" % position_name)
		return Vector3.ZERO
	return m.approach_position()


# ── 动态 object（运行时人物 / 地面物品）────────────────────────────────
# 静态 object 在 boot 时由 _rebuild_anchor_index 扫场景注册；人物和地面物品在 runtime spawn，
# 自己调 register_dynamic_site 把 SiteMarker 注册成 anchor、_exit_tree 时 unregister。
# 注册进同一个 _anchors_by_id —— move 解析、最近锚点、has_position 与静态地点完全同一套逻辑，
# 这就是 godot 给动态实体「动态生成 object_id」的落点。id 约定单一来源见下两个静态方法。

# 人物动态 site id：character:<character_id>（1:1，单锚点）。
static func character_site_id(character_id: String) -> String:
	return "character:" + character_id


# 地面物品动态 object id：ground_item:<item_instances.id>。模板 item_id 是 def_id，
# 需要按模板找最近物品时用 nearest_dynamic_object_id_for_def。
static func ground_item_site_id(instance_id: String) -> String:
	return "ground_item:" + instance_id


# 运行时把一个动态实体的 SiteMarker 注册成 site anchor。marker 是实体场景里的 SiteMarker
# 子节点（随实体移动 = 实时位置 + 半径来源）。多锚点：同 site_id 追加锚点。
func register_dynamic_site(site_id: String, marker: SiteMarker) -> void:
	if site_id.is_empty() or marker == null:
		push_error("[TownWorld] register_dynamic_site 参数非法：id='%s' marker=%s" % [site_id, marker])
		return
	var identity := WorldObjectIdentity.for_node(marker)
	if identity == null or identity.effective_object_id() != site_id:
		push_error("[TownWorld] dynamic object '%s' 缺匹配的 WorldObjectIdentity" % site_id)
		return
	if _anchors_by_id.has(site_id):
		var arr: Array = _anchors_by_id[site_id]
		if not arr.has(marker):
			arr.append(marker)
	else:
		_anchors_by_id[site_id] = [marker]
	_dynamic_site_ids[site_id] = true
	_object_def_by_id[site_id] = identity.effective_def_id()


# 反注册：从锚点数组移除该 marker，数组空了删整条 + 出 _dynamic_site_ids。
func unregister_dynamic_site(site_id: String, marker: SiteMarker) -> void:
	if not _anchors_by_id.has(site_id):
		return
	var arr: Array = _anchors_by_id[site_id]
	arr.erase(marker)
	if arr.is_empty():
		_anchors_by_id.erase(site_id)
		_dynamic_site_ids.erase(site_id)
		_object_def_by_id.erase(site_id)
	else:
		_anchors_by_id[site_id] = arr


func is_dynamic_site(site_id: String) -> bool:
	return _dynamic_site_ids.has(site_id)


# 该 site 离 from 最近的锚点 SiteMarker（动态 site move 的 range 守卫读它自己的可见半径，
# 半径单一来源 = 该实体的 SiteMarker，不再散落在 CharacterPerception 常量）。无 = null。
func nearest_anchor_marker(site_id: String, from: Vector3) -> SiteMarker:
	if not _anchors_by_id.has(site_id):
		return null
	var best: SiteMarker = null
	var best_d := INF
	for a in _anchors_by_id[site_id]:
		var m := a as SiteMarker
		if m == null:
			continue
		var d := from.distance_squared_to(m.global_position)
		if d < best_d:
			best_d = d
			best = m
	return best


func nearest_dynamic_object_id_for_def(def_id: String, from: Vector3) -> String:
	var wanted := def_id.strip_edges()
	if wanted.is_empty():
		return ""
	var best_id := ""
	var best_d := INF
	for id_v in _dynamic_site_ids.keys():
		var id := str(id_v)
		if str(_object_def_by_id.get(id, "")) != wanted:
			continue
		var marker := nearest_anchor_marker(id, from)
		if marker == null:
			continue
		var d := from.distance_squared_to(marker.global_position)
		if d < best_d:
			best_d = d
			best_id = id
	return best_id


# 该 logical id 下所有锚点的寻路到达点。LocationGraph bake 用——多 anchor 的地点
# （像 market_square 东西入口）每个 anchor 都要建独立的图节点。
func all_anchor_positions(position_name: String) -> Array:
	var out: Array = []
	if not _anchors_by_id.has(position_name):
		return out
	for anchor in _anchors_by_id[position_name]:
		out.append(_anchor_nav_pos(anchor as Node3D))
	return out


# 该 logical id 的"自身位置"（首个锚点 SiteMarker 自身 global_position，= 可交互基准）。
func site_self_position(position_name: String) -> Vector3:
	if not _anchors_by_id.has(position_name):
		return Vector3.ZERO
	var anchors: Array = _anchors_by_id[position_name]
	if anchors.is_empty():
		return Vector3.ZERO
	return (anchors[0] as Node3D).global_position


func position_names() -> PackedStringArray:
	return _logical_ids


func top_level_position_names() -> PackedStringArray:
	return _top_level_location_ids


# 仅 waypoint id 集（场景树 Waypoints 容器下的 Marker3D）。
func waypoint_ids() -> PackedStringArray:
	return _nav_only_ids


# LocationGraph 使用的图节点：业务 location + nav-only waypoint。waypoint 继续作为
# 设计师补充路网控制点，location 也参与 A*，让地点之间能直接通过图连接。
func navigation_node_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var seen := {}
	for logical_id in _logical_ids:
		var logical_key := str(logical_id)
		if seen.has(logical_key):
			continue
		seen[logical_key] = true
		out.append(logical_key)
	for waypoint_id in _nav_only_ids:
		var waypoint_key := str(waypoint_id)
		if seen.has(waypoint_key):
			continue
		seen[waypoint_key] = true
		out.append(waypoint_key)
	return out
