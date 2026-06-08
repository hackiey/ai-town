@tool
class_name NPC
extends Character

# 基础 NPC：靠 backend action 驱动 move_to_location + instant actions + idle/walking 动画。
# 架构：CharacterBody3D wrap FantasyKingdom_Characters.fbx 实例（reimport 后 skeleton
# 是 humanoid 标准名）。23 个角色 mesh 共用 1 个 skeleton，script 隐藏 22 个只显示
# 一个。AnimationPlayer 在 NPC 根上（root_node 指 Visual），动画来自 Mixamo（也已
# reimport 成 humanoid 名），路径直接对得上。

@export var visible_mesh: String = "SM_Chr_Peasant_Male_01"
@export var npc_id: String = "":
	set(value):
		npc_id = value
		if is_inside_tree():
			call_deferred("_ensure_name_label")
@export var move_speed: float = 3.0  # 跟 Player 对齐，避免 NPC 跟不上玩家
@export var rotation_speed: float = 14.0
@export var gravity: float = 9.8
@export var settle_delay: float = 0.5
## stuck detection：walking 状态下若窗口期内 XZ 位移不足 → 视为卡住，fail action_request
## 自动 step-up：撞到 ≤ 此高度的台阶时自动抬腿越过（CharacterBody3D 不内置 step climb）
@export var step_assist_height: float = 0.5

const CHAR_MATERIAL := preload("res://third-party/polygon-fantasy-kingdom/Assets/PolygonFantasyKingdom/Materials/PolygonFantasyKingdom_Mat_01_A_mat.tres")
const MIN_SLEEP_NEEDED_HOURS := 8
const MAX_SLEEP_NEEDED_HOURS := 10
const DEFAULT_INITIAL_WAKE_TIME := "06:00"
const MIN_INITIAL_WAKE_MINUTE := 6 * 60
# backend/data/town/npcs.json 是 NPC soul / 初始起床时间的真值。Godot 启动时按需
# load 一次，cache 在 _NPCS_JSON_CACHE；起始背包由 Db seed 阶段写入 SQLite。
const _NPCS_JSON_REL := "backend/data/town/npcs.json"
const _NPCS_I18N_JSON_REL := "data/i18n/zh/npcs.json"
static var _NPCS_JSON_CACHE: Dictionary = {}
static var _NPCS_JSON_LOADED: bool = false
static var _NPCS_I18N_JSON_CACHE: Dictionary = {}
static var _NPCS_I18N_JSON_LOADED: bool = false
@onready var anim: AnimationPlayer = $AnimationPlayer
@onready var skel: Skeleton3D = $Visual/GeneralSkeleton
@onready var visual: Node3D = $Visual

var _state: String = "falling"   # falling | idle | walking
var _settle_timer: float = 0.0
var _step_assist_cooldown: float = 0.0
var _step_lift_remaining: float = 0.0   # 还要往上抬多少米
# 醉酒走路踉跄：每 ~0.5s 掷一次，命中则原地停顿 ~0.6s（drunk 专属，生病不触发）。
var _drunk_stumble_timer: float = 0.0
var _drunk_stumble_check: float = 0.0
const STEP_LIFT_DURATION := 0.12        # 抬起总时长（秒）
# 标记当前 backend command 是 plan_farm_work（用 farm queue 实现）。Queue drain 时
# 调用 _on_farm_queue_completed → 这里识别后把 summary 作为 result 回传给 backend ack。
# Backend action 状态全在 Character.BackendActionRunner（backend_actions()）里。
var _pending_plan_farm_work_action_id: String = ""
var _boot_wake_game_minute: int = -1
var _boot_awake: bool = false
var _boot_sleep_published: bool = false
var _boot_wake_published: bool = false
var _boot_wake_enabled: bool = true
var _backend_registered: bool = false

# 通过 MultiplayerSynchronizer 同步给 client。server 写入，client 监听变化播动画。
# 取值：idle | walking | falling
var anim_state: String = "idle":
	set(value):
		if anim_state == value:
			return
		anim_state = value
		_apply_anim_state(value)


