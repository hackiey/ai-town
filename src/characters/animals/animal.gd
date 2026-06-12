@tool
class_name Animal
extends CharacterBody3D

# 轻量动物：在 spawn 点周围散养游荡，播自带 idle/walk 动画。
#
# **不是 Character**——没有背包 / 饥饿 / 钱包 / group / backend agent。比 NPC 简单得多：
# 每个 Quaternius 模型自带 Skeleton3D + AnimationPlayer + 烘焙好的 clip，runtime 直接用
# 模型自己的 AnimationPlayer，不需要人物 Mixamo 那套 BoneMap 重定向。
#
# 架构（见 src/characters/animals/README.md）：
#   Animal [CharacterBody3D]      ← animal.gd（本脚本）
#     CollisionShape3D            ← 按物种体型在 _ready 重建胶囊
#     NavigationAgent3D
#     Visual [Node3D]             ← 成年 scale 在这（species 场景的 Visual.scale，目视调好）
#       Model [Node3D]            ← species/<id>.tscn 烘焙的物种模型，带 Skeleton3D + AnimationPlayer
#     MultiplayerSynchronizer     ← 同步 position/rotation/anim_state/alive
#     SiteMarker                  ← Phase 1 仅占位（不注册）；Phase 3 接交互/感知时再 register
#
# animal.tscn / wild_animal.tscn 是**抽象 base**（Visual 空、无模型）；真正放进世界 / spawn 的
# 是每个物种的 species/<id>.tscn——它继承 base、把模型烘焙在 Visual 下、Visual.scale 设成调好的
# 成年缩放。所以每只动物可在编辑器里单独拖 gizmo 调 scale（_build_visual 取 Visual.scale 当 base）。
# @tool：编辑器里 _ready 也跑 _build_visual（找模型 + 对地 + 调试预览）。
# 物理 / 游荡只在 RunMode.is_runtime() 的 server 上跑；client 是 puppet，靠 synchronizer。

# 同一物种的所有 clip 命名差异在这里吸收：farm 包带 `Armature|` 前缀，animated 包干净名。
const _CLIP_CANDIDATES := {
	"idle": ["Idle"],
	"walk": ["Walk"],
	"walk_slow": ["WalkSlow", "Walk_Slow"],
	"trot": ["Trot"],
	"run": ["Run", "Gallop"],
	"jump": ["Jump", "Hop"],
	"death": ["Death"],
	# 蹄类动物的攻击叫 Attack_Headbutt / Attack_Kick；犬科/狐/狼是干净的 Attack。
	"attack": ["Attack", "Attack_Headbutt", "Attack_Kick"],
	"hit": ["Idle_HitReact1", "Idle_HitReact_Left", "Idle_HitReact_Right", "HitReact"],
	"eat": ["Eating", "Eat"],
}
const _CLIP_PREFIXES := ["", "Armature|", "AnimalArmature|"]
# 只有 idle 是必需（每个模型都有）→ 缺它 fail-loud。
const _REQUIRED_CLIPS := ["idle"]

# 游荡用的移动 clip 优先级：从"最像平地慢走"到兜底，取该模型**第一个有的**。每条带速度档：
#   "move" = move_speed（正常移动）、"hop" = hop_speed（蹦跳兜底，慢一些）。
# 想加新移动动作：在 _CLIP_CANDIDATES 加 logical，再往这里按顺序插一行即可（见 _resolve_locomotion）。
# 排序理由：walk 最自然 → walk_slow/trot 次之 → run/gallop（只有跑的物种也能动）→ jump 蹦跳（farm
# 包 Sheep/Llama/Pig/Pug 只剩它）。都没有才永远原地 idle。
const _LOCOMOTION_PRIORITY := [
	["walk", "move"],
	["walk_slow", "move"],
	["trot", "move"],
	["run", "move"],
	["jump", "hop"],
]

