class_name ContainerNode
extends WorkstationNode

# 容器节点 = WorkstationNode 的子类型。继承 proximity / approach / lock。
# 额外语义：slot 库存（持久化在 Containers autoload + DB），交互模式 "container"
# 触发独立 inventory UI 而不是 ActionPanel slot grid。

@export_range(1, 999, 1) var slot_count: int = 12

# 容器内容 = 运行时内存权威（server 端由 Containers 维护，DB 只做写穿持久化）。
# 密集数组，长度 = slot_count，空槽是 InventorySlotData.empty()。**不直接同步**——
# treasury_vault 有 999 槽，整数组序列化 ~387KB 远超 ENet 单包 MTU(64KB)。client 显示走
# 「玩家正在查看的那一页」（Player.view_slots，owner-private 同步，见 player.gd）。
var contents: Array[Dictionary] = []

# 容器/货架钱包。钱币不占 contents 槽位；所有 silver_coin/gold_coin 都折算进这里。
var wallet_centi: int = 0

# 被动反应的 vessel 能力 tag 集合。匹配反应表里 match.vessel_tag（data/mechanics/crafting.lua）：
#   "drying" → 槽内匹配的物品(如 wheat)被 PassiveSimulator 自动晾成 malt（auto_start）。
#   （未来加 "smoking" 等就在这里追加；发酵的 brewing_vessel 在物品自身 tag 上，不在这里）
# 普通容器留空 = 不提供任何被动能力（背包水果不会"自动变"）。
@export var passive_tags: PackedStringArray = PackedStringArray()

# 无限液体源（水井）。非空 = 这个容器是某液体的取之不尽来源（take 不减量、不需要 slot 存储）。
# put_take 从这种容器取液体走 LiquidOps.fill_from_source。
@export var infinite_content: String = ""
@export var infinite_quality: int = 100


func has_passive_tag(tag: String) -> bool:
	return passive_tags.has(tag)


func is_infinite_source() -> bool:
	return not infinite_content.strip_edges().is_empty()

# 容器同时进 "workstations"（让 backend perception / E-key 走统一通道）
# 和 "containers"（让 Containers autoload + ContainerPanel 用类型分支查找）。
func _runtime_groups() -> PackedStringArray:
	return PackedStringArray(["workstations", "containers"])


func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	if Containers != null and Containers.has_method("register_container"):
		Containers.register_container(self)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if Containers != null and Containers.has_method("unregister_container"):
		Containers.unregister_container(self)


func effective_container_id() -> String:
	return world_object_id()


# 显示名查找顺序：container.<def_id>.name → 基类 workstation.<def_id>.name → def_id 兜底。
func effective_display_name() -> String:
	var cid := world_object_def_id()
	var key := "container.%s.name" % cid
	var localized := tr(key)
	if localized != key:
		return localized
	var ws_name := display_name
	if not ws_name.is_empty() and not ws_name.begins_with("workstation."):
		return ws_name
	return cid


func _refresh_labels() -> void:
	var title := get_node_or_null("Title") as Label3D
	if title != null:
		title.text = effective_display_name()
	var label := get_node_or_null("Prompt") as Label3D
	if label != null:
		var key := "ui.container.prompt_default"
		var prompt := tr(key)
		label.text = prompt if prompt != key and not prompt.is_empty() else "按 E 查看"


func matches_container_id(value: String) -> bool:
	return effective_container_id() == value.strip_edges()


# Shim：综合 group + 锁。等同基类 can_actually_use。
func can_be_opened_by(character: Node) -> bool:
	return can_actually_use(character)


func requires_key() -> bool:
	return is_locked()
