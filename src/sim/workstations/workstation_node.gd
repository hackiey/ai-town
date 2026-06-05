@tool
class_name WorkstationNode
extends Node3D

# 镇里可交互的工作站（铁砧 / 熔炉 / 工作台 / 磨坊 / 灶）：
# - 子节点 Area3D 检测本地玩家 proximity，进 → 显示 prompt 并广播 EventBus
# - E 键由 ActionPanel 监听，根据"当前 active workstation"决定开哪个 UI
# - 工作站本身不持有反应表 / 不执行 reaction，只是 UI 入口
# - verb / slot 配置都从 Workstation Resource (data/workstations/<id>.tres) 读
# - 物品/产出走标准 Item + reaction dispatcher 路径，server 权威
#
# 设计：docs/architecture/crafting-interaction.md §2.2
# 反应规则：docs/architecture/base-items.md

# 必填，对应 data/workstations/<id>.tres
@export var workstation_id: String = "":
	set(value):
		workstation_id = value
		if is_inside_tree():
			call_deferred("_refresh_labels")

const _WORKSTATIONS_I18N_JSON_REL := "data/i18n/zh/workstations.json"
const _DEFAULT_DISPLAY_NAME := "工作站"
const _DEFAULT_PROMPT_TEXT := "按 E 使用"
static var _WORKSTATIONS_I18N_JSON_CACHE: Dictionary = {}
static var _WORKSTATIONS_I18N_JSON_LOADED: bool = false

# display_name / prompt_text 走 i18n catalog，按 workstation_id 取
# (data/i18n/<locale>/workstations.json -> workstation.<id>.{name,prompt})。
# .tscn 实例不再 override；setter no-op 兼容旧文件。
var display_name: String:
	get:
		if workstation_id.is_empty():
			return _translated_or_fallback("ui.workstation.label_default", _DEFAULT_DISPLAY_NAME)
		var key := "workstation.%s.name" % workstation_id
		var value := _translated_text(key)
		if value.is_empty():
			value = _get_workstation_i18n_field(workstation_id, "name")
		return value if not value.is_empty() else _translated_or_fallback("ui.workstation.label_default", _DEFAULT_DISPLAY_NAME)
	set(_value): pass

var prompt_text: String:
	get:
		if workstation_id.is_empty():
			return _translated_or_fallback("ui.workstation.prompt_default", _DEFAULT_PROMPT_TEXT)
		var key := "workstation.%s.prompt" % workstation_id
		var value := _translated_text(key)
		if value.is_empty():
			value = _get_workstation_i18n_field(workstation_id, "prompt")
		return value if not value.is_empty() else _translated_or_fallback("ui.workstation.prompt_default", _DEFAULT_PROMPT_TEXT)
	set(_value): pass

@export var tint_color: Color = Color(0, 0, 0, 0)    # alpha=0 → 用 .tscn 默认棕色

# 归属 group。语义对齐 LocationMarker.owner_group（解析在 TownWorld._resolve_workstation_owner_group）：
#   ""        → 从父链上最近的 LocationMarker 继承（场景树即真值）；没找到 = public
#   "public"  → 显式公用，覆盖继承（私有园子里的公用水井等）
#   其他字符串 → 该 group 名（如 "blacksmith_shop"）
# 把工作台直接放进对应 location 子树即可自动归属，不必每个节点重复填。
@export var owner_group: String = ""

# 锁。空=未上锁；非空=角色背包需有该 item id 才能 use。
# 与 owner_group 正交：group 控可见/可寻路，lock 控使用。
# 没人能开（仅 system_* 接口能写）= 用一个没人会获得的钥匙 id（如 "__none__"）。
@export var lock_item_id: String = ""

@onready var _area: Area3D = get_node_or_null("Area3D")
@onready var _label: Label3D = get_node_or_null("Prompt")
@onready var _title: Label3D = get_node_or_null("Title")
@onready var _mesh: MeshInstance3D = get_node_or_null("Mesh")
@onready var _approach: Marker3D = get_node_or_null("Approach")


