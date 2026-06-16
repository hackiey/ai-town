class_name CombatController
extends RefCounted

const _CAST_CONTROLLER := preload("res://src/characters/parts/cast_controller.gd")
const _WAND_SCENE := preload("res://third-party/polygon-fantasy-kingdom/Assets/PolygonFantasyKingdom/Prefabs/Items/SM_Item_Stirring_Stick_01.tscn")
const _COMBAT_ANIMS := {
	&"CastWand": preload("res://assets/animations/combat/standing_1h_magic_attack_01.res"),
	&"KnockedOut": preload("res://assets/animations/combat/knocked_out.res"),
	&"GettingUp": preload("res://assets/animations/combat/getting_up.res"),
}

# KnockedOut 开头有一段抬手的 wind-up，受击时不想要——播放后 seek 到这个时间点，直接进倒地。
# 动画总长 ~4.9s；嫌截多/截少调这个值即可。
const KNOCKED_OUT_START_SEC := 0.9

var _character: Character
var _cast: CastController


func _init(owner: Character) -> void:
	_character = owner
	_cast = _CAST_CONTROLLER.new(owner)


func cast() -> CastController:
	return _cast


# ─── setup（Character._ready 调一次）──────────────────

func setup() -> void:
	_load_combat_anims()
	_attach_wand()


func _load_combat_anims() -> void:
	var anim_player := _character.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if anim_player == null:
		return
	var lib := anim_player.get_animation_library("")
	for anim_name: StringName in _COMBAT_ANIMS:
		if not lib.has_animation(anim_name):
			lib.add_animation(anim_name, _COMBAT_ANIMS[anim_name])
	CharacterVisualSetup.set_combat_anims_no_loop(anim_player)


func _attach_wand() -> void:
	var skel := _character.get_node_or_null("Visual/GeneralSkeleton") as Skeleton3D
	if skel:
		CharacterVisualSetup.setup_wand_attachment(skel, _WAND_SCENE)


# ─── stun ─────────────────────────────────────────────

func is_stunned() -> bool:
	return _character.has_status("stunned")


func try_apply_anim() -> bool:
	if not is_stunned():
		return false
	var anim_player := _character.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if anim_player and anim_player.current_animation != "KnockedOut" and anim_player.has_animation("KnockedOut"):
		anim_player.play("KnockedOut", 0.15)
		anim_player.seek(KNOCKED_OUT_START_SEC, true)  # 截掉开头抬手，直接进倒地
	return true


func apply_stun(duration_sec: float) -> void:
	if _character.has_status("stunned"):
		_character.remove_status_type("stunned")
	_character.active_statuses.append({
		"type": "stunned",
		"duration_real_sec": duration_sec,
		"started_real_sec": Time.get_ticks_msec() / 1000.0,
		"started_at": GameClock.total_game_hours(),
		"expires_total_hours": -1,
	})
	_cast.interrupt()
	_character._apply_anim_state(_character._current_anim_state())


func tick(delta: float) -> void:
	_cast.tick(delta)
	_tick_stun()


func _tick_stun() -> void:
	if not is_stunned():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for i in range(_character.active_statuses.size() - 1, -1, -1):
		var s: Dictionary = _character.active_statuses[i]
		if str(s.get("type", "")) != "stunned":
			continue
		var dur: float = float(s.get("duration_real_sec", 3.0))
		var started: float = float(s.get("started_real_sec", now))
		if now - started >= dur:
			_character.active_statuses.remove_at(i)
			_character._apply_anim_state("idle")
