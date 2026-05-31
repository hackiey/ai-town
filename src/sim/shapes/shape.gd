class_name Shape
extends Resource

# 物品形状元数据。每个 shape 一个 .tres，由 Shapes autoload 索引。
#
# 设计：docs/architecture/reaction-schema.md §9.3
# - shape_type 是反应匹配的关键字段（"flat_blade" / "ingot" / ...）
# - 视觉资产按 (shape_type, primary_part 的材质) 查找：data/visual_assets/<shape>/<material>.png
# - parent 用于资产 fallback（找不到精确 shape 资产时用父形状的）

@export var type: String = ""                   # 唯一 id，等同 Item.shape_type 字段值

# display_name 走 i18n catalog: data/i18n/<locale>/shapes.json -> shape.<type>.name
var display_name: String:
	get: return tr("shape.%s.name" % type) if not type.is_empty() else ""
	set(_value): pass

@export var parent: String = ""                 # 父形状 id；空 = 根
@export var primary_part: String = "body"       # 视觉主色取这个 part 的材质
@export var secondary_parts: PackedStringArray = []