# 每个物种一个 species/<id>.tscn（见 animal_species.gd.scene_path），模型 + scale 烘焙在
# 场景里——所以编辑器里改这个字段不再换模型（模型是场景烘焙的，不是 runtime 实例化）。
@export var species_id: String = "cow"
## 散养身份；Phase 2 持久化 / Phase 3 site 注册用。Phase 1 可留空。
@export var animal_id: String = ""
## scene 预放的 founder 默认成年（放下即可繁殖）；繁殖出生的幼崽由 spawn 置 false。
@export var start_as_adult: bool = true
@export var wander_radius: float = 8.0
@export var idle_min: float = 2.0
@export var idle_max: float = 6.0
@export var rotation_speed: float = 8.0
@export var gravity: float = 9.8
@export var settle_delay: float = 0.5
## walk 动画腿频系数。两套包的 walk 都是**原地循环**（无 root motion），身体由代码按
## move_speed 平移；腿频不配上世界速度就会明显滑步。在 species 场景里按目视调（腿看着像
## 在蹬地而不是滑冰即可）。1.0 = 原速。
@export var walk_cycle_speed: float = 1.0
## 无 walk clip 的 farm 动物（Sheep/Llama/Pig/Pug）改用 jump 蹦跳挪动时的移动速度（m/s）。
## 比 move_speed 慢一些，蹦跳节奏才读得出来；species 场景里可调。
@export var hop_speed: float = 0.8

# 从物种配置读（_build_visual 覆盖）。
var move_speed: float = 2.0

# 经 MultiplayerSynchronizer 同步给 client：idle | walking | falling。
var anim_state: String = "idle":
	set(value):
		if anim_state == value:
			return
		anim_state = value
		_apply_anim_state(value)

# 预留给 Phase 3 宰杀；client 也读它决定是否播 death。
var alive: bool = true

# ── 畜牧生命周期（Phase 2；仅 livestock 物种激活，server 权威 + 持久化）──
# growth_stage 同步给 client（用于缩放幼崽）；fed / 孕期 / 繁殖冷却仅 server。
var growth_stage: String = "adult":   # young | adult
	set(value):
		if growth_stage == value:
			return
		growth_stage = value
		_apply_growth_scale()
var fed: float = 100.0                 # 0..100
var spawned_at_game_hour: int = -1
var pregnant_until_hour: int = -1      # -1 = 未孕
var last_bred_hour: int = -100000
var _life: Dictionary = {}             # AnimalSpecies.life_of(species_id) 缓存
var _base_scale: float = 1.0           # 成年缩放，取自 species 场景的 Visual.scale；幼崽按 young_scale_mult 折减

@onready var nav: NavigationAgent3D = $NavigationAgent3D
@onready var _visual: Node3D = $Visual
@onready var _body_shape: CollisionShape3D = $CollisionShape3D

var anim: AnimationPlayer = null
var _model_root: Node3D = null
var _clip_cache: Dictionary = {}
# 移动用的 clip 与速度，由 _resolve_locomotion 按 _LOCOMOTION_PRIORITY 选定（walk→…→jump）。
var _loco_clip: String = ""
var _loco_speed: float = 2.0
# 有移动 clip（walk 或 jump）才游荡；都没有则永远原地 idle。
var _can_wander: bool = false

var _state: String = "falling"   # falling | idle | walking
var _origin: Vector3 = Vector3.ZERO
var _settle_timer: float = 0.0
var _idle_timer: float = 0.0
# 走路卡死兜底：超过 _STUCK_TIMEOUT 没有可观进展（撞墙 / 路不通）就回 idle 重选点。
const _STUCK_TIMEOUT := 1.5
var _stuck_timer: float = 0.0
var _last_progress_pos: Vector3 = Vector3.ZERO


# ── spawn 工厂（Phase 2 繁殖用；scene-placed 动物不走这条）────────────
static func from_spawn_data(data: Variant) -> Node:
	var d: Dictionary = data as Dictionary
	var species := str(d.get("species_id", "cow"))
	var scene_path := AnimalSpecies.scene_path(species)
	var ps := load(scene_path) as PackedScene
	if ps == null:
		push_error("[Animal] 无 species 场景: %s（应在 src/characters/animals/species/ 下建 %s.tscn）" % [scene_path, species])
		return null
	var node := ps.instantiate() as Animal
	node.species_id = species
	node.animal_id = str(d.get("animal_id", ""))
	node.start_as_adult = bool(d.get("start_as_adult", false))  # spawn 出来的默认幼崽
	node.position = d.get("pos", Vector3.ZERO)
	return node


static func spawn(spawner: MultiplayerSpawner, species_id: String, world_pos: Vector3, animal_id: String = "") -> Animal:
	assert(RunMode.is_runtime(), "Animal.spawn must run on the runtime server")
	if not AnimalSpecies.has(species_id):
		push_warning("[Animal] unknown species: %s" % species_id)
		return null
	return spawner.spawn({
		"species_id": species_id,
		"animal_id": animal_id,
		"pos": world_pos,
		"start_as_adult": false,  # spawn 用于出生/hydrate；出生=幼崽，hydrate 随后被 apply_persisted_state 覆盖
	}) as Animal


