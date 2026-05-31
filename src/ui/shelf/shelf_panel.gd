class_name ShelfPanel
extends CanvasLayer

# 玩家货架面板（client only）：
# - shelf_proximity_changed(entered=true) 时记录 active；按 E 弹面板
# - 左栏：货架陈列（Shelves.adapter_listing_slots 实时拉），每行 = item + 单价 + 买/管理按钮
# - 右栏：玩家背包（非空 slot），每行 = item + 数量 + （管理模式时）「上架」按钮
# - 走出货架 3m 半径 → Area3D 报 exited → 自动关
# - 买/上架/下架/改价全部通过 server-RPC (Player.request_buy_from_shelf / request_update_shelf)，
#   server 端 Shelves.* 做最终校验；UI 只负责构造合法请求和显示结果。
#
# 模式：
# - 买家模式（默认）：左栏每行 [买1][全买]；右栏只读
# - 管理模式（owner_group 成员，由 ShelfNode.is_managed_by 判定）：
#     左栏每行 [改价][下架]；右栏每行 [上架...]
# 模式在 open() 时一次性决定；中途 owner_group 变化下次开面板再切换。

const Money = preload("res://src/sim/characters/money.gd")
const POPUP_PRICE_DEFAULT_SILVER := 1.0

var _player: Node = null
var _active_shelf: Node = null      # 当前 proximity 内的货架；按 E 时打开它
var _open_shelf: Node = null         # 当前实际打开的货架
var _is_owner_mode: bool = false     # 在 open() 时算好
# 变化检测——只有数据真变了才 rebuild row widgets，避免每帧 queue_free + add_child 闪烁
var _last_listings_sig: String = ""
var _last_inventory_sig: String = ""
var _last_wallet_centi: int = -1

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/Title
@onready var _wallet_label: Label = $Root/Panel/Margin/VBox/WalletLabel
@onready var _listings_box: VBoxContainer = $Root/Panel/Margin/VBox/HBox/ShelfCol/Scroll/ListingsBox
@onready var _listings_empty: Label = $Root/Panel/Margin/VBox/HBox/ShelfCol/Empty
@onready var _inventory_box: VBoxContainer = $Root/Panel/Margin/VBox/HBox/PlayerCol/Scroll/InventoryBox
@onready var _hint: Label = $Root/Panel/Margin/VBox/Footer/Hint
@onready var _close_btn: Button = $Root/Panel/Margin/VBox/Footer/Close

# 持久 popup 节点：上架时复用，避免每次构建。
var _list_popup: AcceptDialog = null
var _list_popup_qty: SpinBox = null
var _list_popup_price: SpinBox = null
var _list_popup_item_id: String = ""
var _list_popup_item_label: Label = null

# 改价 popup
var _reprice_popup: AcceptDialog = null
var _reprice_popup_price: SpinBox = null
var _reprice_popup_item_id: String = ""
var _reprice_popup_label: Label = null


func _ready() -> void:
	_root.visible = false
	EventBus.shelf_proximity_changed.connect(_on_proximity_changed)
	_close_btn.pressed.connect(close)


func set_player(player: Node) -> void:
	_player = player
	if _root.visible:
		_refresh()


func _on_proximity_changed(shelf: Node, entered: bool) -> void:
	if not _is_shelf(shelf):
		return
	if entered:
		_active_shelf = shelf
	else:
		if shelf == _active_shelf:
			_active_shelf = null
		# 走出 = 强制关面板（同 ContainerPanel）
		if shelf == _open_shelf and _root.visible:
			close()


func open(shelf: Node) -> void:
	if _player == null:
		return
	if not _is_shelf(shelf):
		push_warning("[ShelfPanel] open() called with non-shelf: %s" % shelf)
		return
	_open_shelf = shelf
	_title.text = _shelf_display_name(shelf)
	# Owner 模式判定走 shelf.is_managed_by(player_cid) —— is_managed_by 内部走
	# Db.can_access(cid, owner_group)，是否在 owner_group 由真实 SQLite 决定。
	# god 永远通过（Db.can_access 内部判断），所以 /god 后再开面板就是管理模式。
	var cid := str(_player.backend_character_id()) if _player.has_method("backend_character_id") else ""
	_is_owner_mode = shelf.is_managed_by(cid) if shelf.has_method("is_managed_by") else false
	_hint.text = tr("ui.shelf.hint_manage") if _is_owner_mode else tr("ui.shelf.hint_buy")
	# 强制下一次 _refresh 必 rebuild
	_last_listings_sig = ""
	_last_inventory_sig = ""
	_last_wallet_centi = -1
	_refresh()
	_root.visible = true
	set_process(true)


