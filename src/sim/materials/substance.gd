class_name Substance
extends Resource

# 反应表与物品共用的材质资源。每个材质一个 .tres，全局共享，由 Materials autoload 索引。
# 注：class_name 用 Substance（不是 Material）——Godot 引擎占用了 Material 用于渲染。
# 设计文档里全文叫 Material，对应这里的 Substance 类是同一个概念。
#
# 设计：docs/architecture/reaction-schema.md §2.1
# - 物理常数（hardness / 热学）+ 反应链（transforms / alloys）+ 应用域字段（extra）
# - extra Dictionary 承接非物理字段（wand_charges_capacity / use_effects 等）
#   dispatcher 表达式优先读 @export 字段，找不到回落 extra[key]
# - tags：作为材质特征参与 reaction 输入匹配（"metal" / "ferrous" / "magnetic"）

@export var id: String = ""

# display_name 走 i18n catalog: data/i18n/<locale>/materials.json -> material.<id>.name
var display_name: String:
	get: return tr("material.%s.name" % id) if not id.is_empty() else ""
	set(_value): pass
@export var category: String = ""               # metal / wood / fiber / stone / liquid / food / ...

# 物理常数（从旧 Substance 合并而来，加上 reaction-schema §2.1 列的字段）
@export var hardness: int = 0                   # 0-100
@export var density: float = 1.0                # g/cm³
@export var melting_point: float = -1.0         # °C, -1 = 不熔
@export var boiling_point: float = -1.0
@export var ignite_temperature: float = -1.0    # °C, -1 = 不可燃
@export var flammable: bool = false
@export var burn_rate: float = 0.0              # kg/s 持续燃烧的质量衰减；0 = 不持续燃烧
@export var thermal_capacity: float = 1000.0    # J/(kg·°C)
@export var thermal_conductivity: float = 0.5   # 0-1 相对值
@export_range(0.0, 1.0) var brittleness: float = 0.5
@export_range(0.0, 1.0) var electrical_conductivity: float = 0.0
@export_enum("solid", "liquid", "gas") var default_state: int = 0

# 危险性（v4，影响 reaction 失败时的额外效果）
# 例：sulfur.hazards = ["flammable", "explosive_when_heated"]
@export var hazards: PackedStringArray = []

# 视觉
@export var tint: Color = Color(0.7, 0.7, 0.75, 1)
@export var visual_fallback: String = ""        # 资产缺失时回退到这个材质的 mesh / icon

# 转化（被某 verb 作用后变成什么材质）
# 例：iron_ore.transforms = {"smelt": "iron"}
@export var transforms: Dictionary = {}

# 合金（和某材质在 alloy verb 下生成新材质）
# 例：copper.alloys = {"tin": "bronze", "zinc": "brass"}
@export var alloys: Dictionary = {}

# 腐烂：shelf_life_hours = 0 → 不腐烂；> 0 → 入库后按 (shelf_life / 5) game-hour
# 降一级 freshness_tier，tier 跌到 0 时把材质换成 rotten_into 指向的材质。
# 设计：docs/recipes.md "腐烂系统"。
@export var shelf_life_hours: float = 0.0
@export var rotten_into: String = ""

# 标签
@export var tags: PackedStringArray = []

# 应用域字段（v4 字段开放原则）。dispatcher 表达式按需读：
# moonstone.extra.wand_charges_capacity = 150
# bread.extra.use_effects = [{"stat": "hunger", "delta": 30}]
@export var extra: Dictionary = {}


# 用于表达式 lookup：先查 @export 具名字段，找不到回落 extra
func get_field(name: String) -> Variant:
	if name in self:
		return get(name)
	return extra.get(name)