# NPC 寻路 / backend perception 用的"位置代表点"。基类 .tscn 提供一个在原点的
# Approach Marker3D；带大 mesh 的子类（gold_mine / forge 等）应在自己的 .tscn
# 里 override Approach.transform，把它推到 collider 外，避免 anchor 落在 navmesh 洞里。
# 找不到 marker 时 fallback 到 self —— 兼容尚未加 marker 的老节点。
func get_approach_node() -> Node3D:
	var marker := get_node_or_null("Approach") as Node3D
	return marker if marker != null else self

var _local_active: bool = false


func _enter_tree() -> void:
	# 烘焙在编辑器里跑，所以 editor + runtime 都要加入；NavigationRegion3D
	# 的 geometry_source_geometry_mode=GROUPS_WITH_CHILDREN 会扫子树里的
	# StaticBody（第三方 prefab 自带），把工作台算进 navmesh，NPC 才会绕行。
	add_to_group("navmesh")
	if Engine.is_editor_hint():
		call_deferred("_refresh_labels")


func _ready() -> void:
	if Engine.is_editor_hint():
		_refresh_labels()
		return
	for g in _runtime_groups():
		add_to_group(g)
	if _area == null:
		push_warning("Workstation %s 缺少 Area3D 子节点" % name)
		return
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)
	_refresh_labels()
	# Title Label3D 编辑器里仍然可见（方便摆放），runtime 由 WorkstationNameplateLayer
	# 接管：2D + 走近 ≤10m 才显示，避免远距离名字糊屏。
	if _title != null:
		_title.visible = false
	if _label != null:
		_label.visible = false
	if _mesh != null and tint_color.a > 0.0:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint_color
		_mesh.material_override = mat


func _refresh_labels() -> void:
	var title := get_node_or_null("Title") as Label3D
	if title != null:
		title.text = display_name
	var label := get_node_or_null("Prompt") as Label3D
	if label != null:
		label.text = prompt_text


func _translated_text(key: String) -> String:
	var value := tr(key).strip_edges()
	return "" if value.is_empty() or value == key else value


func _translated_or_fallback(key: String, fallback: String) -> String:
	var value := _translated_text(key)
	return value if not value.is_empty() else fallback


static func _get_workstation_i18n_field(workstation_id_key: String, field_name: String) -> String:
	if not _WORKSTATIONS_I18N_JSON_LOADED:
		_load_workstations_i18n_json()
	var entry_v: Variant = _WORKSTATIONS_I18N_JSON_CACHE.get(workstation_id_key, {})
	if not (entry_v is Dictionary):
		return ""
	return str((entry_v as Dictionary).get(field_name, "")).strip_edges()