func close() -> void:
	_root.visible = false
	_open_shelf = null
	_is_owner_mode = false
	set_process(false)
	if _list_popup != null and _list_popup.visible:
		_list_popup.hide()
	if _reprice_popup != null and _reprice_popup.visible:
		_reprice_popup.hide()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_E and _active_shelf != null and not _root.visible:
		open(_active_shelf)
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and _root.visible:
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _root.visible:
		_refresh()


# 每帧重建——row 数会随 NPC 修改货架 / 玩家背包变化而变。listings 走 host 进程
# 内的 Db.list_shelf_listings（adapter_listing_slots 内调）；多人远端 client 上线
# 时需要补 readonly RPC 把 listings 推给 owner peer。TODO(multiplayer)。
func _refresh() -> void:
	if _open_shelf == null or _player == null:
		return
	_refresh_wallet()
	_refresh_listings()
	_refresh_inventory()


func _refresh_wallet() -> void:
	var centi := int(_player.wallet_centi) if "wallet_centi" in _player else 0
	if centi == _last_wallet_centi:
		return
	_last_wallet_centi = centi
	_wallet_label.text = tr("ui.shelf.wallet_format") % Money.format_silver_from_centi(centi)


func _refresh_listings() -> void:
	var slots: Array = Shelves.adapter_listing_slots(_open_shelf)
	var non_empty: Array = []
	for s in slots:
		var slot: Dictionary = s
		if int(slot.get("quantity", 0)) > 0 and not str(slot.get("item_id", "")).is_empty():
			non_empty.append(slot)
	var sig := _listings_signature(non_empty)
	if sig == _last_listings_sig:
		return
	_last_listings_sig = sig
	for c in _listings_box.get_children():
		c.queue_free()
	if non_empty.is_empty():
		_listings_empty.visible = true
		return
	_listings_empty.visible = false
	for slot in non_empty:
		_listings_box.add_child(_build_listing_row(slot))


func _refresh_inventory() -> void:
	if not "inventory" in _player:
		return
	var inv: Array = _player.inventory
	# 按 item_id+quality 聚合背包槽（NPC update_shelf 按名字操作，"上架 X 个面包"
	# 自动从所有同名 slot 抽取，UI 给一个合并视图就够了）。
	var aggregated: Array = []
	var key_to_idx := {}
	for slot_v in inv:
		var slot: Dictionary = slot_v
		var qty := int(slot.get("quantity", 0))
		if qty <= 0 or str(slot.get("item_id", "")).is_empty():
			continue
		var view := InventorySlotData.of(slot)
		var key := "%s|%d" % [view.id(), view.quality()]
		if key_to_idx.has(key):
			var idx := int(key_to_idx[key])
			var prev: Dictionary = aggregated[idx]
			prev["quantity"] = int(prev.get("quantity", 0)) + qty
			aggregated[idx] = prev
		else:
			key_to_idx[key] = aggregated.size()
			aggregated.append(slot.duplicate(true))
	var sig := _inventory_signature(aggregated)
	if sig == _last_inventory_sig:
		return
	_last_inventory_sig = sig
	for c in _inventory_box.get_children():
		c.queue_free()
	for slot in aggregated:
		_inventory_box.add_child(_build_inventory_row(slot))


func _listings_signature(slots: Array) -> String:
	# 签名 = listing_id + qty + price 串接。任意货架字段变化都会让签名变。
	var parts: Array[String] = []
	for s in slots:
		var slot: Dictionary = s
		parts.append("%s:%d:%d" % [
			str(slot.get("_listing_id", "")),
			int(slot.get("quantity", 0)),
			int(slot.get("_listing_price_centi", 0)),
		])
	parts.sort()
	return ";".join(parts)


func _inventory_signature(slots: Array) -> String:
	var parts: Array[String] = []
	for s in slots:
		var slot: Dictionary = s
		parts.append("%s|%d|%d" % [
			str(slot.get("item_id", "")),
			int(slot.get("quality", 0)),
			int(slot.get("quantity", 0)),
		])
	parts.sort()
	return ";".join(parts)


