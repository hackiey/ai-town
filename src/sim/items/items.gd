class_name Items

# 静态 item 注册表。mirror Materials/Verbs/... 模式——所有 item 在脚本加载时一次 preload，
# 运行期 Items.by_id("tomato_seed") 零开销。
#
# 加新 item：① 写 data/items/<id>.tres ② 在 _ALL 加一行
# 远期：扫 data/items/*.tres 自动注册（避免漏填）+ LLM 生成的 item 走持久化存储而非 .tres。

const _ALL := {
	"tomato_seed":  preload("res://data/items/tomato_seed.tres"),
	"tomato_fruit": preload("res://data/items/tomato_fruit.tres"),
	"flax_seed":    preload("res://data/items/flax_seed.tres"),
	"flax_bundle":  preload("res://data/items/flax_bundle.tres"),
	# === Crafting (base-items.md MVP) ===
	# 层 A 原料
	"wood":         preload("res://data/items/wood.tres"),
	"stone":        preload("res://data/items/stone.tres"),
	"iron_ore":     preload("res://data/items/iron_ore.tres"),
	"copper_ore":   preload("res://data/items/copper_ore.tres"),
	"tin_ore":      preload("res://data/items/tin_ore.tres"),
	"charcoal":     preload("res://data/items/charcoal.tres"),
	"wheat":        preload("res://data/items/wheat.tres"),
	"raw_meat":     preload("res://data/items/raw_meat.tres"),
	"egg":          preload("res://data/items/egg.tres"),
	"berry":        preload("res://data/items/berry.tres"),
	"salt":         preload("res://data/items/salt.tres"),
	# 水不是独立 item——液体只能存在于容器里。craft 时拖容器到 staging，
	# server 把 1 单位 content 物化成临时 instance 喂给 dispatcher。见 wood_bucket + well。
	# 层 B 加工件
	"iron_ingot":     preload("res://data/items/iron_ingot.tres"),
	"copper_ingot":   preload("res://data/items/copper_ingot.tres"),
	"tin_ingot":      preload("res://data/items/tin_ingot.tres"),
	"iron_blade":     preload("res://data/items/iron_blade.tres"),
	"iron_pick_head": preload("res://data/items/iron_pick_head.tres"),
	"iron_axe_head":  preload("res://data/items/iron_axe_head.tres"),
	"wood_shaft":     preload("res://data/items/wood_shaft.tres"),
	"wood_plank":     preload("res://data/items/wood_plank.tres"),
	"rope":           preload("res://data/items/rope.tres"),
	"flour":          preload("res://data/items/flour.tres"),
	"dough":          preload("res://data/items/dough.tres"),
	# 层 C 成品工具
	"iron_shovel":    preload("res://data/items/iron_shovel.tres"),
	"iron_pick":      preload("res://data/items/iron_pick.tres"),
	"iron_axe":       preload("res://data/items/iron_axe.tres"),
	"iron_knife":     preload("res://data/items/iron_knife.tres"),
	"sickle":         preload("res://data/items/sickle.tres"),
	# 层 C 食物
	"bread":          preload("res://data/items/bread.tres"),
	"veg_stew":       preload("res://data/items/veg_stew.tres"),
	"cooked_meat":    preload("res://data/items/cooked_meat.tres"),
	"omelet":         preload("res://data/items/omelet.tres"),
	"berry_jam":      preload("res://data/items/berry_jam.tres"),
	"herbal_remedy":  preload("res://data/items/herbal_remedy.tres"),
	"mint_seed":      preload("res://data/items/mint_seed.tres"),
	"mint_leaf":      preload("res://data/items/mint_leaf.tres"),
	"mugwort_seed":   preload("res://data/items/mugwort_seed.tres"),
	"mugwort_leaf":   preload("res://data/items/mugwort_leaf.tres"),
	"ginger_seed":    preload("res://data/items/ginger_seed.tres"),
	"ginger_root":    preload("res://data/items/ginger_root.tres"),
	"plantain_seed":  preload("res://data/items/plantain_seed.tres"),
	"plantain_leaf":  preload("res://data/items/plantain_leaf.tres"),
	"calendula_seed": preload("res://data/items/calendula_seed.tres"),
	"calendula_flower": preload("res://data/items/calendula_flower.tres"),
	"valerian_seed":  preload("res://data/items/valerian_seed.tres"),
	"valerian_root":  preload("res://data/items/valerian_root.tres"),
	"mint_mugwort_tea": preload("res://data/items/mint_mugwort_tea.tres"),
	"ginger_plantain_broth": preload("res://data/items/ginger_plantain_broth.tres"),
	"calendula_salve": preload("res://data/items/calendula_salve.tres"),
	"valerian_tonic": preload("res://data/items/valerian_tonic.tres"),
	# 层 C 腌制（盐反应输出）— 比对应 cooked 版 buff 略高 + shelf_life ×3-5
	"cured_meat":     preload("res://data/items/cured_meat.tres"),
	"cured_omelet":   preload("res://data/items/cured_omelet.tres"),
	"cured_stew":     preload("res://data/items/cured_stew.tres"),
	# 腐烂态（spoilage tick swap target）— kind=trash 不能吃
	"rotten_food":    preload("res://data/items/rotten_food.tres"),
	# 层 D 容器（kind=container, stackable=false）
	"wood_bucket":    preload("res://data/items/wood_bucket.tres"),
	"brewing_barrel": preload("res://data/items/brewing_barrel.tres"),
	"cup":            preload("res://data/items/cup.tres"),
	# 酿造链：小麦 → 麦芽（晾晒）→ 麦芽酒（发酵）
	"malt":           preload("res://data/items/malt.tres"),
	"beer":           preload("res://data/items/beer.tres"),
	# 农事消耗品
	"wood_ash":       preload("res://data/items/wood_ash.tres"),
	# 货币系统：贵金属矿石 + 铸币（1 金币 = 10 银币；金矿石 1:1 铸金币，银矿石 1:5 铸银币）
	"gold_ore":       preload("res://data/items/gold_ore.tres"),
	"silver_ore":     preload("res://data/items/silver_ore.tres"),
	"gold_coin":      preload("res://data/items/gold_coin.tres"),
	"silver_coin":    preload("res://data/items/silver_coin.tres"),
	"royal_key":      preload("res://data/items/royal_key.tres"),
}


static func by_id(id: String) -> Item:
	return _ALL.get(id)


static func all_ids() -> Array:
	return _ALL.keys()


static func has_id(id: String) -> bool:
	return _ALL.has(id)


# 按 (shape_type, body_material) 查 template id。用于 dispatcher 给 crafted instance
# 找一个"已知物品"的 id（比如 (flat_blade, iron) → "iron_blade"），找不到就返回 ""。
static func find_template(shape_type: String, body_material: String) -> String:
	if shape_type.is_empty():
		return ""
	for id in _ALL.keys():
		var it: Item = _ALL[id]
		if it.shape_type != shape_type:
			continue
		var mat = it.materials.get("body", "")
		if String(mat) == body_material:
			return String(id)
	return ""
