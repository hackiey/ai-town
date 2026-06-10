class_name CharacterPerception
extends RefCounted

# Character 的"我能看到 / 听到 / 走得到 谁"集合操作收口。所有方法基于
# character.global_position 实时算，不 cache。穿越 npcs / players / world_items /
# farm_groups / workstations 几个 group 节点。
#
# 边界：
# - 本类只做"按距离 / group 过滤的查找 + 上下文 snapshot"，不修改世界状态。
# - lookup helper（other_character_node_by_id / world_item_node_by_id 等）也放这里，
#   Walk / Speech 等模块需要时通过 character.perception() 拿。
# - send_manifest() 是上行入口：把"我此刻感知到的实体 id 集合"推给 backend，backend
#   再按 manifest + SELECT sqlite 拼 LLM context。本帧去重 frame counter 也住这里。

# 感知半径按类别分开：地点、人物/物品、可交互候选各自有不同空间语义。
const LOCATION_NEAR_RADIUS := 10.0
const LOCATION_FAR_RADIUS := 50.0
const CHARACTER_NEAR_RADIUS := 3.0
const CHARACTER_FAR_RADIUS := 10.0
const ITEM_NEAR_RADIUS := 3.0
const ITEM_FAR_RADIUS := 10.0
const INTERACTIVE_FARM_VISIBLE_RADIUS := 30.0
const INTERACTIVE_WORKSTATION_VISIBLE_RADIUS := 10.0
const INTERACTIVE_SHELF_VISIBLE_RADIUS := 10.0
const INTERACTIVE_CONTAINER_VISIBLE_RADIUS := 10.0

var character: Character
var _manifest_pushed_at_frame: int = -1
var _world_cache: TownWorld


func _init(owner: Character) -> void:
	character = owner


# ─── space 遮挡 ──────────────────────────────────────────
# 室内外遮挡走 TownWorld（Godot 权威）。没有任何 SpaceVolume 时恒 true = 旧的纯距离行为。
func _world() -> TownWorld:
	if _world_cache == null or not is_instance_valid(_world_cache):
		var tree := character.get_tree()
		if tree != null:
			_world_cache = tree.get_first_node_in_group("town_world") as TownWorld
	return _world_cache


func _can_perceive(target_pos: Vector3, channel: String) -> bool:
	var w := _world()
	if w == null or not w.has_method("can_perceive_between"):
		return true
	return w.can_perceive_between(character.global_position, target_pos, channel)


# ─── characters ──────────────────────────────────────────

# 把所有其他角色按人物 NEAR / FAR 分桶；自己跳过；没有 backend_character_id 的也跳。
func nearby_character_ids() -> Dictionary:
	var near: Array = []
	var far: Array = []
	for node in iter_other_characters():
		var other_id := character_id_of(node)
		if other_id.is_empty():
			continue
		if not _can_perceive(node.global_position, "vision"):
			continue
		var entry: Variant = _character_context_entry(node, other_id)
		var distance: float = character.global_position.distance_to(node.global_position)
		if distance <= CHARACTER_NEAR_RADIUS:
			near.append(entry)
		elif distance <= CHARACTER_FAR_RADIUS:
			far.append(entry)
	return { "near": near, "far": far }


# 行动事件的"目击者"集合：距离内的其他角色，**自动剔除睡觉的人**。
# 这是 game state 真值过滤——睡着的人不可能目击到非声音事件（农事/移动/use_item 等）。
# say_to 不走这里（走 speech.lua 自己的 candidates 列表 + waking_volumes 判定），所以
# 这里把睡觉的人一律排除是安全的。
# volume=near 用 NEAR 半径，否则 FAR；far 包含 near，所以 volume=far 返回的是 near + far 并集。
func voice_affected_character_ids(volume: String) -> Array[String]:
	var radius := voice_radius(volume)
	var radius_sq := radius * radius
	var affected: Array[String] = []
	for node in iter_other_characters():
		var other_id := character_id_of(node)
		if other_id.is_empty():
			continue
		if character.global_position.distance_squared_to(node.global_position) > radius_sq:
			continue
		if node is Character and (node as Character).sleep_controller().is_sleeping():
			continue
		# 室内外隔音：不同 space 且任一室内 → 听不到。同 space / 全室外按距离（上面已判）。
		if not _can_perceive(node.global_position, "speech"):
			continue
		affected.append(other_id)
	return affected


