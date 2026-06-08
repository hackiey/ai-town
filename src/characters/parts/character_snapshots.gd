class_name CharacterSnapshots
extends RefCounted

# Character 只读 snapshot 收口。全部为派生量 —— 不写状态，不持有缓存。
# 包括：
# - 向 UI / context 上报的 vitals / profile / equipment / statuses
# - physiology 派生的 effective_stamina_max / effective_move_speed_mult
# - 角色身份 soul_snapshot（给 prompt 用）
# - 钟表 snapshot（GameClock 转发）
#
# 这些函数原本散在 Character 上，全部纯读，搬这里把 Character 瘦身。

var _character: Character


func _init(owner: Character) -> void:
	_character = owner


# ─── vitals / physiology 派生 ───────────────────────────────

func attributes() -> Dictionary:
	return {
		"hp": { "current": roundf(_character.hp), "max": roundf(_character.max_hp) },
		"stamina": { "current": roundf(_character.stamina), "max": roundf(effective_stamina_max()) },
		"hunger": { "current": roundf(_character.hunger), "max": roundf(_character.max_hunger) },
		"rest": { "current": roundf(_character.rest), "max": roundf(_character.max_rest) },
		"drunk": { "current": roundf(_character.drunk), "max": roundf(Character.MAX_IMPAIRMENT) },
		"sickness": { "current": roundf(_character.sickness), "max": roundf(Character.MAX_IMPAIRMENT) },
	}


func effective_stamina_max() -> float:
	var result: Variant = MechanicHost.query("physiology", "effective_stamina_max", [
		_character.max_stamina,
		_character.hunger,
		_character.max_hunger,
		_character.rest,
		_character.max_rest,
	])
	return float(result) if result != null else _character.max_stamina


func effective_move_speed_mult() -> float:
	var result: Variant = MechanicHost.query("physiology", "move_speed_mult", [
		_character.stamina,
		_character.max_stamina,
	])
	var base := float(result) if result != null else 1.0
	# 负重惩罚：超过 laden 后线性减速（与 physiology 的 stamina 乘子相乘）。Player/NPC 同走此处。
	return base * Impairment.encumber_move_mult(_character.carry_ratio())


# ─── identity / profile ─────────────────────────────────────
# soul_snapshot() 是 Character 上的 virtual（NPC override 加配置字段）。这里直接读，
# 不重复实现 base 逻辑——避免 NPC override 失效。

func ui_profile() -> Dictionary:
	var soul_d := _character.soul_snapshot()
	var group_ids: Array[String] = []
	for group_id in _character.groups:
		group_ids.append(str(group_id))
	var equipment := {}
	for slot_name in ["right_hand", "left_hand", "body", "head"]:
		equipment[slot_name] = str(_character.equipped.get(slot_name, ""))
	return {
		"id": _character.backend_character_id(),
		"name": str(soul_d.get("name", _character.backend_character_id())),
		"age": soul_d.get("age", "未知"),
		"occupation": str(soul_d.get("occupation", "未定义")),
		"personality": str(soul_d.get("personality", "未定义")),
		"faction": _character.faction,
		"materialId": _character.material.id if _character.material != null else "",
		"materialName": _character.material.display_name if _character.material != null else "",
		"mass": _character.mass,
		"volume": _character.volume,
		"moisture": _character.moisture,
		"temperature": _character.temperature,
		"ignitionPoint": _character.ignition_point(),
		"alive": _character.alive,
		"burning": _character.burning,
		"sleeping": _character.sleep_controller().is_sleeping(),
		"sleepNeededHours": _character.sleep_needed_hours,
		"statusIds": active_status_ids(),
		"groupIds": group_ids,
		"equipment": equipment,
		"vitals": {
			"hp": { "current": roundf(_character.hp), "max": roundf(_character.max_hp) },
			"stamina": { "current": roundf(_character.stamina), "max": roundf(effective_stamina_max()) },
			"hunger": { "current": roundf(_character.hunger), "max": roundf(_character.max_hunger) },
			"rest": { "current": roundf(_character.rest), "max": roundf(_character.max_rest) },
			"drunk": { "current": roundf(_character.drunk), "max": roundf(Character.MAX_IMPAIRMENT) },
			"sickness": { "current": roundf(_character.sickness), "max": roundf(Character.MAX_IMPAIRMENT) },
		},
		"proficiency": _proficiency_entries(),
	}


# 按 Crafts.all_skill_ids() 顺序铺 9 项；缺的 skill 填 0（=novice）。
# tier 映射放在 character_panel.gd（表现层），这里只吐 raw value。
func _proficiency_entries() -> Array[Dictionary]:
	var table := _character.get_proficiency_table()
	var out: Array[Dictionary] = []
	for skill_id in Crafts.all_skill_ids():
		out.append({
			"skillId": skill_id,
			"value": float(table.get(skill_id, 0.0)),
		})
	return out


func equipped_items() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot_name_v in _character.equipped.keys():
		var slot_name := str(slot_name_v)
		var item_id := str(_character.equipped.get(slot_name, ""))
		if item_id.is_empty():
			continue
		out.append({
			"slot": slot_name,
			"itemId": item_id,
			"quantity": 1,
		})
	return out


func active_status_ids() -> Array[String]:
	var out: Array[String] = []
	for status_v in _character.active_statuses:
		if typeof(status_v) != TYPE_DICTIONARY:
			continue
		var status: Dictionary = status_v as Dictionary
		var status_type := str(status.get("type", ""))
		if not status_type.is_empty():
			out.append(status_type)
	return out


func game_time() -> Dictionary:
	var clock := _character.get_node_or_null("/root/GameClock")
	if clock == null or not clock.has_method("game_time_snapshot"):
		return {}
	return clock.call("game_time_snapshot") as Dictionary
