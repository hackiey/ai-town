class_name PerishableAspect
extends RefCounted

# 鲜度视图：把 slot 包成"会腐烂的物品"。
# 何谓 perishable：body material 有 shelf_life > 0 OR category=="spoiled"。
# 不是 perishable → PerishableAspect.of() 返回 null（caller 直接跳过）。
#
# tier 在 character.gd 的 spoilage tick 里更新（写 slot.freshness_tier）。
# 这个类只暴露 typed getter；display 由 backend item-display（Phase 3）或 Godot UI 自己处理。

var slot: Dictionary


static func of(slot_: Dictionary) -> PerishableAspect:
	var mats_v: Variant = slot_.get("materials", {})
	if typeof(mats_v) != TYPE_DICTIONARY:
		return null
	var body_id := String((mats_v as Dictionary).get("body", ""))
	if body_id.is_empty():
		return null
	var mat: Substance = Materials.by_id(body_id)
	if mat == null:
		return null
	if mat.shelf_life_hours <= 0.0 and mat.category != "spoiled":
		return null
	var aspect := PerishableAspect.new()
	aspect.slot = slot_
	return aspect


func is_rotten() -> bool:
	var mat := _body_material()
	return mat != null and mat.category == "spoiled"


func tier() -> int:
	var v: Variant = slot.get("freshness_tier", null)
	if v == null:
		return 5
	return int(v)


# 衰减 + swap 规则迁到 data/mechanics/perishable.lua；本类只剩只读 typed getter。

func _body_material() -> Substance:
	var mats_v: Variant = slot.get("materials", {})
	if typeof(mats_v) != TYPE_DICTIONARY:
		return null
	var body_id := String((mats_v as Dictionary).get("body", ""))
	if body_id.is_empty():
		return null
	return Materials.by_id(body_id)


static func tier_name(t: int) -> String:
	if t >= 5:
		return "新鲜"
	if t == 4:
		return "良好"
	if t == 3:
		return "一般"
	if t == 2:
		return "陈旧"
	if t == 1:
		return "将腐"
	return "已腐烂"
