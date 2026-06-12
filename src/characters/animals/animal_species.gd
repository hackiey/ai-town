class_name AnimalSpecies

# 动物物种注册表（Quaternius CC0 两套包）。单一来源：物种 id → 视觉/物理配置。
#
# 两套包各自的怪癖：
# - farm 包（FBX）：clip 名带 `Armature|` 前缀，导入约 0.01 倍 → 需放大 ~8-16×。
# - animated 包（glTF）：clip 名干净（`Idle`/`Walk`/`Attack`…），导入偏大 → 需 ~0.15-0.6×。
#   clip 解析器（animal.gd._resolve_clip）吃掉前缀差异，这里只管 model（参考）/体型/速度。
#
# `wild`：来自 animated 包（带 Attack/HitReact，用 WildAnimal）= true；farm 包（畜牧，
# 用 Animal/Livestock）= false。Cow/Horse 两包都有，畜牧版只取 farm 包，animated 的
# Cow/Horse 不收录（避免 id 撞车）。
#
# **scale 不在这里**：每个物种一个 species/<id>.tscn（见 scene_path），模型 + 成年缩放
# 烘焙在场景的 Visual 节点上——编辑器里直接拖 gizmo 调 scale 即可，单一来源。`model` 仅
# 作资产对照（runtime 不再 load 它，scene 已烘焙好实例）。

const _FARM := "res://third-party/quaternius-farm-animals/FBX/%s.fbx"
const _WILD := "res://third-party/quaternius-animated-animals/glTF/%s.gltf"
const _SCENE := "res://src/characters/animals/species/%s.tscn"

# id → { model, body_radius, body_height, move_speed, wild }
# body_radius/body_height 是世界空间（米），喂给 CollisionShape3D 胶囊 + NavigationAgent3D。
const SPECIES := {
	# ── 畜牧（farm 包，wild=false）─────────────────────────────
	"cow":   {"model": _FARM % "Cow",   "body_radius": 0.45, "body_height": 1.1, "move_speed": 1.2, "wild": false},
	"sheep": {"model": _FARM % "Sheep", "body_radius": 0.30, "body_height": 0.7, "move_speed": 1.3, "wild": false},
	"pig":   {"model": _FARM % "Pig",   "body_radius": 0.32, "body_height": 0.65, "move_speed": 1.4, "wild": false},
	"horse": {"model": _FARM % "Horse", "body_radius": 0.40, "body_height": 1.4, "move_speed": 2.0, "wild": false},
	"llama": {"model": _FARM % "Llama", "body_radius": 0.35, "body_height": 1.4, "move_speed": 1.6, "wild": false},
	"pug":   {"model": _FARM % "Pug",   "body_radius": 0.18, "body_height": 0.35, "move_speed": 1.5, "wild": false},
	"zebra": {"model": _FARM % "Zebra", "body_radius": 0.40, "body_height": 1.3, "move_speed": 2.2, "wild": false},

	# ── 野外（animated 包，wild=true）──────────────────────────
	"wolf":        {"model": _WILD % "Wolf",       "body_radius": 0.30, "body_height": 0.7, "move_speed": 2.5, "wild": true},
	"fox":         {"model": _WILD % "Fox",        "body_radius": 0.18, "body_height": 0.4, "move_speed": 3.0, "wild": true},
	"deer":        {"model": _WILD % "Deer",       "body_radius": 0.30, "body_height": 1.3, "move_speed": 2.8, "wild": true},
	"stag":        {"model": _WILD % "Stag",       "body_radius": 0.32, "body_height": 1.4, "move_speed": 2.8, "wild": true},
	"bull":        {"model": _WILD % "Bull",       "body_radius": 0.45, "body_height": 1.4, "move_speed": 2.0, "wild": true},
	"donkey":      {"model": _WILD % "Donkey",     "body_radius": 0.35, "body_height": 1.3, "move_speed": 1.8, "wild": true},
	"alpaca":      {"model": _WILD % "Alpaca",     "body_radius": 0.32, "body_height": 1.3, "move_speed": 1.6, "wild": true},
	"husky":       {"model": _WILD % "Husky",      "body_radius": 0.22, "body_height": 0.55, "move_speed": 2.5, "wild": true},
	"shiba_inu":   {"model": _WILD % "ShibaInu",   "body_radius": 0.18, "body_height": 0.4, "move_speed": 2.5, "wild": true},
	"horse_white": {"model": _WILD % "Horse_White", "body_radius": 0.40, "body_height": 1.4, "move_speed": 2.5, "wild": true},
}


