class_name Character
extends CharacterBody3D

# 所有"活着的角色"的共享基类（NPC、Player）。
# 设计文档：docs/architecture/entity-model.md
#
# 字段分两类：
#   @export = 编辑器配置，可在 inspector / .tscn 改
#   var     = runtime 状态，每实例独立，不能放 Resource 上（.tres 跨实例共享）
#
# 子系统 accessor 收口：所有动作 / 状态 / IO 都在 parts/<x>_controller.gd 里。
# Character 本体只持有 @export + 核心 runtime 字段 + 子系统 accessor + 子类虚 hook +
# Godot @rpc shim（RefCounted 不能持 @rpc，必须留 Node）。

const _WORKSTATION_ACTION_RUNNER := preload("res://src/sim/workstations/workstation_action_runner.gd")
const _CHARACTER_PERCEPTION := preload("res://src/characters/parts/character_perception.gd")
const _CHARACTER_INVENTORY := preload("res://src/characters/parts/character_inventory.gd")
const _HEAD_STATUS_CONTROLLER := preload("res://src/characters/parts/head_status_controller.gd")
const _WALK_CONTROLLER := preload("res://src/characters/parts/walk_controller.gd")
const _FARM_ACTION_RUNNER := preload("res://src/characters/parts/farm_action_runner.gd")
const _BACKEND_ACTION_RUNNER := preload("res://src/characters/parts/backend_action_runner.gd")
const _TRADE_RUNNER := preload("res://src/characters/parts/trade_runner.gd")
const _SLEEP_CONTROLLER := preload("res://src/characters/parts/sleep_controller.gd")
const _USE_ITEM_CONTROLLER := preload("res://src/characters/parts/use_item_controller.gd")
const _CHARACTER_STATE_IO := preload("res://src/characters/parts/character_state_io.gd")
const _CHARACTER_SNAPSHOTS := preload("res://src/characters/parts/character_snapshots.gd")
const _CHARACTER_VISUAL_CONTROLLER := preload("res://src/characters/parts/character_visual_controller.gd")
const _SPEECH_CONTROLLER := preload("res://src/characters/parts/speech_controller.gd")

const INVENTORY_SLOT_COUNT := 20
const INVENTORY_STACK_MAX := 99
const ITEM_DEFAULT_QUALITY := 100
const DEFAULT_SLEEP_NEEDED_HOURS := 8.0

# 物理 ───────────────────────────────────────────────
@export var material: Substance                   # _ready 兜底为 flesh
@export var mass: float = 70.0                    # kg
@export var volume: float = 0.07                  # m³
@export_range(0.0, 1.0) var moisture: float = 0.05

# instance override；-1 = 用 material 默认。先只放 ignition_point 一项验证模式，
# 其他属性等真有"想偏离默认"的需求再加，避免空字段污染 inspector
@export var ignition_point_override: float = -1.0

# runtime 物理状态
var temperature: float = 36.5
var burning: bool = false
@onready var nav: NavigationAgent3D = get_node_or_null("NavigationAgent3D")

# 生命与体力 ─────────────────────────────────────────
# 角色没有 mana —— 法术能量住在魔杖上（待实现 Wand 类）。stamina 是统一行动力。
# Hunger / hp 衰减 + 阈值 + 饿死 等规则全在 data/mechanics/physiology.lua。
@export var max_hp: float = 100.0
@export var max_stamina: float = 100.0
@export var max_hunger: float = 100.0
@export var max_rest: float = 100.0
@export var sleep_needed_hours: float = 0.0
var hp: float
var stamina: float
var hunger: float
var rest: float
# 钱包。silver_coin / gold_coin 不再以 inventory item 形式存在，统一走 wallet 余额。
# 单位是 centi（1 silver = 100 centi），int 避免浮点误差。显示层除 100 即 silver。
# 拾取物理 silver_coin/gold_coin → 自动入账（见 character_inventory.gd）。
var wallet_centi: int = 0
# 真值翻转通过 affect.set_alive；setter 触发 _on_alive_changed 让子类做物理善后。
var alive: bool = true:
	set(value):
		if alive == value:
			return
		alive = value
		_on_alive_changed()