func voice_radius(volume: String) -> float:
	return CHARACTER_NEAR_RADIUS if volume == "near" else CHARACTER_FAR_RADIUS


# ─── locations ───────────────────────────────────────────

# 附近建筑/地点 id 分 near/far。world 为空（极早期 _ready）时返回空 dict。
# 用 position_names()（全集）+ 距离判定：感知是物理范围，与 owner_group 可见性无关。
# 路过别人家私有田照样能看见它在身边，只是不能作为可前往目的地。
func nearby_position_ids(world: TownWorld) -> Dictionary:
	var near: Array[String] = []
	var far: Array[String] = []
	if world == null:
		return { "near": near, "far": far }
	var position_names := world.position_names()
	for position_name in position_names:
		var target := world.get_nearest_position_world(position_name, character.global_position)
		var distance := character.global_position.distance_to(target)
		var near_radius := world.location_use_radius(position_name, LOCATION_NEAR_RADIUS) \
			if world.has_method("location_use_radius") else LOCATION_NEAR_RADIUS
		if distance <= near_radius:
			near.append(position_name)
		elif distance <= LOCATION_FAR_RADIUS:
			far.append(position_name)
	return { "near": near, "far": far }


# 当前最显著的位置 id：先看 NEAR 半径内最近的 named position，没有就退到所在 region。
func current_location_id(world: TownWorld) -> String:
	if world == null:
		return "unknown"
	var nearest := ""
	if world.has_method("location_use_radius"):
		var best_distance_sq := INF
		for position_name in world.position_names():
			var near_radius := world.location_use_radius(position_name, LOCATION_NEAR_RADIUS)
			var target := world.get_nearest_position_world(position_name, character.global_position)
			var distance_sq := character.global_position.distance_squared_to(target)
			if distance_sq > near_radius * near_radius:
				continue
			if distance_sq < best_distance_sq:
				best_distance_sq = distance_sq
				nearest = str(position_name)
	elif world.has_method("nearest_location_id"):
		nearest = world.nearest_location_id(character.global_position, LOCATION_NEAR_RADIUS)
	else:
		nearest = nearest_position_id(world, LOCATION_NEAR_RADIUS)
	if not nearest.is_empty():
		return nearest
	var region := world.region_at_world(character.global_position)
	if region != null:
		return region.id
	return "unknown"


func nearest_position_id(world: TownWorld, max_distance: float) -> String:
	var best_id := ""
	var best_distance_sq := max_distance * max_distance
	for position_name in world.position_names():
		var target := world.get_nearest_position_world(position_name, character.global_position)
		var distance_sq := character.global_position.distance_squared_to(target)
		if distance_sq <= best_distance_sq:
			best_distance_sq = distance_sq
			best_id = position_name
	return best_id


func visible_locations(world: TownWorld) -> Array[Dictionary]:
	if world == null or not world.has_method("perceived_location_snapshots_for"):
		return []
	return world.perceived_location_snapshots_for(character.global_position, LOCATION_FAR_RADIUS)


# 角色共享的地点感知入口：NPC manifest 和玩家地图都走这里，避免 UI 自己重写一套附近 site 扫描。
func perceived_location_refs(world: TownWorld = null) -> Array:
	var w := world if world != null else _world()
	var refs: Array = []
	if w != null and w.has_method("perceived_position_refs_for"):
		refs = w.perceived_position_refs_for(character.global_position, LOCATION_NEAR_RADIUS, LOCATION_FAR_RADIUS)
	return _filter_refs_by_vision(refs, w)


# 玩家地图消费的角色视角 site 分区。这里只产出数据；MapPanel 只渲染按钮。
func map_site_sections() -> Dictionary:
	var w := _world()
	if w == null:
		return {"global": [], "nearby": []}
	var global_ids := PackedStringArray()
	if w.has_method("global_map_site_ids"):
		global_ids = w.global_map_site_ids()
	return {
		"global": _map_entries_from_ids(global_ids, w, "global"),
		"nearby": _map_entries_from_refs(perceived_location_refs(w), w),
	}


# ─── items ───────────────────────────────────────────────

