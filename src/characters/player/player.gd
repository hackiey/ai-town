class_name Player
extends Character

# 玩家 avatar：server-authoritative。
# - server 拥有所有 Player 实例的 multiplayer authority（peer 1）
# - client 通过 @rpc 把"我想去 (x,y,z)"喊给 server
# - server 跑 nav + 物理，MultiplayerSynchronizer 把位置/朝向/动画状态推回给所有 client
# - client 端的 Player 是 puppet，渲染 + UI 用

@export var move_speed: float = 3.0
@export var rotation_speed: float = 14.0
@export var gravity: float = 9.8
## 自动 step-up：撞到 ≤ 此高度的台阶时自动抬腿越过（CharacterBody3D 不内置 step climb）。
## 跟环境台阶绝对高度挂钩，不要随 character scale 调。
@export var step_assist_height: float = 0.5
## 跟 NPC 一样从共享 FantasyKingdom_Characters skeleton 里挑出唯一可见的 mesh，
## 其余隐藏。npc.gd 用同套机制；FBX 默认无材质，要套上 CHAR_MATERIAL 否则白模。
@export var visible_mesh: String = "SM_Chr_King_01"

const CHAR_MATERIAL := preload("res://third-party/polygon-fantasy-kingdom/Assets/PolygonFantasyKingdom/Materials/PolygonFantasyKingdom_Mat_01_A_mat.tres")
const PLAYER_SLEEP_NEEDED_HOURS := 8.0

# 背包字段 + API 在 Character 基类（INVENTORY_SLOT_COUNT / inventory / add_item / ...）。
# Player 这边只负责 owner 同步（InventorySync）+ owner-RPC 入口（swap / use / drop）。

# 这个 avatar 属于哪个 client peer。spawn 时由 server 写入，spawn replication 推给 client。
# 纯传输层身份：用于 RPC 鉴权（sender == owner_peer_id）+ owner-private RPC 发送目标
# （rpc_id(owner_peer_id, ...)）+ owner 自检（owner_peer_id == multiplayer.get_unique_id()）。
# 业务/持久化身份用 character_id，不要把 owner_peer_id 拼成 id 字符串。
var owner_peer_id: int = 1

# 持久化身份。spawn 时由 server 写入（来自 Players.character_id_of_peer），spawn
# replication 推给 client。所有 backend / DB / log 路径用这个，不再 "player_%d" 拼接。
var character_id: String = ""

# 动画状态：server 写，client 通过 synchronizer 接收，setter 触发动画切换。
var anim_state: String = "idle":
	set(value):
		if anim_state == value:
			return
		anim_state = value
		_apply_anim_state(value)

@onready var anim: AnimationPlayer = $AnimationPlayer if has_node("AnimationPlayer") else null
@onready var skel: Skeleton3D = $Visual/GeneralSkeleton if has_node("Visual/GeneralSkeleton") else null
@onready var visual: Node3D = $Visual
@onready var _inventory_sync: MultiplayerSynchronizer = $InventorySync

# ─ 容器/货架分页查看（owner-private 同步，挂在 InventorySync）────────────────
# client 永远只持有「正在看的那一页」——整容器/货架内容绝不整发（treasury_vault 999 槽
# 序列化会超 ENet MTU）。server 逐帧把权威节点属性切片到 view_slots 推给 owner peer。
# 货架已统一为容器：货架槽位带 listing_price_centi aspect（标价），随 slot 一起同步。
var view_kind: String = ""          # "" | "container"（货架也是容器）
var view_target_id: String = ""
var view_page: int = 0
var view_page_size: int = 24
var view_page_count: int = 1
var view_slots: Array[Dictionary] = []
var view_wallet_centi: int = 0

# Client puppet 的 root transform 由 server 同步；Visual 在 client 端做轻量插值，
# 既抹掉网络/step-assist 的小跳动，也让 CameraRig 跟到平滑后的模型。

var _has_target: bool = false

# AI 托管状态（server 权威）。true = 当前由 backend two-track agent 操控，本地手操输入
# （走位/喊话/命令）在 server 端被拒；AI 自己经 start_backend_action 驱动，不走这些 RPC。
# 可逆：玩家点「取消托管」→ request_ai_release 置回 false。
var ai_controlled: bool = false

# 进行中的 craft（server-only）。空 = 空闲；非空 = 等 GameClock 走到 deadline 后 commit。
# 只能同时跑 1 个，新 request_craft 会被拒。schema:
#   { verb, workstation_id, sub_option, slot_indices: PackedInt32Array,
#     expected_item_ids: PackedStringArray, result: Dictionary,  # dispatcher 已 lock 的 outcome
#     duration_sec, started_at_game_seconds, deadline_game_seconds }
# duration_sec 单位是 game-second，跟着 GameClock.time_scale 走（/timewarp 1000 → craft 也加速）
var _active_craft: Dictionary = {}

# 进行中的物品使用动作（server-only）。完成前不扣物品、不应用脚本。
var _active_use_item: Dictionary = {}

# 工作台 staging（server-authoritative，owner-private 同步）。
# 玩家从背包拖入 ActionPanel = 物理搬运：背包 -1 + staged_items 对应槽 +1。
# 每个 slot 是完整 instance dict（item_id/quality/materials/.../quantity），跟 inventory slot 同结构。
# 长度固定 = STAGED_SLOT_COUNT；空 slot 用 InventorySlotData.empty()。
# 关 panel / cancel craft / 移动 → server 调 _return_all_staged() 全部退还到 inventory。
const STAGED_SLOT_COUNT := 6
var staged_items: Array = []

var _step_assist_cooldown: float = 0.0
var _step_lift_remaining: float = 0.0   # 还要往上抬多少米
const STEP_LIFT_DURATION := 0.12        # 抬起总时长（秒）


# Server-side RPC 入口的统一 owner 鉴权：sender 不是 owner peer 时 warn + 返回 true，
# 调用方写 `if _reject_if_not_owner("xxx"): return` 一行收口。
func _reject_if_not_owner(method_name: String) -> bool:
	var sender := multiplayer.get_remote_sender_id()
	if sender == owner_peer_id:
		return false
	push_warning("[player %s] %s from peer=%d but owner=%d" % [character_id, method_name, sender, owner_peer_id])
	return true


# AI 托管期间拒掉玩家手操入口（走位/喊话/命令），避免人和 AI 抢操作。
# 用法同 _reject_if_not_owner：`if _reject_if_ai_controlled("xxx"): return`。
func _reject_if_ai_controlled(method_name: String) -> bool:
	if not ai_controlled:
		return false
	_notify_owner("AI 托管中，已忽略手动操作（可点「取消托管」收回）", "warn")
	push_warning("[player %s] %s ignored: AI controlled" % [character_id, method_name])
	return true


func _ready() -> void:
	sleep_needed_hours = PLAYER_SLEEP_NEEDED_HOURS
	if RunMode.is_runtime():
		# 初始属性（背包/钱包/熟练度）真值在共享 player 模板，Db 读它来 seed（跟 NPC 同源）。
		Db.ensure_player_seeded(backend_character_id(), PLAYER_SLEEP_NEEDED_HOURS)
	super._ready()  # 基类 _ready 会调 _init_inventory()
	sleep_needed_hours = PLAYER_SLEEP_NEEDED_HOURS
	# MultiplayerSpawner spawn packets must land before this node sends path-based RPCs.
	head_status().set_rpc_enabled(false)
	add_to_group("players")
	# Phase 2：player 不再硬编码 god。从 SQLite 拉真实 group 成员资格；
	# 默认空（普通市民），开发期靠 /god 命令把自己加入 god group 看一切。
	# Db autoload 只在 server 进程可用；client 端的 player avatar 是 puppet，
	# 走 server 路径就行。
	if RunMode.is_runtime():
		reload_groups_from_db()
	_apply_visible_mesh()
	_patch_animation_tracks()
	_init_staged_items()
	# Craft 计时走 GameClock.game_seconds（_physics_process 里 poll deadline）
	if RunMode.is_runtime():
		# 只允许 owner peer 看到自己的背包。public_visibility=false 在 .tscn 里设。
		# spawn_function 已在 instantiate 时写好 owner_peer_id，所以这里直接用。
		_inventory_sync.set_visibility_for(owner_peer_id, true)
		inventory_ops().hydrate_from_db()
		var backend := get_node_or_null("/root/BackendRuntimeClient")
		if backend != null and backend.has_method("register_player"):
			backend.register_player(self)
		register_world_site()  # 注册 character:<character_id> 动态 site（与静态地点同一 registry）
		call_deferred("send_perception_manifest")
		_enable_head_status_rpc.call_deferred()


func _enable_head_status_rpc() -> void:
	if not RunMode.is_runtime() or not is_inside_tree():
		return
	head_status().set_rpc_enabled(true)
	head_status().sync_to_clients()


# 首次出现的玩家起始属性（背包/钱包/熟练度）真值在共享 player 模板
# backend/data/town/player-template.json，由 Db.ensure_player_seeded 读取写入 SQLite，
# Player 只 hydrate。注：water 不在起始包——液体只能存在于容器，玩家用桶去水井打水（按 E）。


func _try_step_assist(intent_xz: Vector2) -> void:
	# 用 player 自己的 collision shape 做 test_move：比 ray 精确、跟实际 move_and_slide
	# 一致。流程：① 在当前位置朝前推 0.15m 看会不会撞 ② 抬高 step_h 后再朝前推
	# ③ 落回地面验证有支撑 → 都满足就把 player 真的搬过去。
	var forward := Vector3(intent_xz.x, 0.0, intent_xz.y).normalized()
	var step_h := step_assist_height
	var probe := forward * 0.15

	# Step 1: 不抬高直接朝前推 → 应该撞东西（否则不算"被卡住"）
	if not test_move(global_transform, probe):
		_step_assist_cooldown = 0.3
		return

	# Step 2: 抬高 step_h 后再朝前推 → 应该没东西（说明 step 顶之上是空的）
	var lifted := global_transform.translated(Vector3(0, step_h, 0))
	if test_move(lifted, probe):
		_step_assist_cooldown = 0.3
		return

	# 安全，瞬时往前推 + 抬高。velocity.y 清零避免上一帧累积的 gravity 把人立刻拉下。
	global_position += probe + Vector3(0, step_h, 0)
	velocity.y = 0.0
	# 短冷却 —— 楼梯一级接一级，1s 会让 player 一秒爬一级看起来像卡住；
	# test_move 自己会兜底过滤掉不该 step 的情况，可以放心调短
	_step_assist_cooldown = 0.15


func _apply_visible_mesh() -> void:
	if not CharacterVisualSetup.apply_visible_mesh(skel, visible_mesh, CHAR_MATERIAL):
		push_warning("[player] visible_mesh '%s' not found under skeleton" % visible_mesh)


func _patch_animation_tracks() -> void:
	CharacterVisualSetup.patch_animation_tracks(anim)