# Smallville-style 状态流（文本/标签，不是数字 buff）
# 每条: { type: String, started_at: float, expires_total_hours: int, source_id: String }
# expires_total_hours = -1 表示永久（hungry / sleeping 走显式清理，不到这步）
var active_conditions: Array[Dictionary] = []

# 社交 / 装备 ────────────────────────────────────────
@export var faction: String = "townsfolk"
@export var character_name: String = ""
@export var character_age: int = -1
@export var occupation: String = ""
@export var personality: String = ""
# 角色所属的 group 集合，**真值在 SQLite `character_groups` 表**。
# server _ready 时从 DB 拉一次（reload_groups_from_db），后端有变动时由 backend
# push `character.groups.refresh` 让本节点重拉。@export 只是 inspector 可见的快照，
# 不要在 .tscn / .gd 里写死成员资格——改 backend/data/town/npcs.json 里该 NPC 的
# `groups[]` 字段（首次 boot 自动 seed），或运行时调 Db.add_member。
# "god" 成员 bypass 所有过滤（dev 期 /god 命令进入）。
@export var groups: PackedStringArray = PackedStringArray()
var _db_groups: PackedStringArray = PackedStringArray()  # 上次从 DB 拉到的列表，refresh 时用来 diff 出要 remove_from_group 的项
# slot_name → item_id；slot 候选: "right_hand"|"left_hand"|"body"|"head"
# Item 类未实现，先用 String item_id 占位
var equipped: Dictionary = {}

# ─── 背包 ───────────────────────────────────────────
# 固定槽数，server 权威。Player 通过 InventorySync 推到 owner client；NPC server-only。
# 槽位形态（Phase 2 schema instance）:
#   { item_id, quality, shape_type, materials: Dictionary,
#     tags: PackedStringArray, properties: Dictionary, quantity }
#   - quality: 1-100；空槽和无意义品质的物品（种子、装备）默认 100
#   - shape_type / materials / tags / properties 同 schema instance 字段
#   - stack 等价：item_id + quality + shape_type + materials + tags + properties 全相等
#     原料无 per-instance 状态自然 stack；crafted item 有 quality 差异自然不 stack
# 空槽: InventorySlotData.empty()（所有字段默认）
# 写 API（add_item / add_instance / remove_item）只 server，assert 守门。
var inventory: Array[Dictionary] = []

# 头顶气泡 ───────────────────────────────────────────
# Nameplate 锚点 = Visual.origin 上方固定 Y offset（"静态像 capsule"）：不绑骨骼，
# 动画播放时 nameplate 完全不动。Visual 由 CharacterVisualController 重度平滑 Y
# （damping_y=5），floor_snap 噪声不会传过来。
@export var head_ui_anchor_offset: float = 1.72
@export var speech_bubble_hold_sec: float = 3.0
@export var speech_bubble_fade_sec: float = 0.6
# Visual smoothing 用帧率无关指数衰减：alpha = 1 - exp(-damping * delta)。
# damping 单位 1/秒，half_life ≈ 0.693/damping。Per-axis：Y 单独慢，专门吃 floor_snap 噪声
# （它每 physics tick 把 Y 拉回地形高度，原始噪声直接给 nameplate 就是抖）。
# XZ 快是玩家走路要 1:1 跟得紧；Y 慢是相机/nameplate 看上去稳。
@export var client_visual_damping_xz: float = 18.0
@export var client_visual_damping_y: float = 5.0
@export var client_visual_max_offset: float = 0.6


# ─── 子系统懒加载 accessor ────────────────────────────
# 所有动作 / 状态 / IO 都收口在对应 controller / runner，本体只持 backing 字段 + 懒加载。
# Cross-character 调用走这些 accessor：character.sleep_controller().is_sleeping() 等。