func nearby_item_ids() -> Dictionary:
	var near: Array[String] = []
	var far: Array[String] = []
	var seen := {}
	for group_name in ["world_items", "ground_items", "dropped_items", "items"]:
		for node in character.get_tree().get_nodes_in_group(group_name):
			if seen.has(node):
				continue
			seen[node] = true
			if not node is Node3D:
				continue
			var item_id := item_id_of(node)
			if item_id.is_empty():
				continue
			if not _can_perceive((node as Node3D).global_position, "vision"):
				continue
			var distance := character.global_position.distance_to((node as Node3D).global_position)
			if distance <= ITEM_NEAR_RADIUS:
				near.append(item_id)
			elif distance <= ITEM_FAR_RADIUS:
				far.append(item_id)
	return { "near": near, "far": far }


# 附近地面上的液体容器（掉落的桶等）——活容器，可被液体转移寻址。
# 带 instanceId(db_id) 让 backend 能寻址具体那一个。
func nearby_ground_container_snapshots() -> Array:
	var out: Array = []
	var seen := {}
	for group_name in ["world_items", "ground_items", "dropped_items", "items"]:
		for node in character.get_tree().get_nodes_in_group(group_name):
			if seen.has(node):
				continue
			seen[node] = true
			var gi := node as GroundItem
			if gi == null or not is_instance_valid(gi):
				continue
			if not InventorySlotData.of(gi.slot_data).has_tag("liquid_container"):
				continue
			var dist := character.global_position.distance_to(gi.global_position)
			if dist > ITEM_FAR_RADIUS:
				continue
			if not _can_perceive(gi.global_position, "vision"):
				continue
			out.append({
				"instanceId": gi.db_id,
				"itemId": gi.item_id,
				"content": gi.slot_data.get("container_content", ""),
				"amount": gi.slot_data.get("container_amount", 0.0),
				"band": "near" if dist <= ITEM_NEAR_RADIUS else "far",
			})
	return out


# ─── farms / workstations ───────────────────────────────

# 给 backend agent context：附近 max_distance 内的 FarmGroup 状态 dump。
# 用 "first slot 位置" 当 farm 中心（FarmGroup 节点 origin 可能远离 slot 阵）。
func nearby_farm_snapshots(max_distance: float = INTERACTIVE_FARM_VISIBLE_RADIUS) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var max_sq := max_distance * max_distance
	for n in character.get_tree().get_nodes_in_group("farm_groups"):
		if not n is FarmGroup:
			continue
		var farm := n as FarmGroup
		var center: Vector3
		var ss := farm.slots()
		if ss.is_empty():
			center = farm.global_position
		else:
			center = ss[0].global_position
		if character.global_position.distance_squared_to(center) > max_sq:
			continue
		var snapshot := farm.describe_for_context()
		snapshot["directlyInteractable"] = _is_farm_directly_interactable(farm)
		out.append(snapshot)
	return out


# 给 backend agent context：当前范围内的工作台候选。owner_group 不过滤工作台使用，
# 只随 snapshot 作为归属/招牌元数据上报。
func nearby_workstation_snapshots(max_distance: float = INTERACTIVE_WORKSTATION_VISIBLE_RADIUS) -> Array[Dictionary]:
	return character.workstation_actions().nearby_snapshots(max_distance)


# 货架已统一为无锁容器（ShelfNode extends ContainerNode），但单独以 perceivedShelves 上报，
# 让 backend 渲染成带标价的货架。只需 id + directlyInteractable；内容/标价 backend 自己查
# shelves 表 + item_instances(ownerKind='container')。可见性 = 物理距离，无 group/owned 概念。
func nearby_shelf_snapshots(max_distance: float = INTERACTIVE_SHELF_VISIBLE_RADIUS) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tree := character.get_tree()
	if tree == null:
		return out
	var max_sq := max_distance * max_distance
	for n in tree.get_nodes_in_group("shelves"):
		var shelf := n as ShelfNode
		if shelf == null or not is_instance_valid(shelf):
			continue
		# 可见性用 max_distance（visible 半径）；可交互距离用货架自己 SiteMarker 的半径（逐对象）。
		# 都以货架自身位置为基准（玩家/NPC 一致）；NPC 寻路点是另一回事（approach）。
		var anchor := shelf.global_position
		if character.global_position.distance_squared_to(anchor) > max_sq:
			continue
		var r := SiteMarker.interaction_radius_of(shelf)
		out.append({
			"id": shelf.effective_shelf_id(),
			"directlyInteractable": character.global_position.distance_squared_to(anchor) <= r * r,
		})
	return out


