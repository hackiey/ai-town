class_name Verb
extends Resource

# 反应动词。每个 verb 一个 .tres，由 Verbs autoload 索引。
#
# 设计：docs/architecture/reaction-schema.md §2.2
# - Verb 不再决定 strategy（v2 修订搬到 Reaction）
# - 每个 verb 由若干 workstation 支持（关系存在 WorkstationDef.verbs）
# - sub_options 解决"同输入同 verb 想要不同输出"的歧义（铁砧锻刃 vs 斧头）

@export var id: String = ""

# display_name 走 i18n catalog: data/i18n/<locale>/verbs.json -> verb.<id>.name
var display_name: String:
	get: return tr("verb.%s.name" % id) if not id.is_empty() else ""
	set(_value): pass

# 副选项：sub_option_id → display 占位（值已迁到 catalog）。空 dict = 无副选项。
# 例：shape.sub_options = {"blade": "", "axe_head": "", "pick_head": ""}
# 显示名：sub_option_label(sub_id) -> tr("verb.<id>.sub_option.<sub_id>")
@export var sub_options: Dictionary = {}


func sub_option_label(sub_id: String) -> String:
	if id.is_empty() or sub_id.is_empty():
		return sub_id
	return tr("verb.%s.sub_option.%s" % [id, sub_id])