var _walk_runner: WalkController = null
var _perception_runner: CharacterPerception = null
var _inventory_runner: CharacterInventory = null
var _workstation_runner: WorkstationActionRunner = null
var _farm_runner: FarmActionRunner = null
var _backend_runner: BackendActionRunner = null
var _head_status_runner: HeadStatusController = null
var _trade_runner_inst: TradeRunner = null
var _sleep_controller_inst: SleepController = null
var _use_item_controller_inst: UseItemController = null
var _state_io_inst: CharacterStateIO = null
var _snapshots_inst: CharacterSnapshots = null
var _visual_inst: CharacterVisualController = null
var _speech_inst: SpeechController = null


func walk() -> WalkController:
	if _walk_runner == null:
		_walk_runner = _WALK_CONTROLLER.new(self)
	return _walk_runner


func perception() -> CharacterPerception:
	if _perception_runner == null:
		_perception_runner = _CHARACTER_PERCEPTION.new(self)
	return _perception_runner


# 节点级转发：让外部（BackendRuntimeClient 重连补发、shelves/trade 交互、player spawn）
# 无需知道 perception 部件即可推送本角色 manifest。
func send_perception_manifest() -> void:
	perception().send_manifest()


# 返回本角色当前完整 perception manifest（dict），供 world event 打包随事件下发。
func build_perception_manifest() -> Dictionary:
	return perception().build_manifest()


func inventory_ops() -> CharacterInventory:
	if _inventory_runner == null:
		_inventory_runner = _CHARACTER_INVENTORY.new(self)
	return _inventory_runner


func workstation_actions() -> WorkstationActionRunner:
	if _workstation_runner == null:
		_workstation_runner = _WORKSTATION_ACTION_RUNNER.new(self)
	return _workstation_runner


func farm_actions() -> FarmActionRunner:
	if _farm_runner == null:
		_farm_runner = _FARM_ACTION_RUNNER.new(self)
	return _farm_runner


func backend_actions() -> BackendActionRunner:
	if _backend_runner == null:
		_backend_runner = _BACKEND_ACTION_RUNNER.new(self)
	return _backend_runner


func head_status() -> HeadStatusController:
	if _head_status_runner == null:
		_head_status_runner = _HEAD_STATUS_CONTROLLER.new(self)
	return _head_status_runner


func trade_runner() -> TradeRunner:
	if _trade_runner_inst == null:
		_trade_runner_inst = _TRADE_RUNNER.new(self)
	return _trade_runner_inst


func sleep_controller() -> SleepController:
	if _sleep_controller_inst == null:
		_sleep_controller_inst = _SLEEP_CONTROLLER.new(self)
	return _sleep_controller_inst


func use_item_controller() -> UseItemController:
	if _use_item_controller_inst == null:
		_use_item_controller_inst = _USE_ITEM_CONTROLLER.new(self)
	return _use_item_controller_inst


func state_io() -> CharacterStateIO:
	if _state_io_inst == null:
		_state_io_inst = _CHARACTER_STATE_IO.new(self)
	return _state_io_inst


func snapshots() -> CharacterSnapshots:
	if _snapshots_inst == null:
		_snapshots_inst = _CHARACTER_SNAPSHOTS.new(self)
	return _snapshots_inst


func visual_smoothing() -> CharacterVisualController:
	if _visual_inst == null:
		_visual_inst = _CHARACTER_VISUAL_CONTROLLER.new(self)
	return _visual_inst


func speech() -> SpeechController:
	if _speech_inst == null:
		_speech_inst = _SPEECH_CONTROLLER.new(self)
	return _speech_inst


# ─── lifecycle ──────────────────────────────────────

func _ready() -> void:
	if material == null:
		material = Materials.by_id("flesh")
	if sleep_needed_hours <= 0.0:
		sleep_needed_hours = DEFAULT_SLEEP_NEEDED_HOURS
	hp = max_hp
	stamina = max_stamina
	hunger = max_hunger
	rest = max_rest
	inventory_ops().init_slots()
	# Hydrate from SQLite character_states：覆盖位姿 / 数值 / 装备 / conditions。
	# 首次开服的角色初始状态由 Db seed 写入；Character 只读取 DB。
	if RunMode.is_runtime():
		state_io().hydrate()
	# _process 只用来跑气泡淡出；没气泡时关掉避免每个角色每帧空转
	set_process(false)