func _apply_anim_state(state: String) -> void:
	match state:
		"idle", "falling", "working":
			# Phase 3：working 暂用 Idle pose 占位（等真正的 plant/water/pest 动画）
			_play("Idle")
		"walking":
			_play("Walking")


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		call_deferred("_ensure_name_label")


func _ready() -> void:
	super._ready()
	add_to_group("npcs")
	# server 端从 SQLite 拉一次 character_groups（boot 后由 backend seed 灌入），
	# diff 后 add_to_group。LLM 上下文里 visible_locations 用 self.groups 过滤就生效。
	if RunMode.is_runtime():
		reload_groups_from_db()
		inventory_ops().hydrate_from_db()
		_bind_backend_runtime_client()
		_register_with_backend()
		register_world_site()  # 注册 character:<npc_id> 动态 site（与静态地点同一 registry）
		if _is_backend_runtime_connected():
			_on_backend_runtime_connected.call_deferred()
	if not CharacterVisualSetup.apply_visible_mesh(skel, visible_mesh, CHAR_MATERIAL):
		push_warning("[NPC] visible_mesh '%s' not found under skeleton" % visible_mesh)
	_ensure_name_label()
	if Engine.is_editor_hint():
		return
	CharacterVisualSetup.patch_animation_tracks(anim)
	# 只有 headless server（runtime）端跑 backend 注册和物理；client 端是 puppet，
	# 接收 MultiplayerSynchronizer 推过来的 position/rotation/anim_state。
	# 用 RunMode 而非 is_multiplayer_authority，避免 multiplayer_peer 还没建好的窗口期。
	if RunMode.is_runtime():
		_boot_wake_enabled = _has_initial_wake_sleep_status()
		head_status().sync_to_clients()


func _ensure_name_label() -> void:
	var name_label := get_node_or_null("NameLabel") as Label3D
	if name_label != null:
		name_label.queue_free()
	var occupation_label := get_node_or_null("OccupationLabel") as Label3D
	if occupation_label != null:
		occupation_label.queue_free()


func head_ui_display_name() -> String:
	var conf := _get_npc_config(npc_id)
	return _localized_npc_field("name", str(conf.get("name", character_name if not character_name.strip_edges().is_empty() else npc_id)))


func head_ui_subtitle() -> String:
	var conf := _get_npc_config(npc_id)
	return _localized_npc_field("occupation", str(conf.get("occupation", occupation)))


func _localized_npc_field(field_name: String, fallback: String = "") -> String:
	var key := "npc.%s.%s" % [npc_id, field_name]
	var value := tr(key).strip_edges() if not npc_id.is_empty() else ""
	if value.is_empty() or value == key:
		value = _get_npc_i18n_field(npc_id, field_name)
	if value.is_empty():
		value = fallback.strip_edges()
	return value

# 懒加载 backend/data/town/npcs.json 到静态 cache。所有 NPC 实例共享。
# 路径相对 godot project 根（globalize_path("res://") + REL）。文件不存在或解析失败
# 都返回空 dict —— 上游用 .get(npc_id, {}) 安全读，缺字段自动 fallback。
static func _get_npc_config(npc_id_key: String) -> Dictionary:
	if not _NPCS_JSON_LOADED:
		_load_npcs_json()
	var entry: Variant = _NPCS_JSON_CACHE.get(npc_id_key, {})
	return entry if entry is Dictionary else {}


static func _get_npc_i18n_field(npc_id_key: String, field_name: String) -> String:
	if not _NPCS_I18N_JSON_LOADED:
		_load_npcs_i18n_json()
	var entry_v: Variant = _NPCS_I18N_JSON_CACHE.get(npc_id_key, {})
	if not (entry_v is Dictionary):
		return ""
	return str((entry_v as Dictionary).get(field_name, "")).strip_edges()