func _ready() -> void:
	_build_visual()
	add_to_group("animals")   # 注意：不是 "npcs" —— 避免被 NPC arrival-spread 扫到
	if Engine.is_editor_hint():
		return
	_apply_anim_state(anim_state)
	if not RunMode.is_runtime():
		return  # client puppet：position/anim_state 靠 synchronizer
	_state = "falling"
	_settle_timer = 0.0
	if is_livestock():
		_init_lifecycle()


# ── 视觉 / 动画装配 ──────────────────────────────────────────────────
func _build_visual() -> void:
	if _visual == null:
		_visual = get_node_or_null("Visual")
	if _visual == null:
		return
	_clip_cache.clear()
	anim = null
	_model_root = null
	var conf := AnimalSpecies.config(species_id)
	if conf.is_empty():
		push_error("[Animal] 未知 species_id: '%s'（不在 AnimalSpecies.SPECIES）" % species_id)
		return
	# 物种模型由 species 场景（species/<id>.tscn）烘焙在 Visual 下——取已有子节点，
	# 不再 runtime 实例化。成年 scale 也由该场景的 Visual.scale 决定（单一来源）。
	if _visual.get_child_count() > 0:
		_model_root = _visual.get_child(0) as Node3D
	if _model_root == null:
		# 裸 base 场景（animal.tscn / wild_animal.tscn 无烘焙模型）：编辑器里安静返回
		# （正在编辑抽象 base）；运行时必须有模型 → fail-loud（见 fail_loud_no_silent_fallback）。
		if not Engine.is_editor_hint():
			push_error("[Animal %s] Visual 下无烘焙模型——应实例化 species/%s.tscn 而非裸 base" % [species_id, species_id])
		return
	_base_scale = _visual.scale.x  # species 场景里目视调好的成年缩放
	_life = AnimalSpecies.life_of(species_id)
	move_speed = float(conf["move_speed"])
	anim = _find_anim_player(_model_root)
	_apply_body_size(conf)
	_apply_growth_scale()  # 设 _visual.scale（_base_scale × 幼崽折减）+ 对地
	_on_visual_built(conf)  # 虚 hook：WildAnimal 预解析战斗 clip
	for req in _REQUIRED_CLIPS:
		if _resolve_clip(req) == "":
			push_error("[Animal %s] 缺必需动画 '%s'；模型 clip = %s" % [
				species_id, req, anim.get_animation_list() if anim != null else []])
	_resolve_locomotion()
	if not Engine.is_editor_hint():
		_patch_loops()
		_apply_anim_state(anim_state)
	# 关键：骨架在 _ready 这帧还没 pose，get_aabb 返回未初始化的小盒子（≈0.07），_apply_growth_scale
	# 里那次对地是错的（羊会悬空）。等一帧 pose 完再对地一次——_align_feet 幂等（按当前 feet 位置纠到
	# body 原点），重算即修正。编辑器 + 运行时都做（编辑器对地后存盘即烘焙正确 offset）。
	_align_feet_when_posed()


# 按 _LOCOMOTION_PRIORITY 顺序挑该模型第一个有的移动 clip + 对应速度档。
# 都没有 → _loco_clip 空 → _can_wander=false，永远原地 idle。
func _resolve_locomotion() -> void:
	_loco_clip = ""
	_loco_speed = move_speed
	for pref in _LOCOMOTION_PRIORITY:
		var clip := _resolve_clip(pref[0])
		if not clip.is_empty():
			_loco_clip = clip
			_loco_speed = hop_speed if pref[1] == "hop" else move_speed
			break
	_can_wander = not _loco_clip.is_empty()


# 虚 hook：WildAnimal override 预解析 attack/death/hit。
func _on_visual_built(_conf: Dictionary) -> void:
	pass


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var found := _find_anim_player(c)
		if found != null:
			return found
	return null


