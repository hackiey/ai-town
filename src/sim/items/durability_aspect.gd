class_name DurabilityAspect
extends RefCounted

# 工具耐久视图。item.properties.max_durability > 0 才适用。
# value() 当前剩余；max_value() 上限；with_decremented(amount) 返回新 durability int。
#
# 设计同 ContainerAspect / PerishableAspect：只读 typed 字段（slot.durability 平铺列），
# 不渲染文字 —— display 由 backend item-display 模块（Phase 3）或 Godot UI 自己处理。

var item: Item
var slot: Dictionary


# 不计耐久（max_durability <= 0）→ 返回 null。
static func of(item_: Item, slot_: Dictionary) -> DurabilityAspect:
	if item_ == null:
		return null
	if int(item_.properties.get("max_durability", 0)) <= 0:
		return null
	var a := DurabilityAspect.new()
	a.item = item_
	a.slot = slot_
	return a


func max_value() -> int:
	return int(item.properties.get("max_durability", 0))


# slot.durability 为 null = 全新工具，回退 max_value()。
func value() -> int:
	var v: Variant = slot.get("durability", null)
	if v == null:
		return max_value()
	return int(v)


# 不直接 mutate slot；返回新的 durability int，caller 自行写回 slot["durability"]。
func with_decremented(amount: int) -> int:
	return maxi(value() - maxi(0, amount), 0)
