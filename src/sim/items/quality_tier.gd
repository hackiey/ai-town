class_name QualityTier

# 品质 4 桶定义（id / 中文名 / 颜色），单一来源。
# - id：稳定 machine string，给 backend snapshot / persistence 用（"premium"/"good"/"normal"/"bad"）
# - display_name：UI tooltip 用的中文名（"极品"/"优"/"普通"/"次品"）
# - color：inventory slot 边框颜色
# - multiplier：线性 q/100，不桶化（理由：character.gd 历史注释——4 桶 multiplier 会让
#   2 肉 q70 算成满营养，鼓励 overstuff；线性后 0.7×0.7=0.49 < 1.0×，没套利空间）
#
# 阈值改这里一处，UI/backend/dispatcher/crop 全跟。

const _TIERS := [
	{"min": 90, "id": "premium", "display_name": "极品", "color": Color(1.0, 0.78, 0.0)},
	{"min": 70, "id": "good",    "display_name": "优",   "color": Color(0.4, 0.85, 0.5)},
	{"min": 40, "id": "normal",  "display_name": "普通", "color": Color(0.85, 0.85, 0.85)},
	{"min": 1,  "id": "bad",     "display_name": "次品", "color": Color(0.55, 0.55, 0.55)},
]
const _EMPTY := {"id": "none", "display_name": "—", "color": Color(0, 0, 0, 0)}


static func _tier(q: int) -> Dictionary:
	for t in _TIERS:
		if q >= int(t["min"]):
			return t
	return _EMPTY


static func id(q: int) -> String:
	return String(_tier(q)["id"])


static func display_name(q: int) -> String:
	return String(_tier(q)["display_name"])


static func color(q: int) -> Color:
	return _tier(q)["color"] as Color


static func multiplier(q: int) -> float:
	return clampf(float(q) / 100.0, 0.0, 1.0)