# 把模型抬到「最低网格点 = 本体 y」，避免缩放后脚陷地里 / 悬空。
# 注意：skinned mesh 的 get_aabb() 只在 skeleton pose 完后才正确（_ready 当帧是未初始化的小盒子）；
# 必须经 _align_feet_when_posed 等一帧后调用，否则算出错误的小 offset（羊悬空的病根）。
func _align_feet() -> void:
	if _model_root == null:
		return
	var meshes := _collect_meshes(_model_root)
	if meshes.is_empty():
		return
	var min_y := INF
	for m in meshes:
		var a: AABB = m.get_aabb()
		for i in 8:
			min_y = minf(min_y, (m.global_transform * a.get_endpoint(i)).y)
	if is_inf(min_y):
		return
	_visual.position.y += global_position.y - min_y


# 等一帧让 skeleton pose 完再对地（get_aabb 才返回真实包围盒）。_align_feet 幂等，重算即纠正
# _apply_growth_scale 里那次（_ready 当帧）的错误对地。节点可能在等待中被 free → 守卫。
func _align_feet_when_posed() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if is_instance_valid(self) and is_inside_tree() and _model_root != null and _visual != null:
		_align_feet()


func _collect_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out += _collect_meshes(c)
	return out


# 按物种体型重建胶囊（新建 shape，不改共享 sub-resource）+ 同步 nav 半径。
func _apply_body_size(conf: Dictionary) -> void:
	var r := float(conf.get("body_radius", 0.3))
	var h := float(conf.get("body_height", 0.8))
	var shape := CapsuleShape3D.new()
	shape.radius = r
	shape.height = maxf(h, r * 2.0)
	if _body_shape != null:
		_body_shape.shape = shape
		_body_shape.position = Vector3(0, shape.height * 0.5, 0)
	if nav != null:
		nav.radius = r


# logical（idle/walk/run/death/attack/hit/eat）→ 实际 clip 名，吃掉前缀差异，缓存。
# 找不到返回 ""（必需 clip 由 _build_visual fail-loud；可选 clip 调用方自判）。
func _resolve_clip(logical: String) -> String:
	if _clip_cache.has(logical):
		return _clip_cache[logical]
	var found := ""
	var bases: Array = _CLIP_CANDIDATES.get(logical, [logical])
	for base in bases:
		for prefix in _CLIP_PREFIXES:
			var cand := str(prefix) + str(base)
			if anim != null and anim.has_animation(cand):
				found = cand
				break
		if not found.is_empty():
			break
	_clip_cache[logical] = found
	return found


# idle + 移动 clip（walk 或 hop 用的 jump）+ run 强制 LOOP_LINEAR，避免播完停住
# （两套包 clip 导入全是 loop=NONE）。共享 .scn resource，第一次改完都受益；
# 编辑器里跳过——会把导入的 .scn 标脏。
func _patch_loops() -> void:
	if anim == null:
		return
	var clips := ["idle", "run"]
	if not _loco_clip.is_empty() and not clips.has(_loco_clip):
		clips.append(_loco_clip)   # walk 或 jump；jump 循环播 = 持续弹跳
	for entry in clips:
		# "idle"/"run" 是 logical 名要解析；_loco_clip 已是实际 clip 名直接用。
		var clip: String = _resolve_clip(entry) if _CLIP_CANDIDATES.has(entry) else entry
		if clip.is_empty():
			continue
		var a := anim.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR


func _apply_anim_state(state: String) -> void:
	match state:
		"walking":
			_play(_loco_clip)   # walk 或（无 walk 时）jump 蹦跳
		_:  # idle / falling
			if anim != null:
				anim.speed_scale = 1.0   # 走路时被 _sync_locomotion_anim_speed 调过，复位
			_play(_resolve_clip("idle"))


func _play(clip: String) -> void:
	if clip.is_empty() or anim == null:
		return
	if anim.current_animation != clip and anim.has_animation(clip):
		anim.play(clip, 0.0)


# ── 畜牧生命周期（Phase 2，server 权威；非 livestock 物种全部 no-op）────────
func is_livestock() -> bool:
	return AnimalSpecies.is_livestock(species_id)


func is_adult() -> bool:
	return growth_stage == "adult"


func is_pregnant() -> bool:
	return pregnant_until_hour >= 0


# 幼崽按 young_scale_mult 折减视觉尺寸；adult 用 base。改 stage 时重设并重新对地。
func _apply_growth_scale() -> void:
	if _visual == null:
		return
	var mult := 1.0
	if growth_stage == "young" and not _life.is_empty():
		mult = float(_life.get("young_scale_mult", 0.55))
	_visual.position = Vector3.ZERO
	_visual.scale = Vector3.ONE * (_base_scale * mult)
	_align_feet()