# 容器统一通过 nearby_workstation_snapshots 上报（ContainerNode 进 "workstations" 组，
# workstation_action_runner.nearby_snapshots 给容器型 workstation 额外带 items/locked/unlocked）。
# 本函数保留作 unlockable_container_snapshots 内部共享逻辑的入口；外部新代码请改用
# nearby_workstation_snapshots，按 interactionMode == "container" 筛容器即可。
func nearby_container_snapshots(max_distance: float = INTERACTIVE_CONTAINER_VISIBLE_RADIUS) -> Array[Dictionary]:
	if Containers == null or not Containers.has_method("nearby_snapshots_for"):
		return []
	return Containers.nearby_snapshots_for(character, max_distance)


func unlockable_container_snapshots() -> Array[Dictionary]:
	if Containers == null or not Containers.has_method("unlockable_snapshots_for"):
		return []
	return Containers.unlockable_snapshots_for(character)


func resolve_farm_by_id(farm_id: String) -> FarmGroup:
	var wanted := farm_id.strip_edges()
	if wanted.is_empty():
		return null
	var best: FarmGroup = null
	var best_dist_sq := INF
	var duplicate_count := 0
	for n in character.get_tree().get_nodes_in_group("farm_groups"):
		if not n is FarmGroup:
			continue
		var farm := n as FarmGroup
		if not farm.matches_farm_id(wanted):
			continue
		duplicate_count += 1
		var dist_sq := character.global_position.distance_squared_to(_farm_center_position(farm))
		if best == null or dist_sq < best_dist_sq:
			best = farm
			best_dist_sq = dist_sq
	if duplicate_count > 1:
		push_warning("[Character %s] duplicate farm_id '%s' matched %d farms; picked nearest '%s'" % [
			character.backend_character_id(), wanted, duplicate_count, best.name if best != null else "?",
		])
	return best


# ─── lookup helpers ─────────────────────────────────────

# 跨 npcs + players 两个 group 枚举所有 Character node，跳过自己 / 非 Node3D。
func iter_other_characters() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var tree := character.get_tree()
	if tree == null:
		return out
	for node in tree.get_nodes_in_group("npcs"):
		if node == character or not node is Node3D:
			continue
		out.append(node as Node3D)
	for node in tree.get_nodes_in_group("players"):
		if node == character or not node is Node3D:
			continue
		out.append(node as Node3D)
	return out


# 兼容：NPC 早期版本只有 npc_id 属性、没装 backend_character_id()；
# Player 一直是 backend_character_id()。优先方法，回退到属性。
func character_id_of(node: Node) -> String:
	if node.has_method("backend_character_id"):
		return str(node.call("backend_character_id"))
	var id_var: Variant = node.get("npc_id")
	if id_var != null:
		return str(id_var)
	return ""


func _character_context_entry(node: Node, character_id: String) -> Variant:
	var status_text := _character_context_status_text(node)
	if status_text.is_empty():
		return character_id
	return {
		"id": character_id,
		"statusText": status_text,
	}


func _character_context_status_text(node: Node) -> String:
	if not node.has_method("_head_status_text"):
		return ""
	var status_text := str(node.call("_head_status_text")).strip_edges()
	var idle_text := character.tr("ui.head_status.idle").strip_edges()
	var hungry_text := character.tr("ui.head_status.hungry").strip_edges()
	if status_text.is_empty() or status_text == idle_text or status_text == hungry_text:
		return ""
	return status_text


func other_character_node_by_id(character_id: String) -> Node3D:
	for node in iter_other_characters():
		if character_id_of(node) == character_id:
			return node
	return null


func world_item_node_by_id(item_id: String) -> Node3D:
	var wanted := normalize_item_target_id(item_id)
	if wanted.is_empty():
		return null
	var seen := {}
	for group_name in ["world_items", "ground_items", "dropped_items", "items"]:
		for node in character.get_tree().get_nodes_in_group(group_name):
			if seen.has(node):
				continue
			seen[node] = true
			if not node is Node3D:
				continue
			if normalize_item_target_id(item_id_of(node)) == wanted:
				return node as Node3D
	return null


func item_id_of(node: Node) -> String:
	if node.has_method("backend_item_id"):
		return str(node.call("backend_item_id"))
	for key in ["item_id", "itemId", "item", "id"]:
		var value: Variant = node.get(key)
		if value != null and not str(value).strip_edges().is_empty():
			return str(value)
	return node.name


