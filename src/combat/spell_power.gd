class_name SpellPower

# 四因子威力（combat-system.md §3.2）：spell_power = base_power × mastery × wand.power × wand.affinity[school]。
# 这里 GDScript 单点算出 **caster_power = mastery × wand.power × wand.affinity[school]**（不含 base_power），
# 注入 ctx；magic.lua 反应再乘自己的 base_power 得到 spell_power（base_power 与反应共置，避免来回查表）。
# 同一份 proficiency 既映射成 mastery 倍率，也喂 compute_fail_chance（0..100），单一来源。

const MASTERY_MIN := 0.6
const MASTERY_MAX := 1.5


static func compute(caster: Character, verb: String, school: String) -> float:
	var mastery := mastery_of(caster, verb)
	var wand := _wand_attrs(caster)
	var wand_power := float(wand.get("power", 1.0))
	var affinity_tbl: Dictionary = wand.get("affinity", {})
	var affinity := float(affinity_tbl.get(school, 1.0))
	return mastery * wand_power * affinity


# proficiency 0..100 → [0.6, 1.5] 倍率
static func mastery_of(caster: Character, verb: String) -> float:
	if caster == null:
		return MASTERY_MIN
	var prof := caster.get_proficiency_table()
	var p := clampf(float(prof.get(verb, 0.0)), 0.0, 100.0)
	return MASTERY_MIN + (MASTERY_MAX - MASTERY_MIN) * (p / 100.0)


# 找施法者背包里第一把魔杖的 slot index（tag "wand"）。-1 = 没有。
# 不看 charges——取出后由 caller（cast_controller）判 durability 是否耗尽。
# equipped 字典在本项目是 vestigial，工具一律靠背包扫描（同 farm/mining 的 count_item 惯例）。
static func find_wand_slot(caster: Character) -> int:
	if caster == null:
		return -1
	var inv: Array = caster.inventory
	for i in inv.size():
		var view := InventorySlotData.of(inv[i])
		if not view.is_empty() and view.has_tag("wand"):
			return i
	return -1


# 读魔杖模板的 power / affinity（模板级，全实例共享，不随 charges 变）；无杖 → 中性 1.0。
static func _wand_attrs(caster: Character) -> Dictionary:
	var idx := find_wand_slot(caster)
	if idx < 0:
		return {"power": 1.0, "affinity": {}}
	var item_id := str((caster.inventory[idx] as Dictionary).get("item_id", ""))
	var tmpl: Item = Items.by_id(item_id)
	if tmpl == null:
		return {"power": 1.0, "affinity": {}}
	var affinity_v: Variant = tmpl.properties.get("wand_affinity", {})
	return {
		"power": float(tmpl.properties.get("wand_power", 1.0)),
		"affinity": affinity_v if affinity_v is Dictionary else {},
	}
