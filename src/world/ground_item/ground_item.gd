class_name GroundItem
extends StaticBody3D

# 地面上的可视化物品。每个 GroundItem 持一个 InventorySlotData dict，承担：
#   - 显示对应 mesh（默认 sack，inherited 子场景 override Mesh.mesh）
#   - 加入 world_items / ground_items group，供 character_perception + LLM 感知
#   - 持 db_id，捡起 / 销毁时由 caller 调 Db.delete_ground_item(db_id)
#
# 不在场景树里 tick 新鲜度——slot.freshness_age_hours 在 drop 那一刻冻结，
# 捡起后由 inventory 重新接管 perishable 衰减。地面变质 v1 不做。

const ITEM_GROUPS := ["world_items", "ground_items"]   # 配合 character_perception.gd:153

# per item 没配 world_mesh 时的 fallback（默认 sack）。
const _BASE := preload("res://src/world/ground_item/ground_item.tscn")

@onready var _quantity_label: Label3D = $QuantityLabel

var db_id: String = ""              # SQLite item_instances.id（ownerKind='world'）
var slot_data: Dictionary = {}      # InventorySlotData dict 深拷贝
var item_id: String = ""


# GroundItemSpawner(MultiplayerSpawner)的 spawn_function。server + client 两端都跑
# 同样代码、同样 data，所以地面物品像 Crop 一样自动复制到所有 peer（含晚加入的）。
# data = {id, slot, pos}；只设纯数据字段，视觉(label)留给 _ready()——此处节点尚未入树，
# @onready 还没解析。不 add_child：MultiplayerSpawner 负责挂到 spawn_path 下。
static func from_spawn_data(data: Variant) -> Node:
	var d: Dictionary = data as Dictionary
	var slot: Dictionary = d.get("slot", {}) as Dictionary
	var item_id := String(slot.get("item_id", ""))
	var item: Item = Items.by_id(item_id)
	# Item.world_mesh 现在指 inherited ground tscn（per item）；没配就 fallback 到 base。
	var scene: PackedScene = item.world_mesh if (item != null and item.world_mesh != null) else _BASE
	var node: GroundItem = scene.instantiate()
	node.db_id = String(d.get("id", ""))
	node.slot_data = slot.duplicate(true)
	node.item_id = item_id
	# 容器 GroundItems 在原点，本地坐标即世界坐标。
	node.position = d.get("pos", Vector3.ZERO)
	return node


func _ready() -> void:
	for g in ITEM_GROUPS:
		add_to_group(g)
	_refresh_quantity_label()


# Spawner / hydrate 调。slot 会被深拷贝，原 dict 不动。label 由 _ready 统一刷（入树后
# @onready 才解析），所以这里只写纯数据，不碰 _quantity_label。
func setup(slot: Dictionary) -> void:
	slot_data = slot.duplicate(true)
	item_id = String(slot.get("item_id", ""))
	if is_node_ready():
		_refresh_quantity_label()


func _refresh_quantity_label() -> void:
	if _quantity_label == null:
		return
	var qty := int(slot_data.get("quantity", 1))
	_quantity_label.text = str(qty)
	_quantity_label.visible = qty > 1


func display_name() -> String:
	return InventorySlotData.of(slot_data).display_name()


func quantity() -> int:
	return int(slot_data.get("quantity", 0))