func normalize_item_target_id(value: String) -> String:
	var out := value.strip_edges()
	var quantity_index := out.rfind(" x")
	if quantity_index > 0:
		out = out.substr(0, quantity_index).strip_edges()
	if out.contains(":"):
		out = out.substr(out.find(":") + 1).strip_edges()
	return out.to_lower()


# ─── private ────────────────────────────────────────────

func _has_nearby_group_node(group_name: String, max_distance: float) -> bool:
	var max_distance_sq := max_distance * max_distance
	for node in character.get_tree().get_nodes_in_group(group_name):
		if not node is Node3D:
			continue
		if character.global_position.distance_squared_to((node as Node3D).global_position) <= max_distance_sq:
			return true
	return false


func _map_entries_from_ids(ids: PackedStringArray, world: TownWorld, band: String) -> Array:
	var refs: Array = []
	for id in ids:
		refs.append({"id": str(id), "band": band})
	return _map_entries_from_refs(refs, world)


func _map_entries_from_refs(refs: Array, world: TownWorld) -> Array:
	var out: Array = []
	var seen := {}
	for ref_v in refs:
		if not (ref_v is Dictionary):
			continue
		var ref: Dictionary = ref_v
		var id := str(ref.get("id", ""))
		if id.is_empty() or seen.has(id):
			continue
		seen[id] = true
		out.append(_map_entry_for_site(id, str(ref.get("band", "")), world))
	return out


func _map_entry_for_site(site_id: String, band: String, world: TownWorld) -> Dictionary:
	var alias := ""
	if world != null and world.has_method("location_alias"):
		alias = str(world.location_alias(site_id))
	var label := alias if not alias.is_empty() else site_id
	var owner_group := ""
	if world != null and world.has_method("owner_group_for"):
		owner_group = str(world.owner_group_for(site_id))
	var parent_id := ""
	if world != null and world.has_method("parent_location_id"):
		parent_id = str(world.parent_location_id(site_id))
	return {
		"id": site_id,
		"label": label,
		"band": band,
		"parentId": parent_id,
		"depth": 1 if not parent_id.is_empty() else 0,
		"ownerGroup": owner_group,
		"inaccessible": not owner_group.is_empty() and not character.groups.has(owner_group),
	}


func _farm_center_position(farm: FarmGroup) -> Vector3:
	if farm == null or not is_instance_valid(farm):
		return character.global_position
	var ss := farm.slots()
	if ss.is_empty():
		return farm.global_position
	var sum := Vector3.ZERO
	var count := 0
	for slot in ss:
		if slot == null or not is_instance_valid(slot):
			continue
		sum += slot.global_position
		count += 1
	return sum / float(count) if count > 0 else farm.global_position


func _is_farm_directly_interactable(farm: FarmGroup) -> bool:
	if farm == null or not is_instance_valid(farm):
		return false
	var r := SiteMarker.interaction_radius_of(farm)
	var max_sq := r * r
	for slot in farm.slots():
		if slot == null or not is_instance_valid(slot):
			continue
		if character.global_position.distance_squared_to(slot.global_position) <= max_sq:
			return true
	return character.global_position.distance_squared_to(_farm_center_position(farm)) <= max_sq


# ─── perception manifest（上行 backend）─────────────────────
# 把"我此刻感知到的实体 id 集合"推给 backend。Backend 再用 manifest + SELECT sqlite
# 当场拼 LLM context；不再传 entity 状态过去。
#
# 本帧去重：send_world_event 会在 emit 前 flush 一次。同一帧主线程未让出 → manifest
# 内容没变化，跳过重复推送。

func send_manifest() -> void:
	if not RunMode.is_runtime():
		return
	var current_frame := Engine.get_process_frames()
	if _manifest_pushed_at_frame == current_frame:
		return
	_manifest_pushed_at_frame = current_frame
	var backend := character.get_node_or_null("/root/BackendRuntimeClient")
	if backend == null or not backend.has_method("send_perception_manifest"):
		return
	backend.call("send_perception_manifest", build_manifest())


