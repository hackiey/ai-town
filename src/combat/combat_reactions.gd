class_name CombatReactions

# 命中→反应的桥（combat-system.md §5.2 的 react.apply 在本项目的真身）。引擎侧 glue：
# 算四因子 caster_power、装 ctx、调 data/mechanics/magic.lua 的 on_hit_reaction，
# 由 Effects.apply 落地 affect.hp / affect.add_status（伤害 + status 全声明式在 lua，本类不直接 mutate）。
# 不复用 Crafting.resolve：crafting 的 ctx 形状是 workstation/slot 阵列，与战斗不符。

const _MECH := "magic"


# caster_power < 0 → 现算（自施 / 无投递时）；>= 0 → 用投递时随弹体带来的值（弹道命中走这条）。
# 返回：{ ok, outcome("hit"|"failed"), power, hp_delta, added_statuses: Array, fail_reason }
static func resolve(caster: Character, target: Character, verb: String, school: String, caster_power: float = -1.0) -> Dictionary:
	if target == null or not is_instance_valid(target):
		return {"ok": false, "outcome": "failed", "fail_reason": "no_target", "hp_delta": 0.0, "added_statuses": []}
	var power := caster_power if caster_power >= 0.0 else SpellPower.compute(caster, verb, school)
	var ctx := {
		"verb": verb,
		"school": school,
		"caster": caster,
		"caster_id": caster.backend_character_id() if caster != null else "",
		"target": target,
		"target_tags": target_tags(target),
		"caster_power": power,
		"proficiency": caster.get_proficiency_table() if caster != null else {},
	}
	var res := MechanicHost.invoke(_MECH, "on_hit_reaction", ctx)
	if not bool(res.get("ok", false)):
		return {"ok": false, "outcome": "failed", "fail_reason": str(res.get("error", "invoke_failed")), "hp_delta": 0.0, "added_statuses": []}
	var rv: Dictionary = res.get("return_value") if res.get("return_value") is Dictionary else {}
	var ok := bool(rv.get("ok", false))
	var statuses_v: Variant = rv.get("statuses", [])
	var statuses: Array = statuses_v if statuses_v is Array else []
	return {
		"ok": ok,
		"outcome": "hit" if ok else "failed",
		"power": float(rv.get("power", 0.0)),
		"hp_delta": float(rv.get("hp_delta", 0.0)),
		"added_statuses": statuses,
		"fail_reason": str(rv.get("fail_reason", "")),
	}


# 角色作为 reaction target 的 tags（用于 magic.lua 的"约束多的赢"匹配）。
# 所有角色 = creature；将来对物体施法时物体走自己的 item tags（浮人比浮物难同一机制）。
static func target_tags(target: Character) -> PackedStringArray:
	var tags := PackedStringArray(["creature"])
	return tags