func _exit_tree() -> void:
	# Server 兜底：角色离场（despawn / kick / 死亡 queue_free）时若仍占用工作台，
	# 取消 active action 让 runner 走标准 release 路径，避免 DB 行残留 busy=1。
	if not RunMode.is_runtime():
		return
	if _workstation_runner != null and _workstation_runner.is_active():
		_workstation_runner.cancel("character_despawned")


func _process(delta: float) -> void:
	head_status().update_process(delta)


# 子类（NPC / Player）覆盖返回当前 anim_state 字符串。基类不知道它（NPC 与 Player
# 各自声明的 anim_state 不在 Character 上），默认空串。
func _current_anim_state() -> String:
	return ""


# alive 翻转后子类的物理善后（NavMesh 移除、RPC 停发、动画切死亡）。
# Character 基类是 no-op；NPC / Player 后续按需 override。
func _on_alive_changed() -> void:
	pass


# 从 SQLite `character_groups` 拉一次成员资格，diff 后更新 self.groups 和
# Godot 节点 group 列表。**只在 server (RunMode.is_runtime) 调有效**——
# client 不直连 DB。子类 _ready 在 super._ready() 之后调即可。
# 后端写入新成员（如 /god、拜师）后，BackendRuntimeClient 收到 refresh 事件再调一次。
func reload_groups_from_db() -> void:
	if not RunMode.is_runtime():
		return
	var character_id := backend_character_id()
	if character_id.is_empty():
		return
	var fresh := PackedStringArray()
	for g in Db.get_character_groups(character_id):
		fresh.append(str(g))
	# diff：remove 老的（不在 fresh 里的），add 新的
	for old_g in _db_groups:
		if not fresh.has(old_g) and is_in_group(old_g):
			remove_from_group(old_g)
	for new_g in fresh:
		if not _db_groups.has(new_g) or not is_in_group(new_g):
			add_to_group(new_g)
	_db_groups = fresh
	groups = fresh.duplicate()


# ─── 缓慢 tick（10 min game-time）─────────────────────
# Server 端调，每 10 game-minutes 一次。town.gd 订阅 GameClock.ten_minute_tick 后遍历所有角色调这个。
# 不放在 _physics_process 里：物理 tick 是 60Hz，hunger 应当按 game-time 而非 real-time。
# 业务规则全在 data/mechanics/physiology.lua；这里只准备 ctx + 收尾（过期 / 腐烂 / persist）。
# total_minute 是自开服累计 game-minute（GameClock signal 真值），用于派生整点判定。
func apply_ten_minute_tick(total_minute: int) -> void:
	if not alive:
		return
	MechanicHost.invoke("physiology", "on_slow_tick", {
		"character": self,
		"tick_hours": 1.0 / 6.0,
		"hp": hp,
		"max_hp": max_hp,
		"stamina": stamina,
		"max_stamina": max_stamina,
		"hunger": hunger,
		"max_hunger": max_hunger,
		"rest": rest,
		"max_rest": max_rest,
		"is_sleeping": sleep_controller().is_sleeping(),
		"has_hungry": has_condition("hungry"),
	})
	_expire_timed_conditions()
	head_status().sync_to_clients()
	if GameClock.minute_of_hour_for_minute(total_minute) == 0:
		inventory_ops().tick_spoilage()
	# Physiology tick = 数值变化的时刻；腐烂仍只在整点结算。
	state_io().persist()


# 清理过期 conditions。expires_total_hours == -1 表示永久（hungry 等永远不到这步）；
# 其余比对 GameClock.total_game_hours()。每次 slow_tick 末尾跑一次。
func _expire_timed_conditions() -> void:
	var now_total: int = GameClock.total_game_hours()
	for i in range(active_conditions.size() - 1, -1, -1):
		var c: Dictionary = active_conditions[i]
		var exp: int = int(c.get("expires_total_hours", -1))
		if exp >= 0 and now_total >= exp:
			active_conditions.remove_at(i)