func _current_anim_state() -> String:
	return anim_state


func _default_sleep_needed_hours() -> float:
	return PLAYER_SLEEP_NEEDED_HOURS


func _exit_tree() -> void:
	head_status().set_rpc_enabled(false)
	if RunMode.is_runtime():
		unregister_world_site()
		var backend := get_node_or_null("/root/BackendRuntimeClient")
		if backend != null and backend.has_method("unregister_player"):
			backend.unregister_player(self)


func _physics_process(delta: float) -> void:
	visual_smoothing().update_smoothing(visual, delta)
	# 唯一权威 = server。client puppet 只接收 synchronizer 推过来的 transform/anim_state。
	if not RunMode.is_runtime():
		return
	# 容器/货架分页查看：逐帧重算当前页（NPC 上架/买卖会改底层），on_change 同步给 owner。
	if not view_kind.is_empty():
		_recompute_view()
	# Craft deadline poll：duration 是 game-second，所以跟着 GameClock 走，timewarp 时也加速。
	if not _active_craft.is_empty():
		var deadline: float = float(_active_craft.get("deadline_game_seconds", 0.0))
		if GameClock.game_seconds >= deadline:
			_on_craft_timer_timeout()
	if not _active_use_item.is_empty():
		var use_deadline: float = float(_active_use_item.get("deadline_game_seconds", 0.0))
		if GameClock.game_seconds >= use_deadline:
			_on_use_item_timer_timeout()
	workstation_actions().tick(delta)
	_tick_backend_action(delta)
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	if _has_target:
		var w := walk()
		var raw_to_target := nav.target_position - global_position
		var to_target_xz := Vector2(raw_to_target.x, raw_to_target.z)
		var next_pos := nav.get_next_path_position()
		var to_next := next_pos - global_position
		var to_next_xz := Vector2(to_next.x, to_next.z)
		var arrival_distance := w.active_arrival_distance(nav.target_desired_distance)

		if to_target_xz.length() <= arrival_distance:
			# 到达当前 corridor waypoint。pop 后还有 → 设下一个；没了 → 真到达 final
			var advance := w.advance_after_arrival()
			if bool(advance.get("finished", false)):
				velocity.x = 0.0
				velocity.z = 0.0
				_has_target = false
				w.clear_final_distance()
				if backend_actions().is_active():
					backend_actions().finish(true, "", {})
				anim_state = "idle"
				# 走到位 → 位姿稳定，写一次 character_states
				state_io().persist()
			else:
				nav.set_target_position(advance["next_target"] as Vector3)
				velocity.x = 0.0
				velocity.z = 0.0
		else:
			var dir_xz: Vector2
			# 只看 path waypoint，除非它退化到跟当前位置几乎重合。
			# 历史教训（按时间顺序，写出来防止又加回去）：
			# 1. 最早有 to_target_xz<2m 就直奔 target 的短路 —— 在"路径绕远 + 终点
			#    直线方向有墙"的几何里让角色撞墙。删。
			# 2. 然后留 dot>0 同向检查兜底"NavAgent 跨路点 1-2 帧还返回旧路点"
			#    的退化 —— 但 sharp turn 处 to_next 跟 to_target 反向、dot<0
			#    会让角色无视寻路直奔 target 撞墙。删。
			# 3. 加 to_next_xz>1m 强制信任 path —— 但 sharp turn 拐点附近 d_next
			#    在 1m 上下抖动，跨阈值切换 dir 让角色每帧反向打颤。删。
			# 结论：waypoint 微小反向（最多一两帧 0.13m）是 NavAgent quirk
			# 的可接受代价，强行修反而引入更糟的 bug。length>0.05 只挡"路点完全
			# 重合"的纯退化。
			if to_next_xz.length() > 0.05:
				dir_xz = to_next_xz.normalized()
			else:
				dir_xz = to_target_xz.normalized()
			var speed := move_speed * snapshots().effective_move_speed_mult()
			velocity.x = dir_xz.x * speed
			velocity.z = dir_xz.y * speed
			rotation.y = lerp_angle(rotation.y, atan2(dir_xz.x, dir_xz.y), rotation_speed * delta)
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	var pre_pos := global_position
	var intent_xz := Vector2(velocity.x, velocity.z)
	move_and_slide()

	# Step-assist：移动中若想走但实际进度不够（沿 action_request 方向投影 < 30% 期望），
	# 且前面是个小台阶 → 抬。投影而非长度避免被沿墙滑动的侧向位移骗过。
	_step_assist_cooldown -= delta
	if _has_target and intent_xz.length() > 0.5 and _step_assist_cooldown <= 0.0:
		var moved_xz := Vector2(global_position.x - pre_pos.x, global_position.z - pre_pos.z)
		var intent_dir := intent_xz.normalized()
		var forward_progress := intent_dir.dot(moved_xz)
		if forward_progress < intent_xz.length() * delta * 0.3:
			_try_step_assist(intent_xz)

	# Stuck 监测：累计"想走但几乎没走"的时长，超过阈值触发 corridor recovery。
	# 用绝对位移而不是 forward_progress：避免被滑墙的侧向位移欺骗。
	if _has_target and walk().tick_stuck_progress(global_position, delta):
		_try_recover()

	# 农事队列推进。在 nav / craft poll 之后跑：walking 状态下按 global_position 判到位，
	# working 状态按 GameClock。_queue_walk_to override 会调 _start_walk_to_world_position
	# 设 nav target，下个 tick 自然走过去。
	farm_actions().tick(delta)
	head_status().sync_to_clients()


func _head_status_text() -> String:
	if sleep_controller().is_sleeping():
		return super._head_status_text()
	if _has_target or farm_actions().active_state() == "walking":
		return tr("ui.head_status.moving")
	if not _active_craft.is_empty():
		return tr("ui.head_status.crafting")
	if (_workstation_runner != null and workstation_actions().is_active()) or farm_actions().active_state() == "working" or water_draw_actions().is_active():
		return tr("ui.head_status.working")
	if backend_actions().is_active():
		return tr("ui.head_status.busy")
	return super._head_status_text()


# Client 调：player.request_move_to.rpc_id(1, world_pos, click_debug)
# Server 收到后校验 sender 是这个 avatar 的 owner，再 set nav target。
# 队列在跑时点击移动 → 自动取消队列再走（"自由移动打断队列"）。
@rpc("any_peer", "call_remote", "reliable")
func request_move_to(pos: Vector3, click_debug: Dictionary = {}) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_move_to"):
		return
	if _reject_if_ai_controlled("request_move_to"):
		return
	# 制造期间禁止移动；通知 client 弹确认。Yes → confirm_cancel_craft_and_move
	if not _active_craft.is_empty():
		_emit_walk_blocked_owner(pos)
		return
	if water_draw_actions().is_active():
		_cancel_active_water_draw(tr("ui.water_draw.cancelled_move"))
	var map_rid := nav.get_navigation_map()
	if not map_rid.is_valid():
		push_warning("[player %s] nav map not ready" % name)
		return
	if farm_actions().is_active():
		var summary := farm_actions().cancel("free movement")
		_notify_owner("已取消农事队列（完成 %d / 剩 %d）" % [
			(summary.get("completed", []) as Array).size(),
			(summary.get("remaining", []) as Array).size(),
		], "info")
	_cancel_non_backend_workstation_action("玩家移动")
	_preempt_backend_action_for_user_walk()
	var err := walk().plan_direct_to_world_position(pos)
	if not err.is_empty():
		push_warning("[player %s] request_move_to failed: %s" % [name, err])
		return
	_begin_player_walk()


func _describe_click_debug(click_debug: Dictionary) -> String:
	if click_debug.is_empty() or not bool(click_debug.get("hit", false)):
		return "<none>"
	var path := str(click_debug.get("path", ""))
	var layer := int(click_debug.get("layer", -1))
	var position: Vector3 = click_debug.get("position", Vector3.ZERO) as Vector3
	return "%s layer=%d pos=%s" % [path, layer, str(position)]


# Client 确认"取消 craft 并移动"。Server cancel 当前 craft（自动退还 staged 材料）+ 走过去。
@rpc("any_peer", "call_remote", "reliable")
func confirm_cancel_craft_and_move(pos: Vector3) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("confirm_cancel_craft_and_move"):
		return
	if not _active_craft.is_empty():
		_cancel_active_craft("玩家移动")
	if water_draw_actions().is_active():
		_cancel_active_water_draw(tr("ui.water_draw.cancelled_move"))
	_cancel_non_backend_workstation_action("玩家移动")
	_preempt_backend_action_for_user_walk()
	var err := walk().plan_direct_to_world_position(pos)
	if not err.is_empty():
		push_warning("[player %s] confirm_cancel walk failed: %s" % [name, err])
		return
	_begin_player_walk()


# Client 输入框 → 本地 player avatar.submit_player_command.rpc_id(1, text)。
# Server 校验 sender 是这个 avatar 的 owner 后，把文本发给 backend agent 那边解析。
# 本函数只是搬运，不做任何理解；backend 解析完会以 action.submit 形式发回，
# 再由 start_backend_action 执行。
@rpc("any_peer", "call_remote", "reliable")
func submit_player_command(text: String) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("submit_player_command"):
		return
	if _reject_if_ai_controlled("submit_player_command"):
		return
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null or not backend.has_method("submit_player_command"):
		push_warning("[player %s] BackendRuntimeClient unavailable, dropping command" % name)
		return
	perception().send_manifest()
	backend.submit_player_command(character_id, trimmed)


# ─── AI 托管（client → server，可逆开关）──────────────────────────
# 客户端弹窗选好 agent 类型 + 两个模型后调。server 发 ai_takeover world_event 给 backend，
# backend 把本玩家登记成 npc 管线（thinking 轨 + 触发）并 seed memory；同时本端置 ai_controlled。
@rpc("any_peer", "call_remote", "reliable")
func request_ai_takeover(agent_type: String, action_model: String, thinking_model: String) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_ai_takeover"):
		return
	if ai_controlled:
		_notify_owner("已经在 AI 托管中", "info")
		return
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null or not backend.has_method("send_world_event"):
		_fail_owner("无法连接 backend，托管失败")
		return
	var cid := backend_character_id()
	ai_controlled = true
	# 先 flush 一次感知，让 backend 起首轮 turn 时 context 是最新的。
	perception().send_manifest()
	backend.send_world_event("ai_takeover", {
		"actorId": cid,
		"affectedCharacterIds": [cid],
		"agentType": agent_type if not agent_type.is_empty() else "two-track",
		"actionModel": action_model,
		"thinkingModel": thinking_model,
	})
	_set_ai_controlled_owner(true)
	_ok_owner("已交给 AI 托管")