# 用本类各 nearby_* 方法收 ID 列表。复用 snapshot 路径下的 nearby_*_snapshots
# 只为拿 id 字段——P7 删掉 snapshot 后这些方法该改成只返回 ids。
func build_manifest() -> Dictionary:
	var world: TownWorld = character.get_tree().get_first_node_in_group("town_world") as TownWorld
	var cid := character.backend_character_id()

	# Locations: 由 world 算 band（near/far）。距离过滤；不再有"顶层永远可见"——
	# NPC 知道哪些地点存在（move_to_location enum）走 known_location_ids 另一字段。
	var location_refs: Array = perceived_location_refs(world)
	var known_location_ids: PackedStringArray = PackedStringArray()
	if world != null and world.has_method("known_position_ids"):
		known_location_ids = world.known_position_ids()

	# Characters: nearby_character_ids() 已按 near/far 分桶
	var character_refs := _refs_from_near_far_dict(nearby_character_ids(), true)

	# Items: nearby_item_ids() 已按 near/far 分桶
	var item_refs := _refs_from_near_far_dict(nearby_item_ids(), false)

	# 交互站点：directlyInteractable=true → "direct"，否则 "near"（已经 ≤ visible 半径才进列表）。
	# 室内外遮挡：用各 site 锚点位置过滤掉跨 space 看不见的（如室外看室内灶台）。
	# location_refs 已由 perceived_location_refs 过滤；下面只过滤交互站点。
	var farm_refs := _filter_refs_by_vision(_refs_from_interactive_snapshots(nearby_farm_snapshots()), world)
	var ws_refs := _filter_refs_by_vision(_refs_from_interactive_snapshots(nearby_workstation_snapshots()), world)
	var shelf_refs := _filter_refs_by_vision(_refs_from_interactive_snapshots(nearby_shelf_snapshots()), world)

	# 容器是 WorkstationNode 子类，已通过 perceivedWorkstations 上报。
	# Backend 在 assemble 阶段同时查 workstation_states + container_states，无需再单独收集。

	var group_ids := PackedStringArray()
	for g in character.groups:
		group_ids.append(str(g))

	return {
		"characterId": cid,
		"selfLocationId": current_location_id(world) if world != null else "unknown",
		"selfIsAsleep": character.sleep_controller().is_sleeping(),
		"gameTime": character.snapshots().game_time(),
		"characterGroupIds": group_ids,
		"perceivedLocations": location_refs,
		"knownLocationIds": known_location_ids,
		"perceivedCharacters": character_refs,
		"perceivedItems": item_refs,
		"perceivedGroundContainers": nearby_ground_container_snapshots(),
		"perceivedFarms": farm_refs,
		"perceivedWorkstations": ws_refs,
		"perceivedShelves": shelf_refs,
	}


# nearby_character_ids() / nearby_item_ids() 返回 {near:[...], far:[...]}，
# 把它压成 [{id, band}]。character entry 可能是 Dictionary（含 id 字段），item entry 是字符串。
func _refs_from_near_far_dict(dict: Dictionary, entries_are_dicts: bool) -> Array:
	var out: Array = []
	var seen := {}
	for band in ["near", "far"]:
		var bucket: Array = dict.get(band, [])
		for entry in bucket:
			var id := ""
			if entries_are_dicts and entry is Dictionary:
				id = str(entry.get("id", ""))
			else:
				id = str(entry)
			if id.is_empty() or seen.has(id):
				continue
			seen[id] = true
			out.append({"id": id, "band": band})
	return out


# nearby_*_snapshots() 给的每条 dict 都带 id + directlyInteractable。
# Visible 范围内已被过滤过，所以非 direct = "near"（不存在 "far"）。
# 按视觉 space 遮挡过滤 [{id,band}] —— 用 site 最近锚点位置判定。没有 SpaceVolume 时原样返回。
func _filter_refs_by_vision(refs: Array, world: TownWorld) -> Array:
	if world == null or not world.has_method("get_nearest_position_world"):
		return refs
	var out: Array = []
	for ref in refs:
		var id := str(ref.get("id", ""))
		if id.is_empty():
			continue
		var target := world.get_nearest_position_world(id, character.global_position)
		if _can_perceive(target, "vision"):
			out.append(ref)
	return out


func _refs_from_interactive_snapshots(snaps: Array) -> Array:
	var out: Array = []
	for snap in snaps:
		var id := str(snap.get("id", snap.get("shelfId", "")))
		if id.is_empty():
			continue
		var band := "direct" if bool(snap.get("directlyInteractable", false)) else "near"
		out.append({"id": id, "band": band})
	return out