# ─── condition primitives（active_conditions 公共操作）──
# 数组留 Character，操作是公共 API（sleep_controller / physiology / inventory 都会调）。

func has_condition(type: String) -> bool:
	for c in active_conditions:
		if str(c.get("type", "")) == type:
			return true
	return false


func remove_condition_type(type: String) -> void:
	for i in range(active_conditions.size() - 1, -1, -1):
		if str(active_conditions[i].get("type", "")) == type:
			active_conditions.remove_at(i)


# 头顶气泡当前状态文本（NPC / Player 可 override 插入 "working" / "crafting" 等）。
# 子类 super._head_status_text() 拿到基类的 condition 文本兜底。
func _head_status_text() -> String:
	if has_condition("sleeping"):
		return tr("ui.head_status.sleeping")
	if has_condition("hungry"):
		return tr("ui.head_status.hungry")
	return tr("ui.head_status.idle")


# head_status_controller 用：决定 status_text 要不要在气泡里显示
# （idle / moving 不显示，其他原样）。
func _should_show_head_status_bubble(status_text: String) -> bool:
	var normalized := status_text.strip_edges()
	if normalized.is_empty():
		return false
	return normalized != tr("ui.head_status.idle").strip_edges() \
		and normalized != tr("ui.head_status.moving").strip_edges()


# 吃 / 喝 / heal 等主动改变 hunger 的路径调一次：让 physiology 复检 hungry 阈值
# 立即清除"饥饿"状态。effects.gd 不该懂这块业务规则，所以走这里。
func refresh_conditions() -> void:
	MechanicHost.invoke("physiology", "on_hunger_changed", {
		"character": self,
		"hunger": hunger,
		"has_hungry": has_condition("hungry"),
	})
	head_status().sync_to_clients()
	state_io().persist()


# ─── Wallet (silver/gold currency) ────────────────────────────────────
# 价格 / 余额都用 centi 整数；1 silver = 100 centi。
# 显示层用 Money.format_silver_from_centi。LLM 看到的接口仍是 silver float。
# 拾取 silver_coin / gold_coin item 自动进 wallet（见 character_inventory.gd）。

func wallet_balance_centi() -> int:
	return wallet_centi


func wallet_balance_silver() -> float:
	return wallet_centi / 100.0


# 进账。amount 可正可负不限，负数走 wallet_spend 路径。
func wallet_add(centi: int) -> void:
	if centi == 0:
		return
	wallet_centi = maxi(0, wallet_centi + centi)
	state_io().persist()


# 扣账。够才扣，返回是否成功。
func wallet_spend(centi: int) -> bool:
	if centi <= 0:
		return true
	if wallet_centi < centi:
		return false
	wallet_centi -= centi
	state_io().persist()
	return true


# ─── 头顶气泡可读 API（HUD / 世界 UI）─────────────────
# bubble_state / speech / RPC override 都在 head_status() 上；本节只留外部展示用的
# anchor 计算和 display name 兜底，逻辑跟头顶气泡渲染语义同源。

func head_ui_world_position() -> Vector3:
	# Visual 是 top-level + 重度 Y 平滑过的稳定渲染节点；锚到它的 origin 上方固定 offset
	# 等同于挂一个不参与动画的"capsule 头标"。Visual 未初始化时退到根节点（启动瞬间）。
	var smoothed := visual_smoothing().active_visual_node()
	var src: Node3D = smoothed if is_instance_valid(smoothed) else self
	return src.get_global_transform_interpolated().origin + Vector3(0.0, head_ui_anchor_offset, 0.0)


func head_ui_display_name() -> String:
	var display_name := character_name.strip_edges()
	if not display_name.is_empty():
		return display_name
	var character_id := backend_character_id().strip_edges()
	return character_id if not character_id.is_empty() else String(name)


func head_ui_subtitle() -> String:
	return occupation.strip_edges()


