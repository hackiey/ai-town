class_name SpellCatalog

# 投递层咒语注册表（GDScript，不 .tres——避 Resource 跨实例坑；per-spell 投递 .lua 以后再说）。
# 只描述"怎么送达"：target_type / delivery / cast_time / 弹道参数。物理后果在 data/mechanics/magic.lua
# 的 reaction（按 verb 选），威力四因子在 SpellPower。effect_verb 默认 == id。
# 设计：docs/architecture/combat-system.md §4.1。

const SPELLS := {
	"stupefy": {
		"id": "stupefy",
		"verb": "stupefy",
		"school": "combat",
		"delivery": "projectile",      # 瞄准弹道
		"cast_time": 0.6,
		"projectile_speed": 22.0,
		"ttl": 2.0,
	},
	"protego": {
		"id": "protego",
		"verb": "protego",
		"school": "combat",
		"delivery": "self_cast",       # 自施，命中即自身
		"cast_time": 0.4,
	},
}


static func get_spell(id: String) -> Dictionary:
	return SPELLS.get(id, {})


static func has(id: String) -> bool:
	return SPELLS.has(id)


static func ids() -> Array:
	return SPELLS.keys()
