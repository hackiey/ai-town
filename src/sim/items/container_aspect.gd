class_name ContainerAspect
extends RefCounted

# 容器视图：把 (item template, slot instance) 包成一个对象，单一来源回答
# "这桶能装多少 / 装了什么 / 装了多少 / 怎么改"。**不**渲染文字 ——
# display 由 backend item-display（Phase 3）或 Godot UI 自己处理。
#
# 设计：
# - capacity 是 template 配置（不可变），从 item.properties.capacity 读
# - amount / content 是 instance 状态，从 slot.container_amount / slot.container_content
#   平铺列读（无 sub-dict，避免水井 bug 类型的字段路径漂移）
# - with_filled 返回两键 dict {"container_amount": ..., "container_content": ...}，
#   caller 显式逐字段写回 slot
#
# 用法：
#   var c := ContainerAspect.of(item, slot)
#   if c == null: return    # 不是 container kind 时拿不到
#   if c.is_empty(): ...
#   var fields := c.with_filled(c.capacity(), "water")
#   slot["container_amount"] = fields["container_amount"]
#   slot["container_content"] = fields["container_content"]

var item: Item
var slot: Dictionary


# kind != "container" 返回 null。caller 拿 null 表示 "这个 slot 不是容器，不要继续"。
static func of(item_: Item, slot_: Dictionary) -> ContainerAspect:
	if item_ == null or item_.kind != "container":
		return null
	var aspect := ContainerAspect.new()
	aspect.item = item_
	aspect.slot = slot_
	return aspect


# 读 ─────────────────────────────────────────────

func capacity() -> float:
	return float(item.properties.get("capacity", 0.0))


func amount() -> float:
	var v: Variant = slot.get("container_amount", null)
	if v == null:
		return 0.0
	return float(v)


func content_id() -> String:
	var v: Variant = slot.get("container_content", null)
	if v == null:
		return ""
	return String(v)


func is_empty() -> bool:
	return amount() <= 0.0 or content_id().is_empty()


func is_full() -> bool:
	return amount() >= capacity()


# 液体物质的当前品质 = slot.quality（不另开列）。空容器返回 100 占位。
func quality() -> float:
	return float(slot.get("quality", 100))


# 写 ─────────────────────────────────────────────
# 返回 {"container_amount": <float>, "container_content": <String>}。
# caller 逐字段写回 slot（平铺列；slot["properties"] 子 dict 已废弃）。

func with_filled(new_amount: float, new_content: String) -> Dictionary:
	var clamped := clampf(new_amount, 0.0, capacity())
	var resolved_content := new_content if clamped > 0.0 else ""
	return {
		"container_amount": clamped,
		"container_content": resolved_content,
	}


func with_consumed(qty: float) -> Dictionary:
	return with_filled(amount() - qty, content_id())


# 倒入 add_amount 份品质 add_quality 的 content 液体，按量加权平均品质。
# 返回 {container_amount, container_content, quality}；caller 逐字段写回 slot。
# 实际倒入量受容量限制（caller 应已用 transfer 算好 add_amount，但此处再夹一次更安全）。
func with_blended(add_amount: float, add_quality: float, content: String) -> Dictionary:
	var cur := amount()
	var new_amount := clampf(cur + add_amount, 0.0, capacity())
	var added := new_amount - cur
	var blended_q := quality()
	if new_amount > 0.0 and added > 0.0:
		blended_q = (quality() * cur + add_quality * added) / new_amount
	return {
		"container_amount": new_amount,
		"container_content": content if new_amount > 0.0 else "",
		"quality": blended_q,
	}