# ─── @rpc shim（Godot 限制：RefCounted 不能持 @rpc，必须留 Node）───
# 真正状态/逻辑全在 HeadStatusController / SpeechController。

@rpc("authority", "call_remote", "reliable")
func show_speech(text: String, volume: String, target_character_id: String = "", affected_character_ids: PackedStringArray = PackedStringArray()) -> void:
	speech().handle_remote_speech(text, volume, target_character_id, affected_character_ids)


@rpc("authority", "call_remote", "reliable")
func show_action_label_rpc(text: String) -> void:
	head_status().apply_remote_override_text(text)


@rpc("authority", "call_remote", "reliable")
func hide_action_label_rpc() -> void:
	head_status().apply_remote_clear_override()


@rpc("authority", "call_remote", "reliable")
func set_status_label_rpc(text: String) -> void:
	head_status().apply_remote_status_text(text)


@rpc("authority", "call_remote", "reliable")
func set_thinking_status_rpc(active: bool) -> void:
	head_status().apply_remote_thinking(active)


# ─── 角色级工具方法（i18n / 世界事件 / 角色查找 / 背包索引）──────────
# Handlers / Controllers / TradeRunner 通过这几个公开方法访问 Character 能力。
# 它们本身不是 facade（不是 1-line forward），而是跨子系统都要用的公共操作。

# 物品 i18n 兜底：tr("item.<id>.name") → 找不到回 Items.by_id().display_name → 回 id。
func localize_item_name(item_id: String) -> String:
	if item_id.is_empty():
		return ""
	var localized := tr("item.%s.name" % item_id)
	if localized != "item.%s.name" % item_id:
		return localized
	var tmpl := Items.by_id(item_id)
	if tmpl != null and not tmpl.display_name.is_empty():
		return tmpl.display_name
	return item_id


# 通过 BackendRuntimeClient 发 world event；boot/non-runtime 时 no-op。
func emit_world_event(event_type: String, data: Dictionary) -> void:
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend != null and backend.has_method("send_world_event"):
		backend.call("send_world_event", event_type, data)


# 按 backend_character_id 在场景树里找 NPC / Player 节点。找不到返回 null。
func find_other_character(character_id: String) -> Character:
	if character_id.is_empty():
		return null
	var tree := get_tree()
	if tree == null:
		return null
	for group_name in ["npcs", "players"]:
		for node in tree.get_nodes_in_group(group_name):
			if node is Character and (node as Character).backend_character_id() == character_id:
				return node as Character
	return null


# 找背包里第一个非空且 item_id 匹配的槽位 index；找不到返回 -1。
func first_inventory_slot_for_item(item_id: String) -> int:
	for i in inventory.size():
		var slot: Dictionary = inventory[i]
		if str(slot.get("item_id", "")) == item_id and int(slot.get("quantity", 0)) > 0:
			return i
	return -1


# ─── 后端身份 + 物理 ─────────────────────────────────
# 子类各自给出 backend id：NPC 返回 npc_id，Player 返回 character_id（player_<8hex>）。

func backend_character_id() -> String:
	return ""


# 角色身份 snapshot —— 给 prompt / UI 用。NPC override 加配置文件里的字段（name/age 等）。
# 这是真 virtual：snapshots().ui_profile() 读它 + 外部 prompt 渲染直接读，不走 snapshots facade。
func soul_snapshot() -> Dictionary:
	var resolved_name := character_name.strip_edges()
	if resolved_name.is_empty():
		resolved_name = str(name).strip_edges()
	if resolved_name.is_empty():
		resolved_name = backend_character_id()
	var resolved_occupation := occupation.strip_edges()
	if resolved_occupation.is_empty():
		resolved_occupation = "未定义"
	var resolved_personality := personality.strip_edges()
	if resolved_personality.is_empty():
		resolved_personality = "未定义"
	return {
		"name": resolved_name,
		"age": character_age if character_age >= 0 else "未知",
		"occupation": resolved_occupation,
		"personality": resolved_personality,
	}