# 收回控制变回手动。打断 AI 正在跑的 backend action，通知 backend 注销 agent 路由。
@rpc("any_peer", "call_remote", "reliable")
func request_ai_release() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_ai_release"):
		return
	if not ai_controlled:
		return
	ai_controlled = false
	_preempt_backend_action_for_user_walk()
	var cid := backend_character_id()
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend != null and backend.has_method("send_world_event"):
		backend.send_world_event("ai_release", {
			"actorId": cid,
			"affectedCharacterIds": [cid],
		})
	_set_ai_controlled_owner(false)
	_ok_owner("已收回控制")


# 弹窗打开时 client 调：server 把 backend 缓存的可用模型回给 owner 填下拉。
@rpc("any_peer", "call_remote", "reliable")
func request_available_models() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_available_models"):
		return
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null:
		return
	if backend.has_method("request_available_models"):
		backend.request_available_models()  # 顺手刷新缓存，下次更准
	var models: Array = backend.get_available_models() if backend.has_method("get_available_models") else []
	var packed := PackedStringArray()
	for m in models:
		packed.append(str(m))
	_receive_available_models_owner(packed)


func _receive_available_models_owner(models: PackedStringArray) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.available_models_received.emit(models)
		return
	_receive_available_models_rpc.rpc_id(owner_peer_id, models)


@rpc("authority", "call_remote", "reliable")
func _receive_available_models_rpc(models: PackedStringArray) -> void:
	EventBus.available_models_received.emit(models)


func _set_ai_controlled_owner(active: bool) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.ai_takeover_state_changed.emit(active)
		return
	_set_ai_controlled_rpc.rpc_id(owner_peer_id, active)


@rpc("authority", "call_remote", "reliable")
func _set_ai_controlled_rpc(active: bool) -> void:
	EventBus.ai_takeover_state_changed.emit(active)


# Client 输入框里的普通文本 → 当成喊话发出去。直接构造 say_to world_event，
# 不走 start_backend_action / 假 action_request ack 链路。volume 默认 near，跟 NPC 一致。
@rpc("any_peer", "call_remote", "reliable")
func say_text(text: String, volume: String = "near") -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("say_text"):
		return
	if _reject_if_ai_controlled("say_text"):
		return
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return
	# 收口到 Character.emit_say（同时算听众、上行 world_event、广播气泡 RPC）
	var result := speech().emit_say(trimmed, volume)
	if not bool(result.get("ok", false)):
		push_warning("[player %s] say_to failed: %s" % [name, str(result.get("error", ""))])
		return


# ─── 背包 UI 触发的 RPC（client → server）──────────────────────
# 三个都是 owner 检查 → 改 server 权威 inventory → 通知 backend（swap 例外）。
# 有脚本/耗时的物品 use 会转入通用物品使用动作，完成后才结算并消耗 1 个。
# 改完会自动通过 InventorySync 推回 owner client，UI 在 _process 里浅比对触发重绘。

