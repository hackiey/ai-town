extends Node

# Autoload: HitResolver —— 命中事件队列 + fast-tick 边界结算（combat-system.md §2 / §6.1）。
# 弹道命中当帧只 enqueue，下个 SimTick.fast_tick 统一 _settle：护盾拦截 → reaction → 唤醒 → spell_hit。
# 单一结算点，避免一发弹道在两 tick 间反复改 HP。server-only（命中是 server 权威）。

var _queue: Array[Dictionary] = []


func _ready() -> void:
	if Engine.is_editor_hint() or not RunMode.is_runtime():
		return
	SimTick.fast_tick.connect(_settle)


# 弹道命中当帧调（server）。hit = {source: Character, target: Character,
#   spell_id, effect_verb, school, caster_power, base_power}
func enqueue(hit: Dictionary) -> void:
	_queue.append(hit)


func _settle() -> void:
	if _queue.is_empty():
		return
	var batch := _queue
	_queue = []
	for hit in batch:
		_resolve_one(hit)


func _resolve_one(hit: Dictionary) -> void:
	var target := hit.get("target") as Character
	var source := hit.get("source") as Character
	if target == null or not is_instance_valid(target):
		return
	var verb := str(hit.get("effect_verb", ""))
	var school := str(hit.get("school", "combat"))
	var caster_power := float(hit.get("caster_power", -1.0))

	# 护盾拦截（命中前消弹 / 减法损耗，combat-system.md §6.6）：盾全额吸收则消弹、不走 reaction。
	if _shield_absorbs(target, verb, caster_power):
		_emit_spell_hit(source, target, hit, {"outcome": "blocked", "hp_delta": 0.0, "added_statuses": []})
		return

	var r := CombatReactions.resolve(source, target, verb, school, caster_power)

	# 挨打是外部刺激：睡着的目标打醒（woke_up 已是 hard_interrupt，reason 带攻击者）。
	# 醒着的目标不发 woke_up，只靠下面的 spell_hit 感知，避免重复唤醒。
	if target.sleep_controller().is_sleeping():
		var attacker_id := source.backend_character_id() if source != null else ""
		var reason := "attacked by %s" % attacker_id if not attacker_id.is_empty() else "attacked"
		target.sleep_controller().wake_from_external_stimulus(reason)

	_emit_spell_hit(source, target, hit, r)


# 护盾吸收：true = 全额挡下（消弹，不走 reaction）。盾按 attack_power 减法损耗，耗尽移除；
# 击穿（block < attack）→ 盾碎、返回 false 让全额命中（leftover 降威力的精细化留后续）。
func _shield_absorbs(target: Character, verb: String, caster_power: float) -> bool:
	var idx := _shielded_index(target)
	if idx < 0:
		return false
	var attack := _reaction_base_power(verb) * maxf(caster_power, 0.0)
	var s: Dictionary = target.active_statuses[idx]
	var block := float(s.get("block_power", 0.0))
	if block >= attack:
		var left := block - attack
		if left <= 0.0:
			target.remove_status_type("shielded")
		else:
			s["block_power"] = left
			target.active_statuses[idx] = s
			target.active_statuses = target.active_statuses  # 触发 synchronizer 推 client
		return true
	target.remove_status_type("shielded")
	return false


func _shielded_index(target: Character) -> int:
	for i in target.active_statuses.size():
		if str((target.active_statuses[i] as Dictionary).get("type", "")) == "shielded":
			return i
	return -1


# 反应的 base_power（power 单位的 attack 标量 = base_power × caster_power）。只读 query。
func _reaction_base_power(verb: String) -> float:
	var rv: Variant = MechanicHost.query("magic", "get_reaction", [verb])
	if rv == null:
		return 1.0
	return float(LuaConv.to_dict(rv).get("base_power", 1.0))


func _emit_spell_hit(source: Character, target: Character, hit: Dictionary, r: Dictionary) -> void:
	if source == null or not is_instance_valid(source):
		return
	# 旁观者 = 施法者 FAR 半径内可感知者（已滤睡眠/隔音）；显式补上目标自己。
	var affected := source.perception().voice_affected_character_ids("far")
	var target_id := target.backend_character_id()
	if not target_id.is_empty() and not affected.has(target_id):
		affected.append(target_id)
	source.emit_world_event("spell_hit", {
		"actorId": source.backend_character_id(),
		"affectedCharacterIds": affected,
		"spellId": str(hit.get("spell_id", "")),
		"school": str(hit.get("school", "combat")),
		"outcome": str(r.get("outcome", "hit")),
		"targetCharacterId": target_id,
		"hpDelta": float(r.get("hp_delta", 0.0)),
		"addedStatuses": r.get("added_statuses", []),
	})