# 物理 accessor：override 优先 → material 默认 → -1
func ignition_point() -> float:
	if ignition_point_override >= 0.0:
		return ignition_point_override
	return material.ignite_temperature if material else -1.0


# ─── 熟练度 ───────────────────────────────────────────
# 工作台 craft 时按 reaction.skill_id 查这张表。真值在 Db.npc_proficiency 表：
# NPC 的初值由 Db boot 时从 npcs.json.proficiency seed；Player 从 0 起步靠 craft 攒；
# 两者都通过同一接口走 Db。详见 docs/proficiency_system.md。
func get_proficiency_table() -> Dictionary:
	var cid := backend_character_id()
	if cid.is_empty():
		return {}
	return Db.get_proficiency_table(cid)


# ─── 子类虚 hook ──────────────────────────────────────
# BackendActionRunner / FarmActionRunner / WorkstationActionRunner 通过这些 hook
# 让子类做自己的状态机切换（NPC vs Player 行为不同）。

# BackendActionRunner 在 walk 派发到位时调，子类切换自己的 walk 状态机。
# NPC: _state="walking"; anim_state="walking"
# Player: _has_target=true; anim_state="walking"
func _begin_action_walk(_action_id: String) -> void:
	pass


# BackendActionRunner 在 cancel 时调，子类清自己的 walk + 切 idle。
func _cancel_action_walk() -> void:
	walk().reset()


# BackendActionRunner finish 完调（在 send_perception_manifest 之后，completion 之前）。
# Player override 加 _ok_owner / _fail_owner 推 owner client 通知。
func _on_backend_action_finished(_ok: bool, _error: String, _result: Dictionary) -> void:
	pass


# WorkstationActionRunner 完成时调，子类把结果回报给 backend action。
func _on_workstation_action_completed(_summary: Dictionary) -> void:
	pass


# WorkstationActionRunner 内部进度推送：直接回上行 backend.report_action_progress。
func _on_backend_action_progress(summary: Dictionary) -> void:
	if summary.is_empty():
		return
	var action_id := backend_actions().current_action_id()
	if action_id.is_empty():
		return
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend != null and backend.has_method("report_action_progress"):
		backend.call("report_action_progress", action_id, summary)


# farm_action_runner 在每个 op 进入 working 状态 / 完成 / 取消时调用。
# 默认 noop —— NPC 头顶 label 已通过 head_status().push_override 处理；
# Player override 这三个 hook 触发 EventBus.player_action_started/completed/cancelled，
# 让 HUD 底部进度条显示。
func _on_farm_op_started(_label: String, _duration_game_seconds: float) -> void:
	pass


func _on_farm_op_completed(_message: String) -> void:
	pass


func _on_farm_op_cancelled(_reason: String) -> void:
	pass


# FarmActionRunner 队列消化完 / 被取消时调。NPC override 用来回报 plan_farm_work 的 action completion。
func _on_farm_queue_completed(_summary: Dictionary) -> void:
	pass


# FarmActionRunner 把"走到位置"指令告知子类的 nav agent。默认 noop —— 没 override 的角色
# （比如未来纯工厂 NPC）队列会卡住。
func _queue_walk_to(_pos: Vector3) -> void:
	pass


func _queue_stop_walking() -> void:
	pass


# ─── Backend agent action_request 入口（子类可 override 加自定义分支）───
# BackendRuntimeClient 调。NPC override 加 plan_farm_work 前置识别；普通分发委托
# backend_actions() runner。

func start_backend_action(action_request: Dictionary, completion: Callable) -> void:
	backend_actions().start(action_request, completion)


func cancel_backend_action(action_id: String, reason: String = "interrupted") -> String:
	return backend_actions().cancel(action_id, reason)


# 由 NPC / Player physics_process 每帧调一次：sleep / use_item deadline 检查。
# BackendActionRunner 本身无 timer 需要 tick，子系统各自驱动。
func _tick_backend_action(delta: float) -> void:
	sleep_controller().tick(delta)
	use_item_controller().tick(delta)