# ── 畜牧生命周期参数（Phase 2）──────────────────────────────────────
# 只有"畜牧"物种有 life：能成长(young→adult)、自动繁殖、被宰杀。野外动物 / pug / zebra
# 无 life（只游荡）。时间单位是游戏小时（GameClock.total_game_hours,10× 实时）。
# slaughter 产出：成年给 qty，幼年给 qty_young。肉复用 raw_meat、皮用 raw_hide（Phase 3 新增）。
const _LIFE := {
	"cow": {
		"maturation_hours": 60.0, "fed_decay_per_hour": 3.0,
		"gestation_hours": 48.0, "breed_cooldown_hours": 96.0,
		"herd_cap": 6, "min_breed_fed": 50.0, "young_scale_mult": 0.55,
		"slaughter": [
			{"item": "raw_meat", "qty": 4, "qty_young": 1},
			{"item": "raw_hide", "qty": 1, "qty_young": 0},
		],
	},
	"horse": {
		"maturation_hours": 72.0, "fed_decay_per_hour": 3.0,
		"gestation_hours": 60.0, "breed_cooldown_hours": 120.0,
		"herd_cap": 5, "min_breed_fed": 50.0, "young_scale_mult": 0.55,
		"slaughter": [
			{"item": "raw_meat", "qty": 4, "qty_young": 1},
			{"item": "raw_hide", "qty": 1, "qty_young": 0},
		],
	},
	"llama": {
		"maturation_hours": 60.0, "fed_decay_per_hour": 2.5,
		"gestation_hours": 48.0, "breed_cooldown_hours": 96.0,
		"herd_cap": 6, "min_breed_fed": 50.0, "young_scale_mult": 0.6,
		"slaughter": [
			{"item": "raw_meat", "qty": 2, "qty_young": 1},
			{"item": "raw_hide", "qty": 1, "qty_young": 0},
		],
	},
	"sheep": {
		"maturation_hours": 36.0, "fed_decay_per_hour": 2.5,
		"gestation_hours": 30.0, "breed_cooldown_hours": 60.0,
		"herd_cap": 8, "min_breed_fed": 45.0, "young_scale_mult": 0.6,
		"slaughter": [
			{"item": "raw_meat", "qty": 2, "qty_young": 1},
			{"item": "raw_hide", "qty": 1, "qty_young": 0},
		],
	},
	"pig": {
		"maturation_hours": 30.0, "fed_decay_per_hour": 4.0,
		"gestation_hours": 24.0, "breed_cooldown_hours": 48.0,
		"herd_cap": 8, "min_breed_fed": 45.0, "young_scale_mult": 0.5,
		"slaughter": [
			{"item": "raw_meat", "qty": 3, "qty_young": 1},
		],
	},
}


static func has(species_id: String) -> bool:
	return SPECIES.has(species_id)


# 物种 prefab 路径：species/<id>.tscn（模型 + scale 烘焙好的继承场景）。
# from_spawn_data / 编辑器摆点都用它；缺文件 = 忘了建场景（调用方 fail-loud）。
static func scene_path(species_id: String) -> String:
	return _SCENE % species_id


# 畜牧生命周期参数；非畜牧物种返回空 dict。
static func life_of(species_id: String) -> Dictionary:
	var entry: Variant = _LIFE.get(species_id, {})
	return entry if entry is Dictionary else {}


# 是否畜牧（有 life = 能成长/繁殖/宰杀）。野外动物 + pug/zebra = false。
static func is_livestock(species_id: String) -> bool:
	return _LIFE.has(species_id)


# 返回物种配置（Dictionary）；未知物种返回空 dict —— 调用方 fail-loud（animal.gd._build_visual）。
static func config(species_id: String) -> Dictionary:
	var entry: Variant = SPECIES.get(species_id, {})
	return entry if entry is Dictionary else {}


static func is_wild(species_id: String) -> bool:
	return bool(config(species_id).get("wild", false))


static func ids() -> Array:
	return SPECIES.keys()