func _compute_stage(total_hour: int) -> String:
	if _life.is_empty() or spawned_at_game_hour < 0:
		return "adult"
	var age := total_hour - spawned_at_game_hour
	return "adult" if age >= int(_life.get("maturation_hours", 48.0)) else "young"


# scene 预放的 founder / 运行时繁殖出生的幼崽，在 _ready 调（runtime + livestock）。
func _init_lifecycle() -> void:
	if animal_id.is_empty():
		push_warning("[Animal] livestock '%s' 无 animal_id，生命周期不持久化" % species_id)
		spawned_at_game_hour = GameClock.total_game_hours()
		return
	var saved := Db.take_animal_instance(animal_id)
	if not saved.is_empty():
		apply_persisted_state(saved)
	else:
		var now := GameClock.total_game_hours()
		# founder 放下即成年（spawned_at 回拨到成熟期之前）；幼崽从现在开始长。
		if start_as_adult and not _life.is_empty():
			spawned_at_game_hour = now - int(_life.get("maturation_hours", 48.0)) - 1
		else:
			spawned_at_game_hour = now
		fed = 100.0
		pregnant_until_hour = -1
		last_bred_hour = -100000
		growth_stage = _compute_stage(now)
		persist_lifecycle()


# town.gd hydrate 重建上次存档的（繁殖出生）动物时调，覆盖持久字段。
func apply_persisted_state(fields: Dictionary) -> void:
	spawned_at_game_hour = int(fields.get("spawnedAtGameHour", GameClock.total_game_hours()))
	fed = float(fields.get("fed", 100.0))
	pregnant_until_hour = int(fields.get("pregnantUntilHour", -1))
	last_bred_hour = int(fields.get("lastBredHour", -100000))
	alive = bool(fields.get("alive", true))
	growth_stage = _compute_stage(GameClock.total_game_hours())
	persist_lifecycle()


func persist_lifecycle() -> void:
	if not RunMode.is_runtime() or animal_id.is_empty() or not is_livestock():
		return
	Db.save_animal_instance(animal_id, {
		"animalDefId": species_id,
		"posX": global_position.x, "posY": global_position.y, "posZ": global_position.z,
		"spawnedAtGameHour": spawned_at_game_hour,
		"fed": fed,
		"pregnantUntilHour": pregnant_until_hour,
		"lastBredHour": last_bred_hour,
		"alive": alive,
	})


# AnimalSimulator 每 slow_tick 调：fed 衰减 + 成长推进 + 持久化。
func lifecycle_tick(total_hour: int) -> void:
	if not is_livestock() or not alive:
		return
	fed = maxf(0.0, fed - float(_life.get("fed_decay_per_hour", 3.0)))
	var ns := _compute_stage(total_hour)
	if ns != growth_stage:
		growth_stage = ns
	persist_lifecycle()


# ── 繁殖 API（AnimalSimulator 编排，需要场景/spawner，故不放 Animal）────────
func can_breed(total_hour: int) -> bool:
	return is_livestock() and alive and is_adult() and not is_pregnant() \
		and fed >= float(_life.get("min_breed_fed", 50.0)) \
		and (total_hour - last_bred_hour) >= int(_life.get("breed_cooldown_hours", 96.0))


func begin_pregnancy(total_hour: int) -> void:
	pregnant_until_hour = total_hour + int(_life.get("gestation_hours", 48.0))
	last_bred_hour = total_hour
	persist_lifecycle()


func mark_sired(total_hour: int) -> void:
	last_bred_hour = total_hour
	persist_lifecycle()


func gestation_due(total_hour: int) -> bool:
	return is_pregnant() and total_hour >= pregnant_until_hour


func clear_pregnancy() -> void:
	pregnant_until_hour = -1
	persist_lifecycle()


# ── 宰杀 API（Phase 3；husbandry_runner 调）──────────────────────────
# 产出列表 [{item_id, quantity}]，按 young/adult 取量。
func slaughter_yields() -> Array:
	var out: Array = []
	var young := growth_stage == "young"
	for y_v in _life.get("slaughter", []):
		var y: Dictionary = y_v
		var qty := int(y.get("qty_young", 0)) if young else int(y.get("qty", 0))
		if qty > 0:
			out.append({"item_id": str(y.get("item", "")), "quantity": qty})
	return out