static func _load_workstations_i18n_json() -> void:
	_WORKSTATIONS_I18N_JSON_LOADED = true
	var project_root := ProjectSettings.globalize_path("res://")
	var path := project_root.path_join(_WORKSTATIONS_I18N_JSON_REL)
	if not FileAccess.file_exists(path):
		push_warning("[WorkstationNode] workstation i18n json not found at %s" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_warning("[WorkstationNode] workstation i18n json root is not a dict")
		return
	var workstation_entries_v: Variant = (parsed as Dictionary).get("workstation", {})
	_WORKSTATIONS_I18N_JSON_CACHE = workstation_entries_v if workstation_entries_v is Dictionary else {}


func _on_body_entered(body: Node) -> void:
	if not _is_local_player(body):
		return
	_local_active = true
	if _label != null:
		_label.visible = true
	EventBus.workstation_proximity_changed.emit(self, true)


func _on_body_exited(body: Node) -> void:
	if not _is_local_player(body):
		return
	_local_active = false
	if _label != null:
		_label.visible = false
	EventBus.workstation_proximity_changed.emit(self, false)


# 只对本地玩家响应（多人时 server 上跑的其他 player 不该触发本地 UI）。
# Headless server 端 Players.local_character_id 永远空 → 永远 false，符合"server 没有 UI"。
func _is_local_player(body: Node) -> bool:
	if not body.is_in_group("players"):
		return false
	var cid := str(body.get("character_id"))
	return not cid.is_empty() and cid == Players.local_character_id


func is_local_active() -> bool:
	return _local_active


# 子类决定自己进哪些 group。基类 = "workstations"；ContainerNode 等子类可加 "containers"。
# 注意 navmesh 在 _enter_tree 里统一加，这里只管 runtime 行为分组。
func _runtime_groups() -> PackedStringArray:
	return PackedStringArray(["workstations"])


# 工作台对所有人可用：现实里谁都能用别人的工作台，被赶走是社交反应（反应层处理），
# 不是硬权限闸门。group 不再作为使用门槛。锁（lock_item_id/钥匙）维度仍生效，见 is_unlocked_by。
# owner_group 保留仅供招牌 flavor 文案，不闸门。
func can_be_used_by(_character: Node) -> bool:
	return true


func is_locked() -> bool:
	return not lock_item_id.strip_edges().is_empty()


# 钥匙维度：无锁 → true；上锁但持钥匙 → true；其他 false。
# 不查 group 权限，调用方自己决定要不要叠 can_be_used_by。
func is_unlocked_by(character: Node) -> bool:
	if not is_locked():
		return true
	if character == null or not character.has_method("inventory_ops"):
		return false
	return character.inventory_ops().count_item(lock_item_id.strip_edges()) > 0


# 综合：group 通过且锁通过。actor 实际能否操作此节点用这个。
func can_actually_use(character: Node) -> bool:
	return can_be_used_by(character) and is_unlocked_by(character)


# ─── 并发占用锁（跨角色）─────────────────────────────────────
# 真值住 _current_operators 数组；容量上限来自 Workstation.max_concurrent_users
# （默认 1 = 严格单占；mine / lumberyard 这类"场地型"设 100 ≈ 无限）。
# Db.workstation_states 是 perception 镜像，try_acquire / release / _exit_tree 同步写。
# ContainerNode 不走 WorkstationActionRunner.start_from_action，子类实例恒为空。
#
# 多占场景下，DB 的 currentOperatorId 写 NULL——perception 不渲染"使用中：xx"，
# 因为列具体名字既不准确也无决策价值（反正没人被挡）。
var _current_operators: Array[String] = []
var _current_verb: String = ""


func is_occupied() -> bool:
	return not _current_operators.is_empty()


# 单占语义下返回那个唯一占用者；多占场景返回首个 operator（兼容旧 caller，
# perception 端不读这个值）。空闲返回 ""。
func current_operator_id() -> String:
	return _current_operators[0] if not _current_operators.is_empty() else ""


func _max_concurrent_users() -> int:
	var ws_def: Workstation = Workstations.by_id(String(workstation_id))
	return ws_def.max_concurrent_users if ws_def != null else 1


# 成功返回 true 并同步 DB；容量已满返回 false。
# 同 operator 重入返回 true（理论上不触发——runner 自己有 _active 拦着）。
func try_acquire(operator_id: String, verb: String) -> bool:
	if operator_id.is_empty():
		push_warning("[Workstation %s] try_acquire with empty operator_id" % name)
		return false
	if _current_operators.has(operator_id):
		_current_verb = verb
		_sync_occupancy_to_db()
		return true
	if _current_operators.size() >= _max_concurrent_users():
		return false
	_current_operators.append(operator_id)
	_current_verb = verb
	_sync_occupancy_to_db()
	return true


# 从占用列表移除该 operator；不在列表里则 warn no-op——防 acquire/release 顺序
# 错乱（如 _exit_tree cleanup）误清不存在的占用。
func release(operator_id: String) -> void:
	if not _current_operators.has(operator_id):
		if not _current_operators.is_empty():
			push_warning("[Workstation %s] release by %s but holders=%s, ignored" % [name, operator_id, _current_operators])
		return
	_current_operators.erase(operator_id)
	if _current_operators.is_empty():
		_current_verb = ""
	_sync_occupancy_to_db()


func _exit_tree() -> void:
	# 节点销毁防泄漏：仍有 occupant 就清 DB 镜像，避免重启前 backend perception 看到孤行 busy=1。
	if not _current_operators.is_empty():
		_current_operators.clear()
		_current_verb = ""
		Db.set_workstation_occupants(String(name), "", "", 0)


# 把内存占用全量同步到 DB perception 镜像。
# 单占场景：写 first operator id；多占场景：写 NULL（perception 不展示具体人名）。
func _sync_occupancy_to_db() -> void:
	var count := _current_operators.size()
	var single := _max_concurrent_users() <= 1
	var first_id := _current_operators[0] if (single and count > 0) else ""
	var verb := _current_verb if not first_id.is_empty() else ""
	Db.set_workstation_occupants(String(name), first_id, verb, count)
