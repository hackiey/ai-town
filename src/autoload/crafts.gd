extends Node

# Autoload: Crafts
#
# 手艺（craft）真值访问层。真值在 res://data/skills/crafts.json，与 backend
# craft-registry.ts 读同一份。禁止再起镜像表。
#
# craft = LLM 看到的一个手艺工具（mine / cook / smith…），背后由 (workstation, verb)
# 决定路由到哪个 lua reaction。新增 craft 改 data/skills/crafts.json，别动这里。
#
# 用法：
#   Crafts.is_action("mine")                       → true（mine 是 craft 之一）
#   Crafts.is_action("draw_water")                 → true（直接使用型工作台也算）
#   Crafts.for_workstation_verb("anvil", "shape")  → "smith"
#   Crafts.for_workstation_verb("well", "direct")  → ""（不属于 craft）

const CRAFTS_JSON_PATH := "res://data/skills/crafts.json"

var _crafts: Dictionary = {}             # slug → { skillId, operations[], ... }
var _action_set: Dictionary = {}         # slug → true（O(1) 判定）
var _by_ws_verb: Dictionary = {}         # "workstation|verb" → craft slug


func _ready() -> void:
	_load()


func _load() -> void:
	if not FileAccess.file_exists(CRAFTS_JSON_PATH):
		push_error("[Crafts] missing %s" % CRAFTS_JSON_PATH)
		return
	var raw := FileAccess.get_file_as_string(CRAFTS_JSON_PATH)
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[Crafts] %s must be a JSON object" % CRAFTS_JSON_PATH)
		return
	var root: Dictionary = parsed
	var crafts_v: Variant = root.get("crafts", {})
	if typeof(crafts_v) != TYPE_DICTIONARY:
		push_error("[Crafts] missing top-level `crafts` object")
		return
	_crafts = crafts_v as Dictionary
	# 构造 (workstation, verb) → slug 反向索引和 action 集合。
	_action_set.clear()
	_by_ws_verb.clear()
	for slug_v in _crafts.keys():
		var slug := str(slug_v)
		_action_set[slug] = true
		var rec: Dictionary = _crafts[slug_v]
		var ops_v: Variant = rec.get("operations", [])
		if not (ops_v is Array):
			continue
		for op_v in ops_v:
			if typeof(op_v) != TYPE_DICTIONARY:
				continue
			var op: Dictionary = op_v
			var key := "%s|%s" % [str(op.get("workstation", "")), str(op.get("verb", ""))]
			_by_ws_verb[key] = slug


# 任何登记过的 craft slug（含 draw_water 这种无 skill 的直接使用型）→ true。
func is_action(name: String) -> bool:
	return _action_set.get(name, false)


# (workstation, verb) → craft slug。无匹配返回空字符串。
# 用作 world event 名（event 名就是 craft slug）和 reaction-catalog 反查。
func for_workstation_verb(workstation_id: String, verb: String) -> String:
	var key := "%s|%s" % [workstation_id, verb]
	return str(_by_ws_verb.get(key, ""))


# craft → 对应 proficiency skill_id。GD 端 _commit_active 用来 surface 给 event。
func skill_id_for(craft_slug: String) -> String:
	var rec_v: Variant = _crafts.get(craft_slug, {})
	if typeof(rec_v) != TYPE_DICTIONARY:
		return ""
	return str((rec_v as Dictionary).get("skillId", ""))


# 所有非空 skill_id，按 crafts.json 插入顺序去重。
# 顺序对应"采集→加工→烹饪"链条，UI（玩家面板手艺 tab）直接拿来当列序。
func all_skill_ids() -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	for slug_v in _crafts.keys():
		var rec_v: Variant = _crafts[slug_v]
		if typeof(rec_v) != TYPE_DICTIONARY:
			continue
		var skill_id := str((rec_v as Dictionary).get("skillId", ""))
		if skill_id.is_empty() or seen.has(skill_id):
			continue
		seen[skill_id] = true
		out.append(skill_id)
	return out