# 标记死亡：播 death、清 DB、延时 free。inventory 沉积由 husbandry_runner 负责。
func on_slaughtered() -> void:
	alive = false
	_state = "idle"
	velocity = Vector3.ZERO
	_play(_resolve_clip("death"))
	if RunMode.is_runtime() and not animal_id.is_empty() and is_livestock():
		Db.delete_animal_instance(animal_id)
	if is_inside_tree():
		get_tree().create_timer(1.5).timeout.connect(queue_free)


# ── 散养游荡 FSM（server-only）───────────────────────────────────────
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not RunMode.is_runtime():
		return  # client puppet
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	if not alive:
		# 被宰杀 / 死亡：原地播 death，不再游荡（等 queue_free）。
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	match _state:
		"falling":
			velocity.x = 0.0
			velocity.z = 0.0
			if is_on_floor():
				_settle_timer += delta
				if _settle_timer >= settle_delay:
					_origin = global_position
					_enter_idle()
		"idle":
			velocity.x = 0.0
			velocity.z = 0.0
			if _can_wander:
				_idle_timer -= delta
				if _idle_timer <= 0.0:
					_pick_wander_target()
		"walking":
			_tick_walk(delta)
	move_and_slide()


func _enter_idle() -> void:
	_state = "idle"
	anim_state = "idle"
	_idle_timer = randf_range(idle_min, idle_max)


# 在 _origin 周围 wander_radius 内随机取一个 navmesh 可达点；找不到就继续 idle。
func _pick_wander_target() -> void:
	var map := nav.get_navigation_map()
	if not map.is_valid():
		_enter_idle()
		return
	for _i in 8:
		var ang := randf() * TAU
		var dist := sqrt(randf()) * wander_radius
		var cand := _origin + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var snapped := NavigationServer3D.map_get_closest_point(map, cand)
		# 目标至少 1.5m 远：比 _tick_walk 的到达距离(target_desired_distance≈0.6)大,
		# 否则刚选点就在到达圈内→一帧就 idle，看着像没动。
		if snapped.distance_to(_origin) <= wander_radius + 1.0 and snapped.distance_to(global_position) > 1.5:
			nav.set_target_position(snapped)
			_last_progress_pos = global_position
			_stuck_timer = 0.0
			_state = "walking"
			anim_state = "walking"
			return
	_enter_idle()


# 镜像 npc.gd 的 walking 消费方式（那套是验证过能平滑走路的）：
# - 到达用「到 target 的 XZ 距离」判，不用 nav.is_navigation_finished()——路径异步计算，
#   刚 set_target 的头几帧它会误报完成，导致一起步就 idle。
# - 朝 get_next_path_position 走，但路径点退化（还没算好 / 末端点≈当前点）时退回直接朝
#   target——**绝不**因为「下一点≈当前点」就原地 idle，那正是走走停停、动画在播却不动的根因。
func _tick_walk(delta: float) -> void:
	var to_target := nav.target_position - global_position
	var to_target_xz := Vector2(to_target.x, to_target.z)
	if to_target_xz.length() <= maxf(nav.target_desired_distance, 0.4):
		_enter_idle()
		return
	# 卡死兜底：撞墙 / 不可达时别永远顶着走，回 idle 下个周期重选点。
	if global_position.distance_to(_last_progress_pos) >= 0.25:
		_last_progress_pos = global_position
		_stuck_timer = 0.0
	else:
		_stuck_timer += delta
		if _stuck_timer >= _STUCK_TIMEOUT:
			_enter_idle()
			return
	var next := nav.get_next_path_position()
	var to_next_xz := Vector2(next.x - global_position.x, next.z - global_position.z)
	var dir := to_next_xz.normalized() if to_next_xz.length() > 0.05 else to_target_xz.normalized()
	velocity.x = dir.x * _loco_speed
	velocity.z = dir.y * _loco_speed
	rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.y), rotation_speed * delta)
	_sync_locomotion_anim_speed(Vector2(velocity.x, velocity.z).length())


# 腿频/蹦跳频率跟世界水平速度匹配，减轻原地 clip 的滑步。walk_cycle_speed 是每物种目视调的系数。
func _sync_locomotion_anim_speed(h_speed: float) -> void:
	if anim == null:
		return
	var ref := maxf(_loco_speed, 0.01)
	anim.speed_scale = walk_cycle_speed * clampf(h_speed / ref, 0.2, 2.0)
