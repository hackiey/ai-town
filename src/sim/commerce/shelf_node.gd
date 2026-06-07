class_name ShelfNode
extends ContainerNode

# 货架 = 无锁的容器。继承 ContainerNode 的 proximity / approach / slot 库存 / 注册到 Containers。
# 货架与容器的唯一区别：
#   1. 永不上锁（lock_item_id 留空）→ 人人可存取。
#   2. 槽位可带 listing_price_centi 标价（仅展示，付钱靠 trade/give + 反应层涌现，无硬性扣钱）。
#   3. 显示名走 location.<id>.name（铺面名），而非 container.<id>.name。
#
# 迁移期：shelf_id / shelf_name / location_id 是兼容旧 .tscn 字段的 setter shim，
# 自动同步到基类的 workstation_id / container_name。

const _SHELF_DISPLAY_NAME := "货架"

@export var shelf_id: String = "":
	set(value):
		shelf_id = value
		var v := value.strip_edges()
		if not v.is_empty() and workstation_id.strip_edges().is_empty():
			workstation_id = v

@export var shelf_name: String = "":
	set(value):
		shelf_name = value
		var v := value.strip_edges()
		if not v.is_empty() and container_name.strip_edges().is_empty():
			container_name = v

# 货架所属铺面，用于显示名（location.<id>.name）。owner_group（继承自基类）已不再闸门使用。
@export var location_id: String = ""


# 货架进 "workstations"+"containers"（走容器统一通道）+"shelves"（场景扫描 / 静态 seed 用）。
func _runtime_groups() -> PackedStringArray:
	return PackedStringArray(["workstations", "containers", "shelves"])


func effective_shelf_id() -> String:
	return effective_container_id()


func effective_location_id() -> String:
	var loc := location_id.strip_edges()
	return loc if not loc.is_empty() else effective_shelf_id()


# 货架显示名：手动 shelf_name（→ container_name）→ location.<id>.name → 默认"货架"。
func effective_display_name() -> String:
	var custom := container_name.strip_edges()
	if not custom.is_empty():
		return custom
	var loc_id := effective_location_id()
	var key := "location.%s.name" % loc_id
	var localized := tr(key)
	if localized != key:
		return localized
	return _SHELF_DISPLAY_NAME


func matches_shelf_id(value: String) -> bool:
	return matches_container_id(value)


# 货架标价展示文本（仅 flavor）。无标价 → 空串。
func price_text_for_slot(slot: Dictionary) -> String:
	var centi := int(slot.get("listing_price_centi", 0)) if slot.get("listing_price_centi", null) != null else 0
	if centi <= 0:
		return ""
	return Money.format_silver_from_centi(centi)
