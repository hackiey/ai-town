class_name ShelfNode
extends ContainerNode

# 货架 = 无锁的容器。继承 ContainerNode 的 proximity / approach / slot 库存 / 注册到 Containers。
# 货架与容器的唯一区别：
#   1. 永不上锁（WorldObjectIdentity.lock_item_id 留空）→ 人人可存取。
#   2. 槽位可带 listing_price_centi 标价；put_take 直接取带标价商品时会校验货架钱包付款。
#   3. 显示名走 WorldObjectIdentity.def_id 对应的 workstation i18n。

const _SHELF_DISPLAY_NAME := "货架"

# 货架进 "workstations"+"containers"（走容器统一通道）+"shelves"（场景扫描 / 静态 seed 用）。
func _runtime_groups() -> PackedStringArray:
	return PackedStringArray(["workstations", "containers", "shelves"])


func effective_shelf_id() -> String:
	return effective_container_id()


func effective_location_id() -> String:
	var identity := world_object_identity()
	if identity != null and not identity.parent_object_id.strip_edges().is_empty():
		return identity.parent_object_id.strip_edges()
	return effective_shelf_id()


# 货架显示名：workstation.<def_id>.name → 默认"货架"。
func effective_display_name() -> String:
	var name := display_name.strip_edges()
	return name if not name.is_empty() else _SHELF_DISPLAY_NAME


func matches_shelf_id(value: String) -> bool:
	return matches_container_id(value)


# 货架标价展示文本（仅 flavor）。无标价 → 空串。
func price_text_for_slot(slot: Dictionary) -> String:
	var centi := int(slot.get("listing_price_centi", 0)) if slot.get("listing_price_centi", null) != null else 0
	if centi <= 0:
		return ""
	return Money.format_silver_from_centi(centi)