static func _load_npcs_json() -> void:
	_NPCS_JSON_LOADED = true
	var project_root := ProjectSettings.globalize_path("res://")
	var path := project_root.path_join(_NPCS_JSON_REL)
	if not FileAccess.file_exists(path):
		push_warning("[NPC] npcs.json not found at %s — NPC soul/inventory config disabled" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[NPC] failed to open %s" % path)
		return
	var raw := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		push_warning("[NPC] npcs.json root is not a dict")
		return
	_NPCS_JSON_CACHE = parsed


static func _load_npcs_i18n_json() -> void:
	_NPCS_I18N_JSON_LOADED = true
	var project_root := ProjectSettings.globalize_path("res://")
	var path := project_root.path_join(_NPCS_I18N_JSON_REL)
	if not FileAccess.file_exists(path):
		push_warning("[NPC] NPC i18n json not found at %s — editor occupation labels disabled" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_warning("[NPC] NPC i18n json root is not a dict")
		return
	var npc_entries_v: Variant = (parsed as Dictionary).get("npc", {})
	_NPCS_I18N_JSON_CACHE = npc_entries_v if npc_entries_v is Dictionary else {}


func _bind_backend_runtime_client() -> void:
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null:
		return
	var on_connected := Callable(self, "_on_backend_runtime_connected")
	if not backend.runtime_connected.is_connected(on_connected):
		backend.runtime_connected.connect(on_connected)


func _schedule_boot_wake() -> void:
	if not _boot_wake_enabled:
		return
	if _boot_wake_game_minute >= 0:
		return
	var now_minutes := _current_total_game_minutes()
	var day_minutes := GameClock.HOURS_PER_GAME_DAY * 60
	var now_minute_of_day := now_minutes % day_minutes
	var wake_minute_of_day := _initial_wake_minute_of_day()
	_boot_awake = false
	_boot_sleep_published = false
	_boot_wake_published = false
	if wake_minute_of_day <= now_minute_of_day:
		_boot_awake = true
		_boot_wake_game_minute = now_minutes
		_boot_wake_published = true
		sleep_controller().remove_sleeping_status()
		perception().send_manifest()
		return
	var delay_minutes := wake_minute_of_day - now_minute_of_day
	var day_start := now_minutes - now_minute_of_day
	_boot_wake_game_minute = day_start + wake_minute_of_day
	sleep_controller().add_sleeping_status(delay_minutes, "boot_sleep")
	_publish_boot_sleep_to_backend()


func _has_initial_wake_sleep_status() -> bool:
	for status_v in active_statuses:
		if not (status_v is Dictionary):
			continue
		var status: Dictionary = status_v as Dictionary
		var source := str(status.get("source_id", ""))
		if str(status.get("type", "")) == "sleeping" and (source == "initial_wake_time" or source == "boot_sleep"):
			return true
	return false


func _current_total_game_minutes() -> int:
	var clock := get_node_or_null("/root/GameClock")
	if clock == null or not clock.has_method("total_game_minutes"):
		return 0
	return int(clock.call("total_game_minutes"))


func _maybe_wake_from_boot() -> void:
	if _boot_awake or _boot_wake_game_minute < 0:
		return
	if _current_total_game_minutes() < _boot_wake_game_minute:
		return
	_boot_awake = true
	sleep_controller().remove_sleeping_status()
	rest = max_rest
	stamina = minf(max_stamina, snapshots().effective_stamina_max())
	state_io().persist()
	_register_with_backend()
	_publish_boot_wake_to_backend()


func _register_with_backend() -> void:
	if _backend_registered:
		return
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null or not backend.has_method("register_npc"):
		return
	backend.register_npc(self)
	_backend_registered = true


func _publish_boot_wake_to_backend() -> void:
	if not _boot_awake or _boot_wake_published:
		return
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null:
		return
	if not backend.has_method("is_runtime_connected") or not bool(backend.call("is_runtime_connected")):
		return
	perception().send_manifest()
	if not npc_id.is_empty() and backend.has_method("send_world_event"):
		backend.call("send_world_event", "woke_up", {
			"actorId": npc_id,
			"affectedCharacterIds": [npc_id],
			"durationGameMinutes": 0,
		})
	_boot_wake_published = true


func _publish_boot_sleep_to_backend() -> void:
	if _boot_awake or _boot_sleep_published:
		return
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null:
		return
	if not backend.has_method("is_runtime_connected") or not bool(backend.call("is_runtime_connected")):
		return
	perception().send_manifest()
	_boot_sleep_published = true


func _on_backend_runtime_connected() -> void:
	if not RunMode.is_runtime():
		return
	_register_with_backend()
	if not _boot_wake_enabled:
		return
	_schedule_boot_wake()
	if _boot_awake:
		_publish_boot_wake_to_backend()
	else:
		_publish_boot_sleep_to_backend()


func _is_backend_runtime_connected() -> bool:
	var backend := get_node_or_null("/root/BackendRuntimeClient")
	if backend == null or not backend.has_method("is_runtime_connected"):
		return false
	return bool(backend.call("is_runtime_connected"))


func _exit_tree() -> void:
	if RunMode.is_runtime():
		unregister_world_site()
		var backend := get_node_or_null("/root/BackendRuntimeClient")
		if backend != null:
			backend.unregister_npc(self)


func _physics_process(delta: float) -> void:
	visual_smoothing().update_smoothing(visual, delta)
	if not RunMode.is_runtime():
		return  # client puppet：位置 + 动画都靠 synchronizer 推过来
	_maybe_wake_from_boot()
	workstation_actions().tick(delta)
	_tick_backend_action(delta)
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	match _state:
		"falling":
			velocity.x = 0.0; velocity.z = 0.0
			if is_on_floor():
				_settle_timer += delta
				if _settle_timer >= settle_delay:
					_enter_idle()
		"idle":
			velocity.x = 0.0; velocity.z = 0.0
		"walking":
			# 全部用 XZ 平面距离判断 —— navmesh 高度可能跟 NPC 实际站立面差 0.5m+（Synty
			# 步道凸起在地面上，navmesh 在步道顶；NPC capsule 落到步道边的沙地里），
			# 用 3D 距离会让 agent 永远以为没到下一个 path 点而卡死
			var w := walk()
			var raw_to_target := nav.target_position - global_position
			var to_target_xz := Vector2(raw_to_target.x, raw_to_target.z)
			var next_pos := nav.get_next_path_position()
			var raw_to_next := next_pos - global_position
			var to_next_xz := Vector2(raw_to_next.x, raw_to_next.z)
			var arrival_distance := w.active_arrival_distance(nav.target_desired_distance)

			if to_target_xz.length() <= arrival_distance:
				# 当前 corridor waypoint 到了；pop 后还有 → 切下一个，没了 → 真到达 final
				var advance := w.advance_after_arrival()
				if bool(advance.get("finished", false)):
					velocity.x = 0.0; velocity.z = 0.0
					w.clear_final_distance()
					# 农事队列接管时不要 finish backend command —— queue tick 会进入 working
					if backend_actions().is_active() and not farm_actions().is_processing_op():
						backend_actions().finish(true, "", {})
					_enter_idle()
				else:
					nav.set_target_position(advance["next_target"] as Vector3)
					velocity.x = 0.0; velocity.z = 0.0
			else:
				# 距离 < 2m 进入"final approach"：直接瞄 target，忽略 path waypoint
				# （末端 path 点可能偏离 target，造成方向反转）。
				# 不做速度衰减 —— 衰减后 NPC 慢动作走最后一段，walk 动画看起来一直在播；
				# 全速冲到 target_desired_distance 内就 idle，干净利落。
				var dir_xz: Vector2
				# 见 player.gd 同名分支注释：sharp turn 拐点的方向稳定性比"NavAgent
				# stale waypoint 1-2 帧轻微反向"重要得多。除非 waypoint 完全退化
				# （length<0.05），否则始终跟 path。
				if to_next_xz.length() > 0.05:
					dir_xz = to_next_xz.normalized()
				else:
					dir_xz = to_target_xz.normalized()
				var speed := move_speed * snapshots().effective_move_speed_mult()
				velocity.x = dir_xz.x * speed
				velocity.z = dir_xz.y * speed   # Vector2.y → world Z
				rotation.y = lerp_angle(rotation.y, atan2(dir_xz.x, dir_xz.y), rotation_speed * delta)
	if _state == "walking":
		_apply_drunk_stumble(delta)
	var pre_pos := global_position
	var intent_xz := Vector2(velocity.x, velocity.z)
	move_and_slide()
	# Step-assist：walking 时若想走但实际进度不够（沿 action_request 方向投影 < 30% 期望），
	# 且前面是个小台阶 → 抬。投影而非长度避免被沿墙滑动的侧向位移骗过。
	_step_assist_cooldown -= delta
	if _state == "walking" and intent_xz.length() > 0.5 and _step_assist_cooldown <= 0.0:
		var moved_xz := Vector2(global_position.x - pre_pos.x, global_position.z - pre_pos.z)
		var intent_dir := intent_xz.normalized()
		var forward_progress := intent_dir.dot(moved_xz)
		if forward_progress < intent_xz.length() * delta * 0.3:
			_try_step_assist(intent_xz)

	# Stuck 监测：每帧累计无进展时间，超阈值触发 corridor recovery
	# （经 corridor 中转点重规划），耗尽次数才 fail action_request
	if _state == "walking" and walk().tick_stuck_progress(global_position, delta):
		_try_recover()

	# 农事队列推进：plan_farm_work action_request → enqueue → 此处一帧帧推 walking → working
	# → apply → 下一项。queue drain 时调 _on_farm_queue_completed，回传 summary 给 backend。
	farm_actions().tick(delta)
	head_status().sync_to_clients()


# 醉酒走路踉跄：醉了的 NPC 在 move_to 途中会莫名其妙停一下。仅 drunk 触发（生病不会）。
# 命中后把水平速度清零 ~0.6s，制造"踉跄/扶墙"的停顿；不改变路径，停完继续走。
func _apply_drunk_stumble(delta: float) -> void:
	var drunk := Impairment.drunk_level(self)
	if drunk < Impairment.DRUNK_TIPSY:
		_drunk_stumble_timer = 0.0
		_drunk_stumble_check = 0.0
		return
	if _drunk_stumble_timer > 0.0:
		_drunk_stumble_timer -= delta
		velocity.x = 0.0
		velocity.z = 0.0
		return
	_drunk_stumble_check += delta
	if _drunk_stumble_check >= 0.5:
		_drunk_stumble_check = 0.0
		if randf() < clampf(drunk / 200.0, 0.0, 0.9):
			_drunk_stumble_timer = 0.6
			velocity.x = 0.0
			velocity.z = 0.0


func _enter_idle() -> void:
	_state = "idle"
	anim_state = "idle"  # setter → _play("Idle")，并通过 synchronizer 推给 client
	# 走/falling 结束时位姿稳定 → 写一次 character_states 让重启能复位到这里
	state_io().persist()


func _current_anim_state() -> String:
	return anim_state


func _default_sleep_needed_hours() -> float:
	var seed_text := npc_id.strip_edges()
	if seed_text.is_empty():
		seed_text = String(name)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(abs(hash(seed_text)))
	return float(rng.randi_range(MIN_SLEEP_NEEDED_HOURS, MAX_SLEEP_NEEDED_HOURS))


func _initial_wake_minute_of_day() -> int:
	var conf := _get_npc_config(npc_id)
	var parsed := _parse_time_of_day_minutes(conf.get("initial_wake_time", DEFAULT_INITIAL_WAKE_TIME))
	if parsed >= 0:
		return maxi(parsed, MIN_INITIAL_WAKE_MINUTE)
	return MIN_INITIAL_WAKE_MINUTE


func _parse_time_of_day_minutes(value: Variant) -> int:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		var total := int(value)
		return total if total >= 0 and total < GameClock.HOURS_PER_GAME_DAY * 60 else -1
	var text := str(value).strip_edges()
	if text.is_empty():
		return -1
	var parts := text.split(":", false)
	if parts.size() != 2:
		return -1
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	var hour := int(parts[0])
	var minute := int(parts[1])
	if hour < 0 or hour >= GameClock.HOURS_PER_GAME_DAY or minute < 0 or minute >= 60:
		return -1
	return hour * 60 + minute


func _head_status_text() -> String:
	if sleep_controller().is_sleeping():
		return super._head_status_text()
	if _state == "walking":
		return tr("ui.head_status.moving")
	if (_workstation_runner != null and workstation_actions().is_active()) or farm_actions().active_state() == "working":
		return tr("ui.head_status.working")
	if backend_actions().is_active():
		return tr("ui.head_status.busy")
	return super._head_status_text()


func _play(anim_name: String) -> void:
	if anim.current_animation != anim_name and anim.has_animation(anim_name):
		# custom_blend=0 强制瞬时切，避免默认 blend time 让旧动画 fade out 一段
		anim.play(anim_name, 0.0)


func _try_step_assist(intent_xz: Vector2) -> void:
	# 用 NPC 自己的 collision shape 做 test_move：比 ray 精确、跟实际 move_and_slide
	# 一致。流程：① 在当前位置朝前推 0.15m 看会不会撞 ② 抬高 step_h 后再朝前推
	# ③ 落回地面验证有支撑 → 都满足就把 NPC 真的搬过去。
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

	# 安全，瞬时往前推 + 抬高。分帧抬过程中 capsule 跟台阶几何重叠 → move_and_slide
	# 每帧把人推回起点 → 等 lift 完成时已经被推下来了。瞬时抬虽然根节点会跳一下，
	# Character._update_client_visual_smoothing 平滑 Visual + CameraRig 的 Y damping
	# 一起把跳变吃掉。
	global_position += probe + Vector3(0, step_h, 0)
	# 短冷却 —— 楼梯一级接一级，1s 会让 NPC 一秒爬一级看起来像卡住；
	# test_move 自己会兜底过滤掉不该 step 的情况，可以放心调短
	_step_assist_cooldown = 0.15


# Backend action 派发已收口到 Character.BackendActionRunner；NPC override start /
# cancel 加 plan_farm_work 分支，并提供三个虚 hook（_begin_action_walk /
# _cancel_action_walk / _on_backend_action_finished）。

# plan_farm_work 不进 runner dispatch（它跑农事队列，完成靠 _on_farm_queue_completed
# 反过来调 runner.finish）。其他 action 全交给 runner.start。
func start_backend_action(action_request: Dictionary, completion: Callable) -> void:
	assert(RunMode.is_runtime(), "start_backend_action must run on headless server")
	if str(action_request.get("action", "")) == "plan_farm_work":
		var plan_err := _start_plan_farm_work(action_request, completion)
		if not plan_err.is_empty():
			# _start_plan_farm_work 失败时 runner 状态尚未置上，直接调 completion
			completion.call(false, plan_err, {})
		return
	backend_actions().start(action_request, completion)


# plan_farm_work 在外层单独处理 → 取消农事队列；其他走 runner.cancel。
func cancel_backend_action(action_id: String, reason: String = "interrupted") -> String:
	assert(RunMode.is_runtime(), "cancel_backend_action must run on headless server")
	if not backend_actions().is_active():
		return ""
	if not action_id.is_empty() and backend_actions().current_action_id() != action_id:
		return "active action_request mismatch: %s" % backend_actions().current_action_id()
	# plan_farm_work：先 cancel queue（内部会 _on_farm_queue_completed → runner.finish with summary）
	if not _pending_plan_farm_work_action_id.is_empty():
		farm_actions().cancel(reason)
		return ""
	var err := backend_actions().cancel(action_id, reason)
	return err


# 虚 hook：runner 派发到走位时调，切自己的 _state 状态机 + 动画。
func _begin_action_walk(action_id: String) -> void:
	_state = "walking"
	anim_state = "walking"  # setter → _play("Walking")，并通过 synchronizer 推给 client
	state_io().persist()


# 虚 hook：runner cancel 时调，重置 walk + 切 idle 状态机。
func _cancel_action_walk() -> void:
	walk().reset()
	velocity.x = 0.0
	velocity.z = 0.0
	if nav != null:
		nav.set_target_position(global_position)
	_enter_idle()


# Stuck 后调：runner.finish 标记失败，再切 idle。
func _try_recover() -> void:
	var err := walk().recover()
	if err.is_empty():
		return
	if backend_actions().is_active():
		backend_actions().finish(false, err, {})
	_enter_idle()


func backend_character_id() -> String:
	return npc_id


func soul_snapshot() -> Dictionary:
	var soul := super.soul_snapshot()
	var conf := _get_npc_config(npc_id)
	# 显示字段（name/occupation/personality/relationships/alias）已迁到 i18n catalog；
	# backend 按 character_id 自查 i18n。Godot 这边只补充非显示字段（age 等）。
	if character_name.strip_edges().is_empty() and conf.has("name"):
		soul["name"] = conf["name"]
	if character_age < 0 and conf.has("age"):
		soul["age"] = conf["age"]
	return soul


# plan_farm_work action_request 执行：解析 farm + ops → 编译 → 调 runner.start_external 把
# runner 状态置上 → enqueue 农事。不立刻 finish —— 等 _on_farm_queue_completed 把
# summary 回传时调 runner.finish。
func _start_plan_farm_work(action_request: Dictionary, completion: Callable) -> String:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return "plan_farm_work target must be object"
	var t: Dictionary = target as Dictionary
	var farm_id := str(t.get("farmId", ""))
	if farm_id.is_empty():
		return "plan_farm_work missing farmId"
	var farm := perception().resolve_farm_by_id(farm_id)
	if farm == null:
		return "plan_farm_work unknown farm: %s" % farm_id
	var ops_in: Variant = t.get("ops", [])
	if typeof(ops_in) != TYPE_ARRAY or (ops_in as Array).is_empty():
		return "plan_farm_work ops empty"
	var resolved: Array = []
	for op_v in (ops_in as Array):
		if typeof(op_v) != TYPE_DICTIONARY:
			continue
		var op: Dictionary = op_v as Dictionary
		var kind := String(op.get("kind", ""))
		match kind:
			"plant", "pest", "harvest", "uproot":
				var idx := int(op.get("slotIndex", -1))
				var slot := farm.slot_by_index(idx)
				if slot == null:
					continue
				var entry := {"kind": kind, "slot_index": idx, "slot_node": slot}
				if kind == "plant":
					entry["payload"] = String(op.get("seedItemId", ""))
				resolved.append(entry)
			"water":
				resolved.append({"kind": "water", "farm_node": farm, "slot_index": -1})
	if resolved.is_empty():
		return "plan_farm_work all ops invalid"
	_pending_plan_farm_work_action_id = String(action_request.get("id", ""))
	backend_actions().start_external(_pending_plan_farm_work_action_id, completion, "plan_farm_work", target)
	farm_actions().enqueue(resolved)
	return ""


# Character 队列回调 —— plan_farm_work 完成（含 cancelled）时把 summary 上报为 ack.result。
# 即使 interrupted=true，已完成项也是有用结果，按 ok 上报 → backend tool 能拿到 partial。
func _on_farm_queue_completed(summary: Dictionary) -> void:
	if _pending_plan_farm_work_action_id.is_empty():
		return
	_pending_plan_farm_work_action_id = ""
	backend_actions().finish(true, "", summary)


func _on_workstation_action_completed(summary: Dictionary) -> void:
	var action_completed := bool(summary.get("actionCompleted", false))
	var err := "" if action_completed else str(summary.get("message", "use_workstation failed"))
	backend_actions().finish(action_completed, err, summary)


# Character 队列调度 walking 阶段时调 —— NPC 用现成 corridor planner，并把 _state 切到
# "walking" 让 _physics_process 真正驱动 nav。queue arrival 检测在 base 类按距离判定，
# 比 NPC 自己的 corridor empty 检测早一帧到位，没问题。
func _queue_walk_to(pos: Vector3) -> void:
	walk().plan_to_world_position_or_direct(pos)
	_state = "walking"
	anim_state = "walking"


# 队列进入 working / cancel 时 stop walking。anim_state 不动 —— queue tick 紧接着会
# set "working"（或 cancel 时 set "idle"），避免一帧 idle 闪烁。
func _queue_stop_walking() -> void:
	walk().reset()
	velocity.x = 0.0
	velocity.z = 0.0
	if nav != null:
		nav.set_target_position(global_position)
	if _state == "walking":
		_state = "idle"