# 每个 listing 一行 HBoxContainer：
# [InventorySlot 64x64] [name+qty+price (VBox)] [按钮区]
# InventorySlot 带 price overlay (_listing_price_centi 自动渲染)
func _build_listing_row(slot: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var icon := InventorySlot.new()
	icon.set_slot(0, slot)  # slot_index 在 listing 行里无意义，传 0
	row.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var view := InventorySlotData.of(slot)
	var name_label := Label.new()
	name_label.text = _format_item_label(view)
	name_label.add_theme_font_size_override("font_size", 14)
	info.add_child(name_label)

	var price_centi := int(slot.get("_listing_price_centi", 0))
	var price_label := Label.new()
	price_label.text = tr("ui.shelf.unit_price_format") % Money.format_silver_from_centi(price_centi)
	price_label.add_theme_font_size_override("font_size", 12)
	price_label.add_theme_color_override("font_color", Color(0.95, 0.9, 0.6, 1))
	info.add_child(price_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 4)
	row.add_child(buttons)

	var listing_id := str(slot.get("_listing_id", ""))
	var qty := int(slot.get("quantity", 0))
	var item_name := view.display_name()

	if _is_owner_mode:
		var reprice_btn := Button.new()
		reprice_btn.text = tr("ui.shelf.btn_reprice")
		reprice_btn.pressed.connect(_on_reprice_pressed.bind(item_name, price_centi))
		buttons.add_child(reprice_btn)

		var unlist_btn := Button.new()
		unlist_btn.text = tr("ui.shelf.btn_unlist")
		unlist_btn.pressed.connect(_on_unlist_pressed.bind(item_name, qty))
		buttons.add_child(unlist_btn)
	else:
		var buy_one := Button.new()
		buy_one.text = tr("ui.shelf.btn_buy_one")
		buy_one.disabled = qty <= 0
		buy_one.pressed.connect(_on_buy_pressed.bind(listing_id, 1))
		buttons.add_child(buy_one)

		var buy_all := Button.new()
		buy_all.text = tr("ui.shelf.btn_buy_all")
		buy_all.disabled = qty <= 1  # 只有 1 个时跟"买1"等价
		buy_all.pressed.connect(_on_buy_pressed.bind(listing_id, qty))
		buttons.add_child(buy_all)

	return row


# 玩家背包行（管理模式下显示「上架」按钮）。
func _build_inventory_row(slot: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var icon := InventorySlot.new()
	icon.set_slot(0, slot)
	row.add_child(icon)

	var view := InventorySlotData.of(slot)
	var name_label := Label.new()
	name_label.text = _format_item_label(view)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 14)
	row.add_child(name_label)

	if _is_owner_mode:
		var item_name := view.display_name()
		var max_qty := int(slot.get("quantity", 0))
		var list_btn := Button.new()
		list_btn.text = tr("ui.shelf.btn_list")
		list_btn.pressed.connect(_on_list_pressed.bind(item_name, max_qty))
		row.add_child(list_btn)

	return row


func _format_item_label(view: InventorySlotData) -> String:
	var name := view.display_name()
	var qty := view.quantity()
	var tier := QualityTier.display_name(view.quality())
	return "%s (%s) ×%d" % [name, tier, qty]


func _on_buy_pressed(listing_id: String, qty: int) -> void:
	if _player == null or _open_shelf == null:
		return
	if listing_id.is_empty() or qty <= 0:
		return
	if not _player.has_method("request_buy_from_shelf"):
		return
	var shelf_id := _shelf_id(_open_shelf)
	_player.request_buy_from_shelf.rpc_id(1, shelf_id, listing_id, qty)


# 上架弹窗：复用同一个 AcceptDialog，每次改 item_id/max。
func _on_list_pressed(item_name: String, max_qty: int) -> void:
	_ensure_list_popup()
	_list_popup_item_id = item_name
	_list_popup_item_label.text = tr("ui.shelf.popup_list_target") % item_name
	_list_popup_qty.max_value = max(max_qty, 1)
	_list_popup_qty.value = 1
	_list_popup_price.value = POPUP_PRICE_DEFAULT_SILVER
	_list_popup.popup_centered()


func _on_unlist_pressed(item_name: String, qty: int) -> void:
	if _player == null or _open_shelf == null:
		return
	if not _player.has_method("request_update_shelf"):
		return
	# update_shelf 的 remove op：qty <= 0 表示全下；这里显式传出货架上的总量。
	var ops := [{"type": "remove", "item": item_name, "quantity": qty}]
	_player.request_update_shelf.rpc_id(1, _shelf_id(_open_shelf), ops)


func _on_reprice_pressed(item_name: String, current_price_centi: int) -> void:
	_ensure_reprice_popup()
	_reprice_popup_item_id = item_name
	_reprice_popup_label.text = tr("ui.shelf.popup_reprice_target") % item_name
	_reprice_popup_price.value = max(current_price_centi, 0) / 100.0
	_reprice_popup.popup_centered()


func _ensure_list_popup() -> void:
	if _list_popup != null:
		return
	_list_popup = AcceptDialog.new()
	_list_popup.title = tr("ui.shelf.popup_list_title")
	_list_popup.dialog_hide_on_ok = true
	_list_popup.get_ok_button().text = tr("ui.shelf.popup_confirm")
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(280, 0)
	vbox.add_theme_constant_override("separation", 6)
	_list_popup.add_child(vbox)

	_list_popup_item_label = Label.new()
	vbox.add_child(_list_popup_item_label)

	var qty_row := HBoxContainer.new()
	qty_row.add_theme_constant_override("separation", 8)
	var qty_label := Label.new()
	qty_label.text = tr("ui.shelf.popup_qty")
	qty_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qty_row.add_child(qty_label)
	_list_popup_qty = SpinBox.new()
	_list_popup_qty.min_value = 1
	_list_popup_qty.max_value = 99
	_list_popup_qty.step = 1
	_list_popup_qty.value = 1
	_list_popup_qty.custom_minimum_size = Vector2(100, 0)
	qty_row.add_child(_list_popup_qty)
	vbox.add_child(qty_row)

	var price_row := HBoxContainer.new()
	price_row.add_theme_constant_override("separation", 8)
	var price_label := Label.new()
	price_label.text = tr("ui.shelf.popup_price")
	price_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_row.add_child(price_label)
	_list_popup_price = SpinBox.new()
	_list_popup_price.min_value = 0.0
	_list_popup_price.max_value = 999.99
	_list_popup_price.step = 0.25
	_list_popup_price.value = POPUP_PRICE_DEFAULT_SILVER
	_list_popup_price.custom_minimum_size = Vector2(100, 0)
	price_row.add_child(_list_popup_price)
	vbox.add_child(price_row)

	add_child(_list_popup)
	_list_popup.confirmed.connect(_on_list_popup_confirmed)


func _on_list_popup_confirmed() -> void:
	if _player == null or _open_shelf == null:
		return
	if not _player.has_method("request_update_shelf"):
		return
	var item_name := _list_popup_item_id
	var qty := int(_list_popup_qty.value)
	# UI silver float → centi int（按 0.01 银 = 1 centi）
	var price_centi := int(roundf(_list_popup_price.value * 100.0))
	if item_name.is_empty() or qty <= 0 or price_centi < 0:
		return
	var ops := [{"type": "add", "item": item_name, "quantity": qty, "price_centi": price_centi}]
	_player.request_update_shelf.rpc_id(1, _shelf_id(_open_shelf), ops)


func _ensure_reprice_popup() -> void:
	if _reprice_popup != null:
		return
	_reprice_popup = AcceptDialog.new()
	_reprice_popup.title = tr("ui.shelf.popup_reprice_title")
	_reprice_popup.dialog_hide_on_ok = true
	_reprice_popup.get_ok_button().text = tr("ui.shelf.popup_confirm")
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(280, 0)
	vbox.add_theme_constant_override("separation", 6)
	_reprice_popup.add_child(vbox)

	_reprice_popup_label = Label.new()
	vbox.add_child(_reprice_popup_label)

	var price_row := HBoxContainer.new()
	price_row.add_theme_constant_override("separation", 8)
	var price_label := Label.new()
	price_label.text = tr("ui.shelf.popup_price")
	price_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_row.add_child(price_label)
	_reprice_popup_price = SpinBox.new()
	_reprice_popup_price.min_value = 0.0
	_reprice_popup_price.max_value = 999.99
	_reprice_popup_price.step = 0.25
	_reprice_popup_price.value = POPUP_PRICE_DEFAULT_SILVER
	_reprice_popup_price.custom_minimum_size = Vector2(100, 0)
	price_row.add_child(_reprice_popup_price)
	vbox.add_child(price_row)

	add_child(_reprice_popup)
	_reprice_popup.confirmed.connect(_on_reprice_popup_confirmed)


func _on_reprice_popup_confirmed() -> void:
	if _player == null or _open_shelf == null:
		return
	if not _player.has_method("request_update_shelf"):
		return
	var item_name := _reprice_popup_item_id
	var price_centi := int(roundf(_reprice_popup_price.value * 100.0))
	if item_name.is_empty() or price_centi < 0:
		return
	# update op 需要 quantity——保留当前总量。用当前 listing slot qty 求和。
	var current_qty := _count_listings_for_item(item_name)
	if current_qty <= 0:
		return
	var ops := [{"type": "update", "item": item_name, "quantity": current_qty, "price_centi": price_centi}]
	_player.request_update_shelf.rpc_id(1, _shelf_id(_open_shelf), ops)


func _count_listings_for_item(item_name: String) -> int:
	if _open_shelf == null:
		return 0
	var total := 0
	for s in Shelves.adapter_listing_slots(_open_shelf):
		var slot: Dictionary = s
		var view := InventorySlotData.of(slot)
		if view.display_name() == item_name:
			total += int(slot.get("quantity", 0))
	return total


func _is_shelf(node: Node) -> bool:
	return node != null and node is ShelfNode


func _shelf_id(node: Node) -> String:
	if node != null and node.has_method("effective_shelf_id"):
		return str(node.effective_shelf_id())
	return ""


func _shelf_display_name(node: Node) -> String:
	if node != null and node.has_method("effective_display_name"):
		return str(node.effective_display_name())
	return tr("ui.shelf.title_default")
