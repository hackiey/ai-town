class_name CastController
extends RefCounted

const SPELL_PROJECTILE := preload("res://src/combat/spell_projectile.tscn")
const CAST_TIME := 0.6
const RELEASE_RATIO := 0.55
const PROJECTILE_SPEED := 22.0
const COOLDOWN := 1.0

# 当前选中的咒（Phase E 接选咒键改它）。effect_verb/school 暂与 id 同义。
var spell_id: String = "stupefy"

var _character: Character
var _casting: bool = false
var _cooldown: float = 0.0
var _pending_aim_dir: Vector3 = Vector3.FORWARD
var _pending_spell: Dictionary = {}    # try_cast 时定格的 spell def（防施法中途切咒）
var _release_timer: SceneTreeTimer
var _finish_timer: SceneTreeTimer
var _cast_token: int = 0


func _init(owner: Character) -> void:
	_character = owner


func try_cast(aim_dir: Vector3) -> bool:
	if _casting:
		return false
	if _cooldown > 0.0:
		return false
	if _character.is_stunned():
		return false
	var spell := SpellCatalog.get_spell(spell_id)
	if spell.is_empty():
		return false
	# 魔杖耗尽（charges=durability=0）则施不出；无杖按中性威力照常施法。
	var wand_slot := SpellPower.find_wand_slot(_character)
	if wand_slot >= 0 and _wand_charges(wand_slot) == 0:
		return false

	_casting = true
	_cast_token += 1
	var token := _cast_token
	_pending_aim_dir = aim_dir.normalized()
	_pending_spell = spell

	# 瞄准类才转身面向目标（让法杖朝目标，弹体从杖尖沿瞄准线出）；自施（protego）不需要。
	# 朝向用与移动同一套公式（atan2(x, z)）；rotation 走 synchronizer 推给所有 client。
	if str(spell.get("delivery", "")) != "self_cast":
		var flat := Vector2(_pending_aim_dir.x, _pending_aim_dir.z)
		if not flat.is_zero_approx():
			_character.rotation.y = atan2(flat.x, flat.y)

	_character.anim_state = "casting"

	var cast_time := float(spell.get("cast_time", CAST_TIME))
	var anim_player := _character.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if anim_player and anim_player.has_animation("CastWand"):
		var anim_length := anim_player.get_animation("CastWand").length
		anim_player.speed_scale = anim_length / cast_time
		anim_player.play("CastWand", 0.1)

	_release_timer = _character.get_tree().create_timer(cast_time * RELEASE_RATIO)
	_release_timer.timeout.connect(_on_spell_release.bind(token))
	_finish_timer = _character.get_tree().create_timer(cast_time)
	_finish_timer.timeout.connect(_finish_cast.bind(token))
	return true


func tick(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta


func interrupt() -> void:
	if not _casting:
		return
	_cast_token += 1
	_casting = false
	_cooldown = 0.0
	var anim_player := _character.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if anim_player:
		anim_player.speed_scale = 1.0
		anim_player.stop()


func _on_spell_release(token: int) -> void:
	if token != _cast_token or not _casting:
		return

	# 消耗 1 点魔杖能量（charges 复用 durability；destroy_at_zero=false → 0 留槽里=depleted 可回充）。
	# 在 release 而非 try_cast 扣：施法被打断（stun）就不该耗能。
	var wand_slot := SpellPower.find_wand_slot(_character)
	if wand_slot >= 0:
		_character.inventory_ops().decrement_tool_durability(wand_slot, 1, false)

	var spell := _pending_spell
	var verb := str(spell.get("verb", spell_id))
	var school := str(spell.get("school", "combat"))

	# 自施（protego）：命中即自身，不发弹体——直接跑 reaction 给自己加 shielded。
	if str(spell.get("delivery", "projectile")) == "self_cast":
		CombatReactions.resolve(_character, _character, verb, school)
		return

	var origin := _get_wand_tip_position()
	var velocity := _pending_aim_dir * float(spell.get("projectile_speed", PROJECTILE_SPEED))
	# 四因子 caster_power 在施法当下算好随弹体走（反映施法瞬间的施法者状态，命中时不再重算）。
	var caster_power := SpellPower.compute(_character, verb, school)
	var data := {
		"pos": origin,
		"velocity": velocity,
		"ttl": float(spell.get("ttl", 2.0)),
		"source_path": str(_character.get_path()),
		"spell_id": spell_id,
		"effect_verb": verb,
		"school": school,
		"caster_power": caster_power,
	}
	var tree := _character.get_tree()
	var spawner: MultiplayerSpawner = null
	if tree != null and tree.current_scene != null:
		spawner = tree.current_scene.get_node_or_null("ProjectileSpawner") as MultiplayerSpawner
	if spawner != null:
		spawner.spawn(data)
		return

	var proj: SpellProjectile = SPELL_PROJECTILE.instantiate()
	proj.apply_spawn_data(data)
	proj.source = _character

	if tree != null and tree.current_scene != null:
		tree.current_scene.add_child(proj)
		proj.global_position = origin
		proj.look_at(origin + _pending_aim_dir)


func _finish_cast(token: int) -> void:
	if token != _cast_token or not _casting:
		return
	_casting = false
	_cooldown = COOLDOWN
	var anim_player := _character.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if anim_player:
		anim_player.speed_scale = 1.0
	_character.anim_state = "idle"


# 魔杖当前能量（=durability）。-1 = 该 slot 无 charges 概念（不该发生于 wand）。
func _wand_charges(slot_index: int) -> int:
	if slot_index < 0 or slot_index >= _character.inventory.size():
		return -1
	var dura := InventorySlotData.of(_character.inventory[slot_index]).as_durability()
	return dura.value() if dura != null else -1


func _get_wand_tip_position() -> Vector3:
	var wand_tip := _character.get_node_or_null("Visual/GeneralSkeleton/WandAttachment/Wand/WandTip") as Node3D
	if wand_tip:
		return wand_tip.global_position
	wand_tip = _character.get_node_or_null("Visual/GeneralSkeleton/WandAttachment/WandTip") as Node3D
	if wand_tip:
		return wand_tip.global_position
	return _character.global_position + Vector3.UP * 1.2 + _character.global_basis.z * -0.5