@rpc("any_peer", "call_remote", "reliable")
func request_use_item(slot_index: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_use_item"):
		return
	if slot_index < 0 or slot_index >= inventory.size():
		return
	var slot: Dictionary = inventory[slot_index]
	var item_id := str(slot.get("item_id", ""))
	if item_id.is_empty() or int(slot.get("quantity", 0)) <= 0:
		return
	_start_use_item_slot(slot_index, false)


@rpc("any_peer", "call_remote", "reliable")
func request_drop_item(slot_index: int, quantity: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_drop_item"):
		return
	if slot_index < 0 or slot_index >= inventory.size() or quantity <= 0:
		return
	var slot: Dictionary = inventory[slot_index]
	var item_id := str(slot.get("item_id", ""))
	if item_id.is_empty():
		return
	# 先快照 slot dict（保 quality / freshness / durability / displayed_effects），
	# 再 remove_item 改 inventory；最后用 snapshot.quantity = taken 的副本喂给 spawner。
	var snapshot: Dictionary = slot.duplicate(true)
	var taken := inventory_ops().remove_item(slot_index, quantity)
	if taken <= 0:
		return
	snapshot["quantity"] = taken
	GroundItemSpawner.spawn_for_character(self, snapshot)
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend != null and backend.has_method("send_world_event"):
		var actor := backend_character_id()
		# Wire contract: prose rendered by backend (event-descriptions/item.ts).
		backend.send_world_event("drop_item", {
			"actorId": actor,
			"affectedCharacterIds": [actor],
			"itemId": item_id,
			"quantity": taken,
		})
	perception().send_manifest()


# E 键拾取：client hover HUD 调 .rpc_id(1, target.get_path())。
# 全有全无（receive_inventory_stacks 内部带回滚）。校验距离防作弊。
@rpc("any_peer", "call_remote", "reliable")
func request_pickup_item(path: NodePath) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_pickup_item"):
		return
	var node := get_node_or_null(path)
	if node == null or not (node is GroundItem):
		return
	var gi: GroundItem = node
	# 拾取距离 = 该地面物品自己 SiteMarker 的可交互半径（逐对象，玩家/NPC 统一）。
	if global_position.distance_to(gi.global_position) > SiteMarker.interaction_radius_of(gi):
		_fail_owner("距离太远")
		return
	var qty := gi.quantity()
	if qty <= 0:
		gi.queue_free()
		return
	var stack: Dictionary = gi.slot_data.duplicate(true)
	stack["quantity"] = qty
	var stacks: Array[Dictionary] = [stack]
	var recv := inventory_ops().receive_stacks(stacks)
	if not bool(recv.get("ok", false)):
		_fail_owner(str(recv.get("message", tr("error.inventory.full"))))
		return
	var item_id := gi.item_id
	Db.delete_ground_item(gi.db_id)
	gi.queue_free()
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend != null and backend.has_method("send_world_event"):
		var actor := backend_character_id()
		backend.send_world_event("pick_up_item", {
			"actorId": actor,
			"affectedCharacterIds": [actor],
			"itemId": item_id,
			"quantity": qty,
		})
	perception().send_manifest()


# ─── slash 命令的 RPC（client → server）─────────────────────────
# /eat <slot> → 走通用 use_item，但要求目标必须是 food。
@rpc("any_peer", "call_remote", "reliable")
func request_eat_food(slot_index: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_eat_food"):
		return
	_start_use_item_slot(slot_index, true)


func _start_use_item_slot(slot_index: int, food_only: bool = false) -> void:
	if not _active_use_item.is_empty():
		_fail_owner("正在使用物品，请等当前完成")
		return
	if water_draw_actions().is_active():
		_fail_owner(str(TranslationServer.translate("error.water_draw.busy")))
		return
	if not _active_craft.is_empty():
		_fail_owner("正在制作中，不能使用物品")
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，不能使用物品")
		return
	var slot := inventory_ops().get_slot(slot_index)
	var view := InventorySlotData.of(slot)
	var use := ItemUse.resolve(view, food_only)
	if not bool(use.get("ok", false)):
		_fail_owner(str(use.get("message", "use_item failed")))
		return
	var item_id := str(use.get("item_id", view.id()))
	var duration := float(use.get("duration_seconds", 0.0))
	if duration <= 0.0:
		_complete_use_item_slot(slot_index, item_id, food_only)
		return
	_active_use_item = {
		"slot_index": slot_index,
		"item_id": item_id,
		"food_only": food_only,
		"duration": duration,
		"started_at_game_seconds": GameClock.game_seconds,
		"deadline_game_seconds": GameClock.game_seconds + duration,
	}
	var action_name := str(use.get("action_name", "使用物品"))
	head_status().push_override(action_name)
	_emit_player_action_started_owner(action_name, duration)


func _on_use_item_timer_timeout() -> void:
	if _active_use_item.is_empty():
		return
	var active := _active_use_item.duplicate(true)
	_active_use_item = {}
	head_status().clear_override()
	var slot_index := int(active.get("slot_index", -1))
	var expected_item_id := str(active.get("item_id", ""))
	var food_only := bool(active.get("food_only", false))
	_complete_use_item_slot(slot_index, expected_item_id, food_only)


func _complete_use_item_slot(slot_index: int, expected_item_id: String, food_only: bool) -> void:
	var slot := inventory_ops().get_slot(slot_index)
	var view := InventorySlotData.of(slot)
	var reason := ""
	if view.is_empty() or view.id() != expected_item_id:
		reason = "物品已不在原槽位"
		_emit_player_action_cancelled_owner(reason)
		_fail_owner(reason)
		return
	var use := ItemUse.resolve(view, food_only)
	if not bool(use.get("ok", false)):
		reason = str(use.get("message", "use_item failed"))
		_emit_player_action_cancelled_owner(reason)
		_fail_owner(reason)
		return
	var result := ItemUse.execute(self, view, use)
	if not result.get("ok", false):
		reason = "use_item 脚本错误：%s" % str(result.get("error", ""))
		_emit_player_action_cancelled_owner(reason)
		_fail_owner(reason)
		return
	inventory_ops().remove_item(slot_index, 1)
	var item := use.get("item") as Item
	if item != null and item.kind == "food":
		refresh_statuses()  # hunger 上升后立即清除 hungry status
	perception().send_manifest()
	var message := ItemUse.completion_message(item, self)
	_emit_player_action_completed_owner(message)
	_ok_owner(message)


# /plant <item_id> → 必须站在 FarmSlot 前方且 slot 空，server 端 spawn Crop 在 slot 上。
# item_id 需要 tags 含 "seed"，同时定义 crop_variety_id，比如 tomato_seed 或 wheat。
# 业务逻辑全在 character.gd:try_plant_seed_facing；这里只做 owner 鉴权 + 用户反馈。
@rpc("any_peer", "call_remote", "reliable")
func request_plant_seed(item_id: String) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_plant_seed"):
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，请等当前完成")
		return
	var result := farm_actions().try_plant_seed_facing(item_id)
	if not bool(result.get("ok", false)):
		_fail_owner("/plant " + str(result.get("message", "")))
		return
	perception().send_manifest()
	_ok_owner(str(result.get("message", "")))


# /water → 找正前方作物所属的农田，消耗 20 点水，让整片田 moisture +20%。
@rpc("any_peer", "call_remote", "reliable")
func request_water_crop() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_water_crop"):
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，请等当前完成")
		return
	var result := farm_actions().try_water_facing()
	if not bool(result.get("ok", false)):
		_fail_owner("/water " + str(result.get("message", "")))
		return
	_ok_owner(str(result.get("message", "")))


# /pest → 找正前方 1.5m 内最近 has_pest 的 Crop，清虫害。
@rpc("any_peer", "call_remote", "reliable")
func request_remove_pest() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_remove_pest"):
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，请等当前完成")
		return
	var result := farm_actions().try_remove_pest_facing()
	if not bool(result.get("ok", false)):
		_fail_owner("/pest " + str(result.get("message", "")))
		return
	_ok_owner(str(result.get("message", "")))


# /harvest → 找前方 1.5m 内最近的 ripe Crop，加产物到 inventory，
# multi-harvest variety 自动回到下一轮，single-harvest queue_free。
@rpc("any_peer", "call_remote", "reliable")
func request_harvest_crop() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_harvest_crop"):
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，请等当前完成")
		return
	var result := farm_actions().try_harvest_facing()
	if not bool(result.get("ok", false)):
		_fail_owner("/harvest " + str(result.get("message", "")))
		return
	perception().send_manifest()
	var leftover := int(result.get("leftover", 0))
	var message := str(result.get("message", ""))
	if leftover > 0:
		_notify_owner("%s，背包满丢失 %d" % [message, leftover], "warn")
	else:
		_ok_owner(message)


# 右键 NPC 菜单"说话"：ChatBar 定向模式下提交文本时调用。directed_target_id 指定听众。
# 实现复用 Character.emit_say —— 与 say_text 唯一差别是带 target_character_id。
@rpc("any_peer", "call_remote", "reliable")
func request_say_to_npc(target_id: String, text: String, volume: String = "near") -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_say_to_npc"):
		return
	if _reject_if_ai_controlled("request_say_to_npc"):
		return
	var trimmed_text := text.strip_edges()
	var trimmed_target := target_id.strip_edges()
	if trimmed_text.is_empty() or trimmed_target.is_empty():
		return
	var result := speech().emit_say(trimmed_text, volume, trimmed_target)
	if not bool(result.get("ok", false)):
		push_warning("[player %s] say_to %s failed: %s" % [name, trimmed_target, str(result.get("error", ""))])


# 右键 NPC 菜单"提出交易"：client TradePanel 构造完整的 offer action_request
# 后调用，server 端校验 owner + action 类型，转交 start_backend_action 走现有
# BackendActionRunner._run_offer pipeline。request 非空 → trade.lua mech → Db pending → 等
# NPC respond(kind:"trade") 回填；request:[] → _run_give 同步即时转移，立刻 finish。
@rpc("any_peer", "call_remote", "reliable")
func request_propose_trade(action_request: Dictionary) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_propose_trade"):
		return
	if str(action_request.get("action", "")) != "offer":
		_fail_owner("交易请求 action 类型必须为 offer")
		return
	var target_v: Variant = action_request.get("target", {})
	if typeof(target_v) != TYPE_DICTIONARY:
		_fail_owner("交易请求缺少 target 对象")
		return
	var target: Dictionary = target_v as Dictionary
	if str(target.get("characterId", "")).strip_edges().is_empty():
		_fail_owner("交易请求缺少对方角色")
		return
	# action_request 没带 id 就补一个，BackendActionRunner 需要 id 做去重 / 回填路由
	var ar := action_request.duplicate(true)
	if str(ar.get("id", "")).strip_edges().is_empty():
		ar["id"] = "ui_offer_%d" % Time.get_ticks_msec()
	var seller_label := _trade_target_display_name(str(target.get("characterId", "")).strip_edges())
	# 立刻通知玩家"已发送" —— offer 是 pending action（request 非空时），completion callback 要等
	# 对方 respond 完才会回调（参见 _resolve_pending_offer）。request:[] 则同步立即 finish。
	_ok_owner("已向 %s 发起交易，等待回应" % seller_label)
	start_backend_action(ar, func(ok: bool, err: String, result: Dictionary) -> void:
		_on_trade_completed(ok, err, result, seller_label)
	)


# 交易撮合结果（NPC respond 完之后）：accept 时 result 含 trade=Dictionary；
# reject 时 result.response == "reject"；start 时校验失败走 err。
func _on_trade_completed(ok: bool, err: String, result: Dictionary, seller_label: String) -> void:
	if not ok:
		_fail_owner("交易失败（%s）：%s" % [seller_label, err])
		return
	var response := str(result.get("response", ""))
	if response == "reject":
		_notify_owner("%s 拒绝了你的交易" % seller_label, "warn")
		return
	if response == "accept":
		_ok_owner("%s 接受了你的交易" % seller_label)
		return
	_ok_owner("交易完成（%s）" % seller_label)


func _trade_target_display_name(target_id: String) -> String:
	if target_id.is_empty():
		return "对方"
	for node in get_tree().get_nodes_in_group("npcs"):
		if not (node is Character):
			continue
		var ch := node as Character
		if ch.backend_character_id() == target_id:
			var disp := ch.head_ui_display_name().strip_edges()
			return disp if not disp.is_empty() else target_id
	return target_id


# 地图面板用：构造 action_request 直接走 player 的 move_to_location，跳过 backend AI。
@rpc("any_peer", "call_remote", "reliable")
func request_move_to_site(site_id: String) -> void:
	if not RunMode.is_runtime():
		return
	var action_request := {
		"id": "map_panel_%d" % Time.get_ticks_msec(),
		"action": "move_to_location",
		"target": {"locationId": site_id},
	}
	start_backend_action(action_request, func(_ok: bool, _err: String, _result: Dictionary) -> void: pass)


# FarmPanel 收单：client 把 (farm_id, ops) 发过来；ops 里只带 slot_index / kind / seed_id
# （RPC 不能传 Node ref）。Server 按 FarmGroup.effective_farm_id() 反查 FarmGroup → slot_index 反查 FarmSlot
# → 编出完整 op (含 slot_node/farm_node) → enqueue。校验失败的 op 跳过（broadcast warn）。
@rpc("any_peer", "call_remote", "reliable")
func request_queue_farm_actions(farm_id: String, ops: Array) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_queue_farm_actions"):
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，请等当前完成")
		return
	if ops.is_empty():
		return
	var farm := perception().resolve_farm_by_id(farm_id)
	if farm == null:
		_fail_owner("找不到农场：%s" % farm_id)
		return
	var resolved_ops: Array = []
	var dropped: int = 0
	for op_v in ops:
		var op: Dictionary = op_v
		var kind := String(op.get("kind", ""))
		match kind:
			"plant", "pest", "harvest", "uproot":
				var idx := int(op.get("slot_index", -1))
				var slot := farm.slot_by_index(idx)
				if slot == null:
					dropped += 1
					continue
				var resolved := {"kind": kind, "slot_index": idx, "slot_node": slot}
				if kind == "plant":
					resolved["payload"] = String(op.get("seed_id", ""))
				resolved_ops.append(resolved)
			"water":
				resolved_ops.append({"kind": "water", "farm_node": farm, "slot_index": -1})
			_:
				dropped += 1
	if resolved_ops.is_empty():
		_fail_owner("规划无效（dropped=%d）" % dropped)
		return
	farm_actions().enqueue(resolved_ops)
	var notice := "队列：%d 个动作（%s）" % [resolved_ops.size(), farm.effective_display_name()]
	if dropped > 0:
		notice += "，丢弃 %d 个无效项" % dropped
	_ok_owner(notice)


@rpc("any_peer", "call_remote", "reliable")
func request_cancel_farm_queue() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_cancel_farm_queue"):
		return
	if not farm_actions().is_active():
		_notify_owner("没有进行中的农事队列", "info")
		return
	var summary := farm_actions().cancel("user cancel")
	_ok_owner("已取消（完成 %d / 剩 %d）" % [
		(summary.get("completed", []) as Array).size(),
		(summary.get("remaining", []) as Array).size(),
	])


# /farmtest [seed_id=tomato_seed] → 找最近 FarmGroup 的前 3 个空 slot，排队种 3 颗。
# Phase A smoke：验证队列推进 / 走位 / label / cancel 闭环，不走 UI 面板。
@rpc("any_peer", "call_remote", "reliable")
func request_farm_test(seed_id: String) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_farm_test"):
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，请等当前完成")
		return
	if inventory_ops().count_item(seed_id) <= 0:
		_fail_owner("/farmtest 背包没有 %s（先 /give %s 5）" % [seed_id, seed_id])
		return
	# 找最近的 FarmGroup
	var nearest_group: FarmGroup = null
	var nearest_d := 9999.0
	for n in get_tree().get_nodes_in_group("farm_groups"):
		if not n is FarmGroup:
			continue
		var d := global_position.distance_to((n as Node3D).global_position)
		if d < nearest_d:
			nearest_d = d
			nearest_group = n as FarmGroup
	if nearest_group == null:
		_fail_owner("/farmtest 找不到 FarmGroup")
		return
	# 取前 3 个空 slot
	var ops: Array = []
	var idx := 0
	for child in nearest_group.get_children():
		if not child is FarmSlot:
			continue
		var slot := child as FarmSlot
		if slot.is_occupied():
			idx += 1
			continue
		ops.append({
			"kind": "plant",
			"slot_node": slot,
			"slot_index": idx,
			"payload": seed_id,
		})
		idx += 1
		if ops.size() >= 3:
			break
	if ops.is_empty():
		_fail_owner("/farmtest 农场已满")
		return
	farm_actions().enqueue(ops)
	_ok_owner("/farmtest 排队 %d 个 plant op (FarmGroup=%s)" % [ops.size(), nearest_group.effective_farm_id()])


# /timewarp <mult> → 改 GameClock.time_scale。debug only，无权限分级。
# /cast <mech> [arg1] [arg2] ... → 把当前玩家作为 caster，调用对应 mechanic 的 on_cast hook。
# ctx 给 lua: { caster, caster_id, candidates=[{id,distance,statuses,character}], args=[...],
#               game_hour, game_day, total_game_hours }。
# Lua 端 affect.* 已经够用（add_status / world_event / give_item / stamina / hunger / ...）。
@rpc("any_peer", "call_remote", "reliable")
func request_cast_spell(mech_name: String, args: PackedStringArray) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_cast_spell"):
		return
	if not MechanicHost.has_mechanic(mech_name):
		_fail_owner("/cast 未知机制：%s" % mech_name)
		return
	var caster_id := backend_character_id()
	var candidates: Array = []
	for node in perception().iter_other_characters():
		var other_id := perception().character_id_of(node)
		if other_id.is_empty():
			continue
		var other := node as Character
		candidates.append({
			"id": other_id,
			"distance": global_position.distance_to(node.global_position),
			"statuses": other.snapshots().active_status_ids() if other != null else [],
			"character": other,  # lua 用作 affect.add_status 的 target 句柄
		})
	var args_arr: Array = []
	for s in args:
		args_arr.append(s)
	var ctx := {
		"caster": self,
		"caster_id": caster_id,
		"candidates": candidates,
		"args": args_arr,
		"game_hour": GameClock.game_hour(),
		"game_day": GameClock.game_day(),
		"total_game_hours": GameClock.total_game_hours(),
	}
	var result := MechanicHost.invoke(mech_name, "on_cast", ctx)
	if not bool(result.get("ok", false)):
		_fail_owner("/cast %s 失败：%s" % [mech_name, str(result.get("error", ""))])
		return
	var rv: Variant = result.get("return_value")
	var summary := str((rv as Dictionary).get("summary", "")) if rv is Dictionary else ""
	if summary.is_empty():
		summary = "施放 %s（影响 %d 个 effect）" % [mech_name, (result.get("effects", []) as Array).size()]
	_ok_owner(summary)


@rpc("any_peer", "call_remote", "reliable")
func request_timewarp(multiplier: float) -> void:
	if not RunMode.is_runtime():
		return
	GameClock.set_time_scale(multiplier)
	_ok_owner("时间倍率已设为 %.2fx" % multiplier)


# /god → 切自己在 god group 的成员资格。完全本地（Db 直写 + 自调
# reload_groups_from_db），不再绕 backend WS——按"游戏运行不依赖 backend"
# 的原则，纯权限切换没必要走大脑那一圈。
@rpc("any_peer", "call_remote", "reliable")
func request_god_toggle() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_god_toggle"):
		return
	var character_id := backend_character_id()
	if character_id.is_empty():
		_fail_owner("/god 角色 id 缺失")
		return
	var was_god := Db.is_member_of(character_id, Db.GOD_GROUP)
	if was_god:
		Db.remove_member(character_id, Db.GOD_GROUP)
	else:
		Db.add_member(character_id, Db.GOD_GROUP, "runtime")
	reload_groups_from_db()
	_ok_owner("god 模式：%s" % ("ON" if not was_god else "OFF"))


# /give <item_id> [qty=1] [quality=100] → debug 给自己加物品。MVP 用来测试 craft / 食物
# 链；正式接入前可加 god-mode 权限检查，现在 dev 阶段直接放开。
@rpc("any_peer", "call_remote", "reliable")
func request_give(item_id: String, quantity: int, quality: int = Character.ITEM_DEFAULT_QUALITY) -> void:
	if not RunMode.is_runtime():
		return
	if not Items.has_id(item_id):
		_fail_owner("/give 未知物品：%s" % item_id)
		return
	var leftover := inventory_ops().add_item(item_id, quantity, quality)
	var added := quantity - leftover
	if leftover > 0:
		_notify_owner("/give 加入 %s x%d (q=%d)（背包满丢弃 %d）" % [item_id, added, quality, leftover], "warn")
	else:
		_ok_owner("/give 加入 %s x%d (q=%d)" % [item_id, added, quality])


# Crafting：ActionPanel "执行" → 这里。staged_items（已被物理搬到工作台）作为输入。
#
# Phase 2.5+staging 时序：
#   1. validate 没有进行中 craft + staged_items 非空
#   2. 跑 dispatcher 锁定 outcome（success/failure 在 start 时就掷骰）
#   3. 读 reaction.duration_seconds：> 0 → 启动 _craft_timer 等到期；= 0 → 立刻 commit
#   4. timer 到期触发 _on_craft_timer_timeout → commit outcome（消耗 staged，加输出到 inventory）
#   5. 中途 cancel（移动等）→ _return_all_staged 退还所有材料
#
# Server-only。Client 通过 EventBus craft_started/completed/cancelled 渲染进度条。
@rpc("any_peer", "call_remote", "reliable")
func request_craft(verb: String, workstation_id: String, sub_option: String) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_craft"):
		return
	if not _active_craft.is_empty():
		_fail_owner("正在制作中，请等当前完成")
		return
	if not _active_use_item.is_empty():
		_fail_owner("正在使用物品，请等当前完成")
		return
	if water_draw_actions().is_active():
		_fail_owner(str(TranslationServer.translate("error.water_draw.busy")))
		return
	if workstation_actions().is_active():
		_fail_owner("正在工作中，请等当前完成")
		return
	# 收集 staged_items 中所有非空 slot 作为 dispatcher 输入
	var instances: Array = []
	var staged_indices: PackedInt32Array = PackedInt32Array()
	for i in staged_items.size():
		var s: Dictionary = staged_items[i]
		if int(s.get("quantity", 0)) <= 0:
			continue
		instances.append(s.duplicate(true))
		staged_indices.append(i)
	if instances.is_empty():
		_fail_owner("工作台没有材料")
		return
	var result: Dictionary = Crafting.resolve(verb, workstation_id, sub_option, instances, get_proficiency_table())
	var outcome: String = result.get("outcome", "no_match")
	if outcome == "no_match":
		_fail_owner(String(result.get("message", tr("error.workstation.no_matching_reaction"))))
		return
	var duration: float = float(result.get("duration_seconds", 0.0))
	var reaction_label: String = WorkstationActionRunner.craft_label(verb, workstation_id, sub_option)
	if duration <= 0.0:
		_commit_craft_outcome(verb, workstation_id, sub_option, staged_indices, result)
		return
	_active_craft = {
		"verb": verb,
		"workstation_id": workstation_id,
		"sub_option": sub_option,
		"staged_indices": staged_indices,
		"result": result,
		"duration": duration,
		"started_at_game_seconds": GameClock.game_seconds,
		"deadline_game_seconds": GameClock.game_seconds + duration,
		"label": reaction_label,
	}
	_emit_craft_started_owner(reaction_label, duration)


# Deadline 到期（_physics_process 触发）：再校验 slot 仍持有 → commit；slot 已换 → cancel。
func _on_craft_timer_timeout() -> void:
	if _active_craft.is_empty():
		return
	var ac := _active_craft.duplicate(true)
	_active_craft = {}
	# Staging 模式下材料已经物理搬到 staged_items，commit 时直接消耗即可——不需要再校验
	# inventory（玩家无法在 craft 期间动 staged，因为 stage/unstage RPC 会被 _active_craft 拦下）
	_commit_craft_outcome(ac["verb"], ac["workstation_id"], ac["sub_option"], ac["staged_indices"], ac["result"])


# 显式中止（玩家死亡 / 新 craft 被拒后无影响 / Phase 4+ 的"离开工作站"路径）。
func _cancel_active_craft(reason: String) -> void:
	if _active_craft.is_empty():
		return
	_active_craft = {}
	_return_all_staged()
	_emit_craft_cancelled_owner(reason)


# ==============================================================================
# Workstation staging (server-authoritative)
# ==============================================================================
# 玩家拖背包 → ActionPanel = 物理搬运。背包 -1，staged_items 对应槽 +1（同 stack 合并）。
# server 持权威 staged_items；通过 InventorySync 推回 owner client（owner-private）。
# 时机：
#   - 关 panel / cancel craft / 玩家移动 → server 调 _return_all_staged()
#   - Execute → 用 staged_items 跑 dispatcher，consumed_input_indices 是 staged 的索引

func _init_staged_items() -> void:
	if not staged_items.is_empty():
		return
	for i in STAGED_SLOT_COUNT:
		staged_items.append(InventorySlotData.empty())


# amount<=0 = 全量（拖拽）；amount>0 = 指定量（分离面板选的份数/升数）。
# 液体容器 → 倒 amount 升进 staging（桶留 inventory、amount 扣减、记原桶）。
# 离散物品 → 放 amount 件进一个空 staging 槽（记原槽）。两者都记 origin_slot 供原路退回。
@rpc("any_peer", "call_remote", "reliable")
func request_stage_to_workstation(inv_slot: int, amount: int = 0) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_stage_to_workstation"):
		return
	if not _active_craft.is_empty():
		_fail_owner("制造中，无法调整材料")
		return
	if workstation_actions().is_active():
		_fail_owner("工作中，无法调整材料")
		return
	if inv_slot < 0 or inv_slot >= inventory.size():
		return
	var src: Dictionary = inventory[inv_slot]
	var src_qty := int(src.get("quantity", 0))
	if src_qty <= 0:
		return
	# 容器自动倒料：拖一个非空 liquid_container → 倒 N 升 content 进 staging。
	# "瓶子里的水也是水"——staging 看到的是液体 item 而非桶，dispatcher 不用知道桶存在；
	# 余量与原桶地址记在 staged 上，关面板/取出时原路倒回（见 _return_staged_slot）。
	if _is_pourable_container(src):
		_stage_pour(inv_slot, amount)
		return
	# 离散：把 N 件放进一个空 staging 槽（一个槽 = 一个配方输入实例）。
	var actual := mini(amount if amount > 0 else src_qty, src_qty)
	if actual <= 0:
		return
	var target_idx := _first_empty_staged_slot()
	if target_idx == -1:
		_fail_owner("工作台格子已满")
		return
	var staged := src.duplicate(true)
	staged["quantity"] = actual
	staged["origin_slot"] = inv_slot
	staged_items[target_idx] = staged
	staged_items = staged_items
	inventory_ops().remove_item(inv_slot, actual)


# 判定：是个有内容的液体容器（拖到工作台时倒内容物出来用）
func _is_pourable_container(slot: Dictionary) -> bool:
	var view := InventorySlotData.of(slot)
	if not view.has_tag("liquid_container"):
		return false
	var container := view.as_container()
	return container != null and not container.is_empty()


func _first_empty_staged_slot() -> int:
	for i in staged_items.size():
		if int((staged_items[i] as Dictionary).get("quantity", 0)) <= 0:
			return i
	return -1


# 倒 N 升内容物到 staging（合成 fluid_pouch，quantity=升数），桶 amount -= N。liters<=0 表示全量。
# 扣桶写平铺列 container_amount/container_content（properties 子 dict 已废弃），倒空时清发酵态。
# staged 记 origin_slot/pour_content 供原路倒回。
func _stage_pour(inv_slot: int, liters: int) -> void:
	var bucket: Dictionary = inventory[inv_slot]
	var container := InventorySlotData.of(bucket).as_container()
	if container == null or container.is_empty():
		return
	var content_id := container.content_id()
	var avail := int(floor(container.amount()))
	var n := avail if liters <= 0 else mini(liters, avail)
	if n <= 0:
		return
	var target_idx := _first_empty_staged_slot()
	if target_idx == -1:
		_fail_owner("工作台格子已满")
		return
	var poured := WorkstationActionRunner.poured_content_instance(bucket, content_id)
	poured["quantity"] = n
	poured["origin_slot"] = inv_slot
	poured["pour_content"] = content_id
	staged_items[target_idx] = poured
	var fields := container.with_consumed(float(n))
	bucket["container_amount"] = fields["container_amount"]
	bucket["container_content"] = fields["container_content"]
	if float(fields["container_amount"]) <= 0.0:
		bucket["transform_age"] = null
		bucket["transform_settle_hour"] = null
		bucket["ferment_ceiling"] = null
	inventory[inv_slot] = bucket
	staged_items = staged_items
	inventory = inventory
	inventory_ops().persist_slot(inv_slot)


# staging 上的合成键（不属于背包 slot schema），退回背包前剥掉。
func _strip_staging_keys(slot: Dictionary) -> void:
	slot.erase("origin_slot")
	slot.erase("pour_content")


# 通用原路退回：把 staged 槽里的 units 个单位退回背包。被 unstage / 关面板 / craft cancel 共用。
#  - 液体（有 pour_content）→ 倒回原桶（fill_from_source，校验原槽仍是同种或空容器、有余量）
#  - 离散 → 原槽优先（空则放、可堆叠则堆），剩余 add_instance（其它可堆叠槽 → 空槽）
# 返回成功退回的单位数；放不下/原桶失效 → push_error，剩余留在 staging（绝不丢、绝不乱倒）。
func _return_staged_slot(staged_idx: int, units: int) -> int:
	if staged_idx < 0 or staged_idx >= staged_items.size():
		return 0
	var staged: Dictionary = staged_items[staged_idx]
	var have := int(staged.get("quantity", 0))
	if have <= 0 or units <= 0:
		return 0
	var n := mini(units, have)
	var moved := _return_liquid_to_origin(staged, n) if staged.has("pour_content") else _return_discrete(staged, n)
	if moved <= 0:
		return 0
	var left := have - moved
	if left <= 0:
		staged_items[staged_idx] = InventorySlotData.empty()
	else:
		staged["quantity"] = left
		staged_items[staged_idx] = staged
	staged_items = staged_items
	return moved


# 液体原路倒回 origin_slot 指定的桶。严格回原桶（防止稀释别的桶）。返回倒回的升数。
func _return_liquid_to_origin(staged: Dictionary, n: int) -> int:
	var origin := int(staged.get("origin_slot", -1))
	var content := str(staged.get("pour_content", ""))
	if origin < 0 or origin >= inventory.size() or content.is_empty():
		push_error("[staging] 液体退回缺少原桶信息，留在工作台")
		return 0
	var bucket: Dictionary = inventory[origin]
	var container := InventorySlotData.of(bucket).as_container()
	if container == null:
		push_error("[staging] 原槽已不是液体容器，液体留在工作台")
		return 0
	if not container.is_empty() and container.content_id() != content:
		push_error("[staging] 原桶装了别的液体，液体留在工作台")
		return 0
	var res := LiquidOps.fill_from_source(bucket, content, float(staged.get("quality", 100)), float(n))
	if not bool(res.get("ok", false)):
		push_error("[staging] 液体倒回原桶失败：%s" % str(res.get("message", "")))
		return 0
	var moved := int(round(float(res.get("moved", 0.0))))
	if moved <= 0:
		return 0
	inventory[origin] = bucket
	inventory = inventory
	inventory_ops().persist_slot(origin)
	return moved


# 离散物品退回：原槽优先（空则放、可堆叠则堆到上限），剩余走 add_instance。返回退回件数。
func _return_discrete(staged: Dictionary, n: int) -> int:
	var origin := int(staged.get("origin_slot", -1))
	var remaining := n
	if origin >= 0 and origin < inventory.size():
		var dst: Dictionary = inventory[origin]
		var dst_view := InventorySlotData.of(dst)
		if dst_view.is_empty():
			var put := mini(remaining, Character.INVENTORY_STACK_MAX)
			var inst := staged.duplicate(true)
			_strip_staging_keys(inst)
			inst["quantity"] = put
			inventory[origin] = inst
			remaining -= put
			inventory = inventory
			inventory_ops().persist_slot(origin)
		elif dst_view.equals_stackable_with(InventorySlotData.of(staged)):
			var room := Character.INVENTORY_STACK_MAX - dst_view.quantity()
			var put := mini(remaining, room)
			if put > 0:
				dst["quantity"] = dst_view.quantity() + put
				inventory[origin] = dst
				remaining -= put
				inventory = inventory
				inventory_ops().persist_slot(origin)
	if remaining > 0:
		var inst2 := staged.duplicate(true)
		_strip_staging_keys(inst2)
		remaining = inventory_ops().add_instance(inst2, remaining)
	var moved := n - remaining
	if moved < n:
		push_error("[staging] 背包放不下退回物品，%d 件留在工作台" % remaining)
	return moved


@rpc("any_peer", "call_remote", "reliable")
func request_unstage_from_workstation(staged_idx: int, qty: int = 1) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_unstage_from_workstation"):
		return
	if not _active_craft.is_empty():
		_fail_owner("制造中，无法调整材料")
		return
	if workstation_actions().is_active():
		_fail_owner("工作中，无法调整材料")
		return
	if staged_idx < 0 or staged_idx >= staged_items.size():
		return
	var moved := _return_staged_slot(staged_idx, qty if qty > 0 else 1)
	if moved <= 0:
		_fail_owner("放不回背包")


# 灶台液体取出到玩家选定的目标容器（分离面板路径，区别于强制原桶的 _return_staged_slot）。
@rpc("any_peer", "call_remote", "reliable")
func request_unstage_liquid_to_container(staged_idx: int, target_backpack_slot: int, amount: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_unstage_liquid_to_container"):
		return
	if not _active_craft.is_empty():
		_fail_owner("制造中，无法调整材料")
		return
	if workstation_actions().is_active():
		_fail_owner("工作中，无法调整材料")
		return
	if staged_idx < 0 or staged_idx >= staged_items.size():
		return
	if target_backpack_slot < 0 or target_backpack_slot >= inventory.size() or amount <= 0:
		return
	var staged: Dictionary = staged_items[staged_idx]
	if not staged.has("pour_content"):
		_fail_owner("这个格子不是液体")
		return
	var have := int(staged.get("quantity", 0))
	if have <= 0:
		return
	var content := str(staged.get("pour_content", ""))
	var target: Dictionary = inventory[target_backpack_slot]
	var tcont := InventorySlotData.of(target).as_container()
	if tcont == null:
		_fail_owner("目标不是容器")
		return
	if not tcont.is_empty() and tcont.content_id() != content:
		_fail_owner("目标容器装着别的液体")
		return
	var n := mini(amount, have)
	var res := LiquidOps.fill_from_source(target, content, float(staged.get("quality", 100)), float(n))
	if not bool(res.get("ok", false)):
		_fail_owner(str(res.get("message", tr("error.liquid.transfer_failed"))))
		return
	var moved := int(round(float(res.get("moved", 0.0))))
	if moved <= 0:
		_fail_owner("目标容器满了")
		return
	inventory[target_backpack_slot] = target
	var left := have - moved
	if left <= 0:
		staged_items[staged_idx] = InventorySlotData.empty()
	else:
		staged["quantity"] = left
		staged_items[staged_idx] = staged
	staged_items = staged_items
	inventory = inventory
	inventory_ops().persist_slot(target_backpack_slot)


# ==============================================================================
# Container UI RPCs (server-authoritative; client UI 调，server 校验 access 后真正搬运)
# ==============================================================================

@rpc("any_peer", "call_remote", "reliable")
func request_container_take(container_id: String, container_slot_index: int, qty: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_container_take"):
		return
	if qty <= 0:
		return
	var node := Containers.find_container_node_near(container_id, global_position)
	if node == null:
		_fail_owner("找不到容器")
		return
	if not _container_access_ok(node):
		return
	var shelf_mode := node is ShelfNode or node.is_in_group("shelves")
	var price_centi := 0
	var take_qty := qty
	if shelf_mode:
		var slots: Array = Containers.adapter_slots(node)
		if container_slot_index < 0 or container_slot_index >= slots.size():
			_fail_owner("货架槽无效")
			return
		var shelf_slot: Dictionary = slots[container_slot_index]
		var shelf_view := InventorySlotData.of(shelf_slot)
		if shelf_view.is_empty():
			_fail_owner("货架格里没有物品")
			return
		take_qty = mini(qty, shelf_view.quantity())
		var price_v: Variant = shelf_slot.get("listing_price_centi", null)
		price_centi = maxi(0, int(price_v)) if price_v != null else 0
		var estimated_cost := price_centi * take_qty
		if estimated_cost > wallet_balance_centi():
			_fail_owner("钱包余额不足（需要 %s，有 %s）" % [
				Money.format_silver_from_centi(estimated_cost),
				Money.format_silver_from_centi(wallet_balance_centi()),
			])
			return
	var take_result: Dictionary = Containers.adapter_take(node, {"slot_index": container_slot_index}, take_qty)
	var stacks_v: Variant = take_result.get("stacks", [])
	var stacks: Array[Dictionary] = []
	if stacks_v is Array:
		for s in (stacks_v as Array):
			if s is Dictionary:
				stacks.append(s as Dictionary)
	if stacks.is_empty():
		_fail_owner("容器格里没有物品")
		return
	var actual_qty := 0
	var receive_stacks: Array[Dictionary] = []
	for stack in stacks:
		actual_qty += int(stack.get("quantity", 0))
		var receive_stack := stack.duplicate(true)
		if shelf_mode:
			receive_stack["listing_price_centi"] = null
		receive_stacks.append(receive_stack)
	var receive: Dictionary = inventory_ops().receive_stacks(receive_stacks)
	if not bool(receive.get("ok", false)):
		# 背包装不下 → 把刚取出的塞回容器，避免吞物
		Containers.adapter_place(node, stacks)
		_fail_owner(str(receive.get("message", tr("error.inventory.full"))))
		return
	var actual_cost := price_centi * actual_qty if shelf_mode else 0
	if actual_cost > 0:
		var pay := inventory_ops().pay_centi(actual_cost)
		if not bool(pay.get("ok", false)):
			var received_stacks: Array[Dictionary] = []
			var received_v: Variant = receive.get("stacks", [])
			if received_v is Array:
				for r in (received_v as Array):
					if r is Dictionary:
						received_stacks.append(r as Dictionary)
			inventory_ops().rollback_received_stacks(received_stacks)
			Containers.adapter_place(node, stacks)
			_fail_owner(str(pay.get("message", tr("error.money.not_enough"))))
			return
		Containers.wallet_add_centi(container_id, actual_cost)


@rpc("any_peer", "call_remote", "reliable")
func request_container_put(container_id: String, player_slot_index: int, qty: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_container_put"):
		return
	if qty <= 0:
		return
	var node := Containers.find_container_node_near(container_id, global_position)
	if node == null:
		_fail_owner("找不到容器")
		return
	if not _container_access_ok(node):
		return
	var extracted := inventory_ops().extract_stack(player_slot_index, qty)
	if extracted.is_empty():
		_fail_owner("背包槽无物品")
		return
	var place: Dictionary = Containers.adapter_place(node, [extracted])
	var leftover_v: Variant = place.get("leftover", [])
	if leftover_v is Array and not (leftover_v as Array).is_empty():
		var leftover: Array[Dictionary] = []
		for l in (leftover_v as Array):
			if l is Dictionary:
				leftover.append(l as Dictionary)
		# 容器装不下 → 退回背包
		inventory_ops().receive_stacks(leftover)
		if int(place.get("placed_qty", 0)) <= 0:
		_fail_owner(str(place.get("message", tr("error.container.full"))))


@rpc("any_peer", "call_remote", "reliable")
func request_container_wallet_transfer(container_id: String, direction: String, centi: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_container_wallet_transfer"):
		return
	centi = maxi(0, centi)
	if centi <= 0:
		return
	var node := Containers.find_container_node_near(container_id, global_position)
	if node == null:
		_fail_owner("找不到容器")
		return
	if not _container_access_ok(node):
		return
	match direction:
		"put":
			var pay := inventory_ops().pay_centi(centi)
			if not bool(pay.get("ok", false)):
				_fail_owner(str(pay.get("message", tr("error.money.not_enough"))))
				return
			Containers.wallet_add_centi(container_id, centi)
		"take":
			if not Containers.wallet_spend_centi(container_id, centi):
				_fail_owner("容器钱包余额不足")
				return
			wallet_add(centi)
		_:
			return
	emit_world_event("container_put_take", {
		"actorId": backend_character_id(),
		"affectedCharacterIds": perception().voice_affected_character_ids("far"),
		"moves": [{"kind": "item", "itemId": "silver_coin", "amount": centi / 100.0}],
	})
	perception().send_manifest()
	_recompute_view()


# 玩家专用打水：从无限液体源（水井）把 amount 升灌进背包里指定的液体容器。
# 玩家走独立 RPC + WaterDrawPanel，但提交的仍是与 NPC 等价的 put_take transfer；
# 耗时/体力/缩水结算统一由 WaterDrawRunner 处理。
@rpc("any_peer", "call_remote", "reliable")
func request_draw_water(container_id: String, backpack_slot_index: int, amount: float) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_draw_water"):
		return
	var action_request: Dictionary = {
		"target": {
			"transfers": [{
				"kind": "liquid",
				"amount": amount,
				"from": {"where": "well", "containerId": container_id},
				"to": {"where": "backpack", "slotIndex": backpack_slot_index},
			}],
		},
	}
	var started: Dictionary = water_draw_actions().start_from_put_take(action_request, Callable(self, "_on_player_water_draw_completed"))
	if not bool(started.get("ok", false)):
		_fail_owner(str(started.get("message", TranslationServer.translate("error.water_draw.failed"))))
		return
	_emit_player_action_started_owner(tr("ui.water_draw.action_label"), float(started.get("duration_seconds", 0.0)))


func _on_player_water_draw_completed(ok: bool, error: String, result: Dictionary) -> void:
	if not ok:
		_fail_water_draw(error if not error.is_empty() else str(TranslationServer.translate("error.water_draw.failed")))
		return
	var moved := _sum_water_draw_moves(result.get("moves", []))
	var message := tr("ui.water_draw.completed_format") % moved
	_emit_player_action_completed_owner(message)
	_ok_owner(message)


func _fail_water_draw(message: String) -> void:
	_emit_player_action_cancelled_owner(message)
	_fail_owner(message)


func _cancel_active_water_draw(reason: String) -> void:
	if not water_draw_actions().is_active():
		return
	water_draw_actions().cancel(reason)
	_emit_player_action_cancelled_owner(reason)


func _sum_water_draw_moves(moves_v: Variant) -> float:
	var total := 0.0
	if typeof(moves_v) != TYPE_ARRAY:
		return total
	var moves: Array = moves_v as Array
	for move_v in moves:
		if typeof(move_v) != TYPE_DICTIONARY:
			continue
		var move := move_v as Dictionary
		if str(move.get("kind", "")) == "liquid" and str(move.get("content", "")) == "water":
			total += float(move.get("amount", 0.0))
	return total


# 玩家专用倒液体：把一个液体容器的内容倒进另一个。container_id="" 表示背包槽，否则附近容器节点槽。
# 复用 NPC 同一套 endpoint 解析 + LiquidOps.transfer_between_slots（服务端权威、距离/锁 server 裁）。
@rpc("any_peer", "call_remote", "reliable")
func request_pour_liquid(from_container_id: String, from_slot: int, to_container_id: String, to_slot: int, amount: float) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_pour_liquid"):
		return
	if amount <= 0.0:
		return
	var from_res := ContainerHandlers._resolve_liquid_endpoint(self, _pour_endpoint(from_container_id, from_slot))
	if not bool(from_res.get("ok", false)):
		_fail_owner(str(from_res.get("message", tr("error.container.invalid_source"))))
		return
	var to_res := ContainerHandlers._resolve_liquid_endpoint(self, _pour_endpoint(to_container_id, to_slot))
	if not bool(to_res.get("ok", false)):
		_fail_owner(str(to_res.get("message", tr("error.container.invalid_target"))))
		return
	var result := LiquidOps.transfer_between_slots(from_res["slot"], to_res["slot"], amount)
	if not bool(result.get("ok", false)):
		_fail_owner(str(result.get("message", tr("error.liquid.transfer_failed"))))
		return
	(from_res["commit"] as Callable).call()
	(to_res["commit"] as Callable).call()
	var moved := float(result.get("moved", 0.0))
	var content := str((to_res["slot"] as Dictionary).get("container_content", ""))
	emit_world_event("container_put_take", {
		"actorId": backend_character_id(),
		"affectedCharacterIds": perception().voice_affected_character_ids("far"),
		"moves": [{"kind": "liquid", "content": content, "amount": moved}],
	})


func _pour_endpoint(container_id: String, slot_index: int) -> Dictionary:
	if container_id.strip_edges().is_empty():
		return {"where": "backpack", "slotIndex": slot_index}
	return {"where": "node", "containerId": container_id, "slotIndex": slot_index}


# 玩家专用酿酒：给一个装水的酿酒桶 + 背包原料起头发酵。复用 NPC 同一 BrewHandlers.run_brew
# （服务端权威：配方读反应表、扣原料、定上限、写发酵态；之后 PassiveSimulator 推进品质）。
# container_id="" 表示背包槽，否则附近容器节点槽（酒桶仓库）。recipe_id = 反应表里的发酵反应 id。
@rpc("any_peer", "call_remote", "reliable")
func request_brew(container_id: String, slot_index: int, recipe_id: String) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_brew"):
		return
	# run_brew 读 action_request.target.barrel + action_request.recipe，barrel 要包在 target 里
	# （与 NPC brew 动作同形状），不能把 barrel 平铺在顶层，否则取不到酒桶 endpoint。
	var action_request := {
		"target": {"barrel": _pour_endpoint(container_id, slot_index)},
		"recipe": recipe_id,
	}
	var res := BrewHandlers.run_brew(self, action_request)
	if not bool(res.get("ok", false)):
		_fail_owner(str(res.get("message", tr("error.brew.failed"))))


# ─ 容器/货架分页查看 ──────────────────────────────────────────────────────
# 货架已统一为无锁容器（ShelfNode extends ContainerNode），面板/存取全走 ContainerPanel
# + request_container_take/put。面板打开/翻页/关闭时由 ContainerPanel 调（client→server
# 控制信号）。页数据经 owner-private synchronizer（view_slots）回传，不走 RPC 发数据。
# kind="" 关闭查看。
@rpc("any_peer", "call_remote", "reliable")
func request_view(kind: String, target_id: String, page: int, page_size: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_view"):
		return
	view_kind = kind
	view_target_id = target_id
	view_page = maxi(page, 0)
	view_page_size = clampi(page_size, 1, 64)
	_recompute_view()


# server-only：把当前查看目标的权威内容切到 view_page 这一页，写进 view_slots（同步给 owner）。
# 逐帧调（_physics_process）以反映 NPC 存取；on_change 同步，同内容不会重发。
func _recompute_view() -> void:
	if view_kind.is_empty():
		if not view_slots.is_empty():
			view_slots = []
			view_page_count = 1
		view_wallet_centi = 0
		return
	var all_slots: Array = []
	var wallet := 0
	if view_kind == "container":
		# 货架也是 ContainerNode，统一从 Containers 查（含货架标价 listing_price_centi）。
		var node := Containers.find_container_node_near(view_target_id, global_position)
		if node != null:
			all_slots = Containers.adapter_slots(node)
			wallet = Containers.wallet_balance_centi(view_target_id)
	var total := all_slots.size()
	var size := maxi(view_page_size, 1)
	view_page_count = maxi(1, int(ceil(float(total) / float(size))))
	var page := clampi(view_page, 0, view_page_count - 1)
	var start := page * size
	var page_slots: Array[Dictionary] = []
	for i in range(start, mini(start + size, total)):
		page_slots.append(all_slots[i])
	view_slots = page_slots
	view_wallet_centi = wallet


func _container_access_ok(node: Node) -> bool:
	if node == null:
		return false
	if not node.can_actually_use(self):
		var nm := String(node.effective_display_name()) if node.has_method("effective_display_name") else String(node.name)
		if not node.can_be_used_by(self):
			_fail_owner(tr("ui.container.msg_no_access") % nm)
		else:
			var key_id := String(node.lock_item_id) if node.get("lock_item_id") != null else ""
			var key_label := tr("item.%s.name" % key_id)
			if key_label == "item.%s.name" % key_id:
				key_label = key_id
			_fail_owner(tr("ui.container.msg_no_key") % [nm, key_label])
		return false
	var reach := SiteMarker.interaction_radius_of(node)
	if global_position.distance_squared_to(node.global_position) > reach * reach:
		var nm2 := String(node.effective_display_name()) if node.has_method("effective_display_name") else String(node.name)
		_fail_owner(tr("ui.container.msg_too_far") % nm2)
		return false
	return true


@rpc("any_peer", "call_remote", "reliable")
func request_clear_staging() -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_clear_staging"):
		return
	if not _active_craft.is_empty():
		_fail_owner("制造中，无法调整材料")
		return
	if workstation_actions().is_active():
		_fail_owner("工作中，无法调整材料")
		return
	_return_all_staged()


# Server-only：把所有 staged 退还到背包。craft 期间外随时可调。背包满 → 留在 staged。
func _return_all_staged() -> void:
	if staged_items.is_empty():
		return
	# 逐槽原路退回：液体→原桶、离散→原槽优先（见 _return_staged_slot）。
	for i in staged_items.size():
		var q := int((staged_items[i] as Dictionary).get("quantity", 0))
		if q > 0:
			_return_staged_slot(i, q)


# 应用 outcome：success 加 outputs，failure 弹消息。consume/return 按 dispatcher 索引扣。
# 复用：duration=0 立即调；duration>0 timer 到期调。
func _commit_craft_outcome(verb: String, workstation_id: String, sub_option: String,
		staged_indices: PackedInt32Array, result: Dictionary) -> void:
	# Staging 模式下 consumed_input_indices 是"传给 dispatcher 的 instances 数组中的索引"，
	# 通过 staged_indices 映射回 staged_items 的真实槽，扣减 qty。
	if WorkstationActionRunner.consume_staged_inputs(
			staged_items,
			staged_indices,
			result.get("consumed_input_indices", [])
	):
		staged_items = staged_items

	var summary := WorkstationActionRunner.apply_outputs_to_character(self, result, {
		"workstation_id": workstation_id,
		"verb": verb,
		"sub_option": sub_option,
	})
	var summary_text := str(summary.get("message", tr("tool.tool_result.workstation.completed")))
	if bool(summary.get("ok", false)):
		_ok_owner(summary_text)
		var qm := float(summary.get("quality_modifier", 1.0))
		if qm < 0.999:
			var lvl := "warn" if qm < 0.5 else "info"
			_notify_owner("材料配比偏离，品质 ×%.0f%%" % (qm * 100.0), lvl)
		for leftover in summary.get("leftover_outputs", []):
			_notify_owner("制造产出 %s 没放下（背包满）" % str(leftover), "warn")
	else:
		_notify_owner(summary_text, "warn")
	# 熟练度持久化：把 lua 算好的 delta 应用回 Db（见 docs/proficiency_system.md）。
	var prof_skill_id: String = str(result.get("proficiency_skill_id", ""))
	var prof_delta: float = float(result.get("proficiency_delta", 0.0))
	if not prof_skill_id.is_empty() and absf(prof_delta) > 0.0001:
		var prof_before: float = float(result.get("proficiency_before", 0.0))
		var prof_after: float = clampf(prof_before + prof_delta, 0.0, 100.0)
		Db.upsert_proficiency(backend_character_id(), prof_skill_id, prof_after)
	# 制造完成后未消耗的 staged 材料（failure 退还的 + batch 富余等）自动归还背包
	_return_all_staged()
	_emit_craft_completed_owner(summary_text)
	perception().send_manifest()


# Owner-only craft 生命周期通知：转 EventBus，ActionPanel 渲染进度条。
# 与 _notify_owner 同一套 owner-self-emit 模式：单机 host 直接 emit；远端走 RPC。
func _emit_craft_started_owner(reaction_name: String, duration_sec: float) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.craft_started.emit(reaction_name, duration_sec)
		return
	_craft_started_rpc.rpc_id(owner_peer_id, reaction_name, duration_sec)


func _emit_craft_completed_owner(message: String) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.craft_completed.emit(message)
		return
	_craft_completed_rpc.rpc_id(owner_peer_id, message)


func _emit_craft_cancelled_owner(reason: String) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.craft_cancelled.emit(reason)
		return
	_craft_cancelled_rpc.rpc_id(owner_peer_id, reason)


func _emit_player_action_started_owner(action_name: String, duration_sec: float) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.player_action_started.emit(action_name, duration_sec)
		return
	_player_action_started_rpc.rpc_id(owner_peer_id, action_name, duration_sec)


func _emit_player_action_completed_owner(message: String) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.player_action_completed.emit(message)
		return
	_player_action_completed_rpc.rpc_id(owner_peer_id, message)


func _emit_player_action_cancelled_owner(reason: String) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.player_action_cancelled.emit(reason)
		return
	_player_action_cancelled_rpc.rpc_id(owner_peer_id, reason)


# Character 虚 hook 重载：farm_action_runner 每 op 进 working 时调，让玩家 HUD 显进度条。
# duration 是 game-seconds（ActionPanel 用 GameClock.game_seconds 算进度）。
func _on_farm_op_started(label: String, duration_game_seconds: float) -> void:
	_emit_player_action_started_owner(label, duration_game_seconds)


func _on_farm_op_completed(message: String) -> void:
	_emit_player_action_completed_owner(message)


func _on_farm_op_cancelled(reason: String) -> void:
	_emit_player_action_cancelled_owner(reason)


func _emit_walk_blocked_owner(target_pos: Vector3) -> void:
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.craft_walk_block_requested.emit(target_pos)
		return
	_walk_blocked_rpc.rpc_id(owner_peer_id, target_pos)


@rpc("authority", "call_remote", "reliable")
func _craft_started_rpc(reaction_name: String, duration_sec: float) -> void:
	EventBus.craft_started.emit(reaction_name, duration_sec)


@rpc("authority", "call_remote", "reliable")
func _craft_completed_rpc(message: String) -> void:
	EventBus.craft_completed.emit(message)


@rpc("authority", "call_remote", "reliable")
func _craft_cancelled_rpc(reason: String) -> void:
	EventBus.craft_cancelled.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _player_action_started_rpc(action_name: String, duration_sec: float) -> void:
	EventBus.player_action_started.emit(action_name, duration_sec)


@rpc("authority", "call_remote", "reliable")
func _player_action_completed_rpc(message: String) -> void:
	EventBus.player_action_completed.emit(message)


@rpc("authority", "call_remote", "reliable")
func _player_action_cancelled_rpc(reason: String) -> void:
	EventBus.player_action_cancelled.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _walk_blocked_rpc(target_pos: Vector3) -> void:
	EventBus.craft_walk_block_requested.emit(target_pos)


# 纯 UI 重排：只换位置，不改总量、不发 world event。同 id 不自动合并 —— 等需要再加。
@rpc("any_peer", "call_remote", "reliable")
func request_swap_slots(a: int, b: int) -> void:
	if not RunMode.is_runtime():
		return
	if _reject_if_not_owner("request_swap_slots"):
		return
	if a == b:
		return
	if a < 0 or a >= inventory.size() or b < 0 or b >= inventory.size():
		return
	var sa: Dictionary = inventory[a]
	inventory[a] = inventory[b]
	inventory[b] = sa
	inventory = inventory  # trigger MultiplayerSynchronizer
	var cid := backend_character_id()
	Db.save_inventory_slot(cid, a, inventory[a])
	Db.save_inventory_slot(cid, b, inventory[b])


func backend_character_id() -> String:
	return character_id


# Backend action 派发已收口到 Character.BackendActionRunner；Player 只 override 三个虚 hook：
# - _begin_action_walk：套用 _begin_player_walk（has_target + anim）
# - _cancel_action_walk：清 walk + 切 idle，并显式 print 留 trace
# - _on_backend_action_finished：把 ok / error 推 owner client 当聊天通知

func _begin_action_walk(_action_id: String) -> void:
	_begin_player_walk()


func _cancel_action_walk() -> void:
	walk().reset()
	_has_target = false
	velocity.x = 0.0
	velocity.z = 0.0
	if nav != null:
		nav.set_target_position(global_position)
	anim_state = "idle"


func _on_backend_action_finished(ok: bool, error: String, _result: Dictionary) -> void:
	if ok:
		_ok_owner("AI 指令完成")
	else:
		_fail_owner("AI 指令失败：%s" % error)


# Stuck recovery：撞墙时 corridor planner 找新中转点；走不通则 fail action_request。
func _try_recover() -> void:
	var err := walk().recover()
	if err.is_empty():
		return
	_has_target = false
	anim_state = "idle"
	if backend_actions().is_active():
		backend_actions().finish(false, err, {})


func _on_workstation_action_completed(summary: Dictionary) -> void:
	var action_completed := bool(summary.get("actionCompleted", false))
	var message := str(summary.get("message", "use_workstation failed"))
	if backend_actions().is_active():
		var err := "" if action_completed else message
		backend_actions().finish(action_completed, err, summary)
		return
	if action_completed:
		_emit_player_action_completed_owner(message)
		_ok_owner(message)
	else:
		_emit_player_action_cancelled_owner(message)
		_fail_owner(message)


# ─── Server → owner client 通知（聊天 log 系统行）──────────────────
# 设计：server 端权威逻辑里出现需要让玩家看见的事件（命令成功/失败、原因等），
# 走 _notify_owner 单点 RPC 推回 owner peer，client 端转 EventBus → chat_bar 渲染。
# level: "info" | "success" | "warn" | "error"。

func _notify_owner(text: String, level: String = "info") -> void:
	# server 端调；owner 是 host 自己（peer 1，offline 单机）时直接 emit，免得没必要的 RPC。
	if not RunMode.is_runtime():
		return
	if owner_peer_id == multiplayer.get_unique_id():
		EventBus.notification_posted.emit(text, level)
		return
	_notify_owner_rpc.rpc_id(owner_peer_id, text, level)


func _ok_owner(text: String) -> void:
	_notify_owner(text, "success")


func _fail_owner(text: String) -> void:
	_notify_owner(text, "error")


@rpc("authority", "call_remote", "reliable")
func _notify_owner_rpc(text: String, level: String) -> void:
	# client 端收到 server 推过来的通知 → 转给 EventBus，chat_bar 订阅。
	EventBus.notification_posted.emit(text, level)


func _character_attributes() -> Dictionary:
	return {
		"hp": { "current": roundf(hp), "max": roundf(max_hp) },
		"stamina": { "current": roundf(stamina), "max": roundf(snapshots().effective_stamina_max()) },
		"hunger": { "current": roundf(hunger), "max": roundf(max_hunger) },
		"rest": { "current": roundf(rest), "max": roundf(max_rest) },
	}


func _equipped_items() -> Array[String]:
	var items: Array[String] = []
	for slot_name in equipped.keys():
		var item_id := str(equipped[slot_name])
		if not item_id.is_empty():
			items.append("%s: %s" % [slot_name, item_id])
	return items


func _apply_anim_state(state: String) -> void:
	if anim == null:
		return
	# Phase 3：working 暂时复用 Idle pose 占位（等 Mixamo plant/water/pest 真动画）
	var name_ := "Walking" if state == "walking" else "Idle"
	if anim.current_animation != name_ and anim.has_animation(name_):
		anim.play(name_, 0.0)


# Character.enqueue_farm_actions 的 walking 阶段调这个：把 nav target 接到 corridor planner。
# 失败（如 NavMesh 不可达）会 push_warning，下个 tick 队列还在 walking 状态原地等到位
# —— 这是设计选择：既然 walked nowhere，到位条件永远不满足，下个 cancel/timeout 会清掉。
# Phase D 可以加 timeout 防卡死。
func _queue_walk_to(pos: Vector3) -> void:
	var err := walk().plan_to_world_position(pos)
	if not err.is_empty():
		push_warning("[player %s] queue walk failed: %s" % [name, err])
		return
	_begin_player_walk()


func _begin_player_walk() -> void:
	_has_target = true
	anim_state = "walking"


# 玩家点地自由移动 / confirm_cancel_craft_and_move 入口调：若当前还跑着 backend action
# （典型是 move_to_location 走到一半），先 cancel 掉再切到点地路径。
# 不 cancel 的话，新 nav target 替掉旧的，玩家走到点击点 → _physics_process 走 finish(true)
# 分支，把"完成 move_to_location 到 X"事件错发到点击点附近（而不是真正的 X 附近）。
func _preempt_backend_action_for_user_walk() -> void:
	if not backend_actions().is_active():
		return
	var action_id := backend_actions().current_action_id()
	backend_actions().cancel(action_id, "玩家点地中断")


func _cancel_non_backend_workstation_action(reason: String) -> void:
	if not workstation_actions().is_active() or backend_actions().is_active():
		return
	workstation_actions().cancel(reason)
	_emit_player_action_cancelled_owner(reason)
	_notify_owner("已取消工作：%s" % reason, "info")


# 队列进入 working / cancel 时调：清掉 corridor / has_target，让 _physics_process 不再继续推 velocity。
# 物理 capsule 自然停在原地。
func _queue_stop_walking() -> void:
	walk().reset()
	_has_target = false
	velocity.x = 0.0
	velocity.z = 0.0
	if nav != null:
		nav.set_target_position(global_position)
