class_name CharacterStateIO
extends RefCounted

# Character ↔ SQLite character_states 行映射。两个方向：
# - hydrate()：_ready 时 Db.take_character_state(cid) → 覆盖位姿/数值/装备/statuses/wallet。
# - persist()：事件触发（slow tick 末、refresh_statuses、wallet 操作、子类位姿稳定点）写回 Db。
# 不周期 flush；写次数与角色态变化次数同阶。
#
# Server-only：RunMode.is_runtime()==false 时全部 no-op。客户端不连 DB。

var _character: Character


func _init(owner: Character) -> void:
	_character = owner


# 从 Db cache 拉本角色行覆盖到 Character。DB 没行（首次开服）则保留 _ready 上面设的兜底默认值。
func hydrate() -> void:
	if not RunMode.is_runtime():
		return
	var cid := _character.backend_character_id()
	if cid.is_empty():
		return
	var row := Db.take_character_state(cid)
	if row.is_empty():
		return
	_character.hp = roundf(float(row.get("hp", _character.hp)))
	_character.max_hp = float(row.get("maxHp", _character.max_hp))
	_character.stamina = float(row.get("stamina", _character.stamina))
	_character.max_stamina = float(row.get("maxStamina", _character.max_stamina))
	_character.hunger = float(row.get("hunger", _character.hunger))
	_character.max_hunger = float(row.get("maxHunger", _character.max_hunger))
	_character.rest = float(row.get("rest", _character.rest))
	_character.max_rest = float(row.get("maxRest", _character.max_rest))
	_character.strength = float(row.get("strength", _character.strength))
	_character.constitution = float(row.get("constitution", _character.constitution))
	_character.recompute_derived_attributes()
	_character.drunk = float(row.get("drunk", _character.drunk))
	_character.sickness = float(row.get("sickness", _character.sickness))
	_character.disease_id = str(row.get("diseaseId", _character.disease_id))
	var symptoms_v: Variant = row.get("symptoms", _character.symptoms)
	if symptoms_v is Dictionary:
		_character.symptoms = Character._clean_number_dict(symptoms_v)
	if _character.sickness <= 0.0:
		_character.disease_id = ""
	_character.seed_symptoms_from_legacy_sickness()
	_character.recompute_sickness_from_symptoms()
	_character.sleep_needed_hours = float(row.get("sleepNeededHours", _character.sleep_needed_hours))
	if _character.sleep_needed_hours <= 0.0:
		_character.sleep_needed_hours = Character.DEFAULT_SLEEP_NEEDED_HOURS
	_character.temperature = float(row.get("temperature", _character.temperature))
	_character.burning = bool(row.get("burning", _character.burning))
	_character.alive = bool(row.get("alive", _character.alive))
	# 位姿：场景 .tscn 已经把 NPC 摆好；DB 行存在时一律覆盖，让上次停机位置生效。
	var px := float(row.get("posX", 0.0))
	var py := float(row.get("posY", 0.0))
	var pz := float(row.get("posZ", 0.0))
	if not (px == 0.0 and py == 0.0 and pz == 0.0):
		_character.global_position = Vector3(px, py, pz)
	_character.rotation.y = float(row.get("rotY", _character.rotation.y))
	# 装备
	var eq := {}
	for pair in [["right_hand", "equippedRightHand"], ["left_hand", "equippedLeftHand"],
		["body", "equippedBody"], ["head", "equippedHead"]]:
		var v := str(row.get(pair[1], ""))
		if not v.is_empty():
			eq[pair[0]] = v
	_character.equipped = eq
	# Statuses：直接装回（hungry/sleeping 等都被保留）
	var conds_v: Variant = row.get("activeStatuses", [])
	if conds_v is Array:
		var typed: Array[Dictionary] = []
		for c in (conds_v as Array):
			if c is Dictionary:
				typed.append(c as Dictionary)
		_character.active_statuses = typed
	_character.wallet_centi = maxi(0, int(row.get("silverCentiBalance", 0)))


# 把当前角色态写回 Db（事件触发，不周期 flush）。
func persist() -> void:
	if not RunMode.is_runtime():
		return
	var cid := _character.backend_character_id()
	if cid.is_empty():
		return
	_character.recompute_derived_attributes()
	var world: TownWorld = _character.get_tree().get_first_node_in_group("town_world") as TownWorld
	var loc_id := _character.perception().current_location_id(world) if world != null else ""
	Db.save_character_state(cid, {
		"currentLocationId": loc_id,
		"posX": _character.global_position.x,
		"posY": _character.global_position.y,
		"posZ": _character.global_position.z,
		"rotY": _character.rotation.y,
		"animState": _character._current_anim_state(),
		"hp": roundf(_character.hp),
		"maxHp": _character.max_hp,
		"stamina": _character.stamina,
		# max_stamina 是静态 export 上限；effective_stamina_max 受 hunger/rest 实时压低，
		# 不持久化（每次读 state 时再算/渲染即可）。
		"maxStamina": _character.max_stamina,
		"hunger": _character.hunger,
		"maxHunger": _character.max_hunger,
		"rest": _character.rest,
		"maxRest": _character.max_rest,
		"strength": _character.strength,
		"constitution": _character.constitution,
		"drunk": _character.drunk,
		"sickness": _character.sickness,
		"diseaseId": _character.disease_id if _character.sickness > 0.0 else "",
		"symptoms": _character.symptoms,
		# 派生档位 key 随 raw 一起持久化——阈值只在 Impairment 里判一次，backend 直接读这个 key。
		"drunkTier": Impairment.drunk_tier_key(_character.drunk),
		"sicknessTier": Impairment.sickness_tier_key(_character.sickness),
		# 负重：carry_weight 由 CharacterInventory 单一写者算好；carryTier 派生档位（backend 只读渲染）。
		"carryWeight": _character.carry_weight,
		"maxCarry": _character.max_carry_weight,
		"carryTier": Impairment.encumbrance_tier_key(_character.carry_ratio()),
		"sleepNeededHours": _character.sleep_needed_hours,
		"temperature": _character.temperature,
		"burning": _character.burning,
		"alive": _character.alive,
		"equippedRightHand": str(_character.equipped.get("right_hand", "")),
		"equippedLeftHand": str(_character.equipped.get("left_hand", "")),
		"equippedBody": str(_character.equipped.get("body", "")),
		"equippedHead": str(_character.equipped.get("head", "")),
		"activeStatuses": _character.active_statuses,
		"silverCentiBalance": _character.wallet_centi,
	})
