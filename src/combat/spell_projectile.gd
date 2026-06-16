class_name SpellProjectile
extends Area3D

# 投递层弹体：只管飞 + 命中检测。命中当帧不结算物理，只往 HitResolver 推 hit_event，
# 下个 fast-tick 边界统一结算（combat-system.md §2）。伤害/status/感知全在 reaction 管线。

var velocity: Vector3 = Vector3.ZERO
var ttl: float = 2.5
var source: Character
var source_path: NodePath = NodePath("")

# 投递时随弹体走的咒标识 + 命中时要算的四因子 caster_power（施法瞬间算好）。
var spell_id: String = ""
var effect_verb: String = ""
var school: String = "combat"
var caster_power: float = 1.0


func apply_spawn_data(data: Dictionary) -> void:
	position = data.get("pos", Vector3.ZERO) as Vector3
	velocity = data.get("velocity", Vector3.ZERO) as Vector3
	ttl = float(data.get("ttl", ttl))
	source_path = NodePath(str(data.get("source_path", "")))
	spell_id = str(data.get("spell_id", ""))
	effect_verb = str(data.get("effect_verb", ""))
	school = str(data.get("school", "combat"))
	caster_power = float(data.get("caster_power", 1.0))


func _ready() -> void:
	_resolve_source()
	if not RunMode.is_runtime():
		return
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	global_position += velocity * delta
	ttl -= delta
	if RunMode.is_runtime() and ttl <= 0.0:
		queue_free()


func _on_body_entered(body: Node3D) -> void:
	if not RunMode.is_runtime():
		return
	if body == source:
		return
	if body is Character:
		# 命中当帧只入队，下个 fast-tick 由 HitResolver 统一结算（护盾/伤害/唤醒/感知）。
		HitResolver.enqueue({
			"source": source,
			"target": body as Character,
			"spell_id": spell_id,
			"effect_verb": effect_verb,
			"school": school,
			"caster_power": caster_power,
		})
	queue_free()


func _resolve_source() -> void:
	if source != null or source_path == NodePath(""):
		return
	source = get_node_or_null(source_path) as Character
