@tool
class_name WildAnimal
extends Animal

# 野外动物：当前和畜牧动物一样只散养游荡（用户决定战斗后置）。区别仅在于它来自 animated
# 包、带 Attack / HitReact / Death clip——这里预解析好并留 3 个占位方法，等以后人物战斗
# 系统（docs/architecture/combat-system.md）接入时直接调，无需再改动物管线。
#
# 这些方法现在不被任何 AI 调用（dormant）。

var _has_combat_clips: bool = false


func _on_visual_built(_conf: Dictionary) -> void:
	# 预热缓存：把战斗 clip 解析进 _clip_cache，缺失只 warn（不像 idle/walk 那样 fail-loud，
	# 因为战斗系统还没上）。
	var attack := _resolve_clip("attack")
	var death := _resolve_clip("death")
	var hit := _resolve_clip("hit")
	_has_combat_clips = not attack.is_empty()
	if attack.is_empty():
		push_warning("[WildAnimal %s] 无 attack clip（战斗接入前可忽略）" % species_id)
	# death / hit 仅缓存备用，缺了不影响游荡。
	if death.is_empty() and hit.is_empty():
		pass


# ── 占位接口：留给战斗系统 ────────────────────────────────────────────
func play_attack() -> void:
	_play(_resolve_clip("attack"))


func take_hit() -> void:
	_play(_resolve_clip("hit"))


# 死亡：播 death 并停住游荡。Phase 3 宰杀 / 未来战斗都会走到这。
func die() -> void:
	alive = false
	_state = "idle"
	velocity = Vector3.ZERO
	_play(_resolve_clip("death"))
