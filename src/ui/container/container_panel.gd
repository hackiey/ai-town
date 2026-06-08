class_name ContainerPanel
extends CanvasLayer

# 玩家容器面板（client only）：
# - 由 ActionPanel 在容器型 workstation 上按 E 时调 open(workstation) 打开
# - 左：容器内容 / 右：玩家背包；两栏均显示 InventorySlot
# - 容器 slot 右键 → 取 1 / 取一整堆；背包 slot 右键 → 存 1 / 存一整堆
# - 实际转移由 server-authoritative RPC 完成（player.request_container_take/put）
# - 玩家走出容器范围或 ESC 关闭

const ROWS_CONTAINER := 4   # 容器格每页显示 N=ROWS_CONTAINER*COLS 槽，超出走分页
const COLS := 6
const TAKE_PER_CLICK := 1
const PUT_PER_CLICK := 1
const PAGE_SIZE := ROWS_CONTAINER * COLS   # 每页槽数 = 24

var _player: Node = null
var _split_panel: Node = null  # SplitPanel; 右键"倒出液体"/"存入 N"/"取出 N"时打开
var _brew_panel: Node = null  # BrewPanel; 右键"酿酒…"时打开
var _active_container: Node = null  # ContainerNode 进入 proximity 时记录
var _open_container: Node = null
var _container_slots: Array = []
var _player_slots: Array = []
var _last_player_snapshot: Array = []
var _page: int = 0   # 当前查看页（0-based）
# 分页导航控件（程序化创建，挂在容器列底部）
var _nav_prev: Button = null
var _nav_next: Button = null
var _nav_label: Label = null
var _nav_row: HBoxContainer = null
var _wallet_label: Label = null
var _wallet_put_btn: Button = null
var _wallet_take_btn: Button = null
var _wallet_row: HBoxContainer = null
var _shelf_scroll: ScrollContainer = null
var _shelf_rows: VBoxContainer = null
var _shelf_empty_label: Label = null
var _shelf_row_controls: Array[Dictionary] = []
var _last_shelf_signature: String = ""
var _container_hint_text: String = ""

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/Title
@onready var _container_col: VBoxContainer = $Root/Panel/Margin/VBox/HBox/ContainerCol
@onready var _container_grid: GridContainer = $Root/Panel/Margin/VBox/HBox/ContainerCol/Grid
@onready var _player_col: VBoxContainer = $Root/Panel/Margin/VBox/HBox/PlayerCol
@onready var _player_grid: GridContainer = $Root/Panel/Margin/VBox/HBox/PlayerCol/Grid
@onready var _container_label: Label = $Root/Panel/Margin/VBox/HBox/ContainerCol/Label
@onready var _player_label: Label = $Root/Panel/Margin/VBox/HBox/PlayerCol/Label
@onready var _close_btn: Button = $Root/Panel/Margin/VBox/Footer/Close
@onready var _hint: Label = $Root/Panel/Margin/VBox/Footer/Hint


func _ready() -> void:
	_root.visible = false
	_container_hint_text = _hint.text
	_container_grid.columns = COLS
	_player_grid.columns = 5
	_build_wallet_controls()
	_build_nav()
	_build_shelf_list()
	EventBus.workstation_proximity_changed.connect(_on_proximity_changed)
	_close_btn.pressed.connect(close)


func _build_wallet_controls() -> void:
	_wallet_row = HBoxContainer.new()
	_wallet_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_wallet_row.add_theme_constant_override("separation", 8)
	_wallet_label = Label.new()
	_wallet_label.custom_minimum_size = Vector2(180, 0)
	_wallet_row.add_child(_wallet_label)
	_wallet_put_btn = Button.new()
	_wallet_put_btn.text = tr("ui.container.wallet_put")
	_wallet_put_btn.pressed.connect(_on_wallet_put)
	_wallet_row.add_child(_wallet_put_btn)
	_wallet_take_btn = Button.new()
	_wallet_take_btn.text = tr("ui.container.wallet_take")
	_wallet_take_btn.pressed.connect(_on_wallet_take)
	_wallet_row.add_child(_wallet_take_btn)
	_container_col.add_child(_wallet_row)


# 容器列底部的分页导航：[‹ 上一页] 第 X/Y 页 [下一页 ›]，只在多页时显示。
func _build_nav() -> void:
	_nav_row = HBoxContainer.new()
	_nav_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_nav_row.add_theme_constant_override("separation", 8)
	_nav_prev = Button.new()
	_nav_prev.text = tr("ui.container.page_prev")
	_nav_prev.pressed.connect(_on_prev_page)
	_nav_row.add_child(_nav_prev)
	_nav_label = Label.new()
	_nav_row.add_child(_nav_label)
	_nav_next = Button.new()
	_nav_next.text = tr("ui.container.page_next")
	_nav_next.pressed.connect(_on_next_page)
	_nav_row.add_child(_nav_next)
	_nav_row.visible = false
	_container_col.add_child(_nav_row)


func _build_shelf_list() -> void:
	_shelf_scroll = ScrollContainer.new()
	_shelf_scroll.visible = false
	_shelf_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_shelf_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shelf_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shelf_scroll.custom_minimum_size = Vector2(520, 320)

	var wrapper := VBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("separation", 8)
	_shelf_scroll.add_child(wrapper)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	wrapper.add_child(header)

	var item_header := Label.new()
	item_header.text = tr("ui.shelf.col_item")
	item_header.custom_minimum_size = Vector2(260, 0)
	item_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(item_header)

	var price_header := Label.new()
	price_header.text = tr("ui.shelf.col_unit_price")
	price_header.custom_minimum_size = Vector2(120, 0)
	header.add_child(price_header)

	var qty_header := Label.new()
	qty_header.text = tr("ui.shelf.col_quantity")
	qty_header.custom_minimum_size = Vector2(96, 0)
	header.add_child(qty_header)

	var action_header := Label.new()
	action_header.custom_minimum_size = Vector2(96, 0)
	header.add_child(action_header)

	_shelf_rows = VBoxContainer.new()
	_shelf_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shelf_rows.add_theme_constant_override("separation", 6)
	wrapper.add_child(_shelf_rows)

	_shelf_empty_label = Label.new()
	_shelf_empty_label.text = tr("ui.shelf.msg_empty")
	_shelf_empty_label.visible = false
	wrapper.add_child(_shelf_empty_label)

	_container_col.add_child(_shelf_scroll)
	_container_col.move_child(_shelf_scroll, 1)


func set_player(player: Node) -> void:
	_player = player
	if _root.visible:
		_refresh()


func set_split_panel(panel: Node) -> void:
	_split_panel = panel


func set_brew_panel(panel: Node) -> void:
	_brew_panel = panel


func _on_proximity_changed(workstation: Node, entered: bool) -> void:
	if not _is_container(workstation):
		return
	if entered:
		_active_container = workstation
	else:
		if workstation == _active_container:
			_active_container = null
		if workstation == _open_container and _root.visible:
			close()


# ActionPanel 在 mode == "container" 时调本方法替代 ActionPanel.open。
func open(workstation: Node) -> void:
	if not _is_container(workstation):
		push_warning("[ContainerPanel] open() called with non-container: %s" % workstation)
		return
	_open_container = workstation
	_title.text = String(workstation.effective_display_name()) if workstation.has_method("effective_display_name") else String(workstation.display_name)
	_container_label.text = tr("ui.shelf.label_listings") if _is_shelf_open() else tr("ui.container.label_storage")
	_player_label.text = tr("ui.container.label_backpack")
	_page = 0
	_last_shelf_signature = ""
	_shelf_row_controls.clear()
	_apply_content_mode()
	if not _is_shelf_open():
		_build_container_slots()
		_build_player_slots()
	_request_view()
	_refresh()
	_root.visible = true
	set_process(true)


func close() -> void:
	_root.visible = false
	# 通知 server 停止为本玩家算容器页（清空 view）。
	if _player != null and _open_container != null and _player.has_method("request_view"):
		_player.request_view.rpc_id(1, "", "", 0, PAGE_SIZE)
	_open_container = null
	set_process(false)


# 向 server 报「正在看容器 X 第 _page 页」；页数据经 Player.view_slots 同步回来。
func _request_view() -> void:
	if _player == null or _open_container == null:
		return
	if not _player.has_method("request_view"):
		return
	_player.request_view.rpc_id(1, "container", _container_id(), _page, PAGE_SIZE)


func _on_prev_page() -> void:
	if _page <= 0:
		return
	_page -= 1
	if _is_shelf_open():
		_last_shelf_signature = ""
	else:
		_build_container_slots()
	_request_view()


func _on_next_page() -> void:
	var count := int(_player.view_page_count) if _player != null and "view_page_count" in _player else 1
	if _page >= count - 1:
		return
	_page += 1
	if _is_shelf_open():
		_last_shelf_signature = ""
	else:
		_build_container_slots()
	_request_view()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	# E 路由统一由 InteractionController 处理；这里只管 ESC 关闭。
	if key.physical_keycode == KEY_ESCAPE and _root.visible:
		close()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _root.visible


func accepts_backpack_put() -> bool:
	return _root.visible and not _is_shelf_open()


func _process(_delta: float) -> void:
	if _root.visible:
		_refresh()


func _container_id() -> String:
	if _open_container == null:
		return ""
	if _open_container.has_method("effective_container_id"):
		return String(_open_container.effective_container_id())
	return String(_open_container.workstation_id)


func _build_container_slots() -> void:
	for c in _container_grid.get_children():
		c.queue_free()
	_container_slots.clear()
	# 只建本页实际有的格子数（按容器 slot_count），不再固定 24 格——3 格的酒桶就显示 3 格。
	var total := _container_total_slots()
	var on_page := clampi(total - _page * PAGE_SIZE, 0, PAGE_SIZE)
	for i in on_page:
		var slot := InventorySlot.new()
		_container_grid.add_child(slot)
		# 右键菜单：取出 1 / 取出整堆。信号自带 slot_index（=网格位），不要再 .bind() 否则多传一参报错。
		slot.set_menu_labels(tr("ui.container.menu.take_one"), tr("ui.container.menu.take_all"))
		slot.set_transfer_label(tr("ui.container.menu.take_n"))   # 取出 N…（分离面板选份数）
		slot.show_pour = true   # 装着液体的容器物会多出"倒出液体…"
		slot.show_brew = true   # 装水的酿酒桶会多出"酿酒…"
		slot.use_requested.connect(_on_container_take_one)
		slot.drop_requested.connect(_on_container_take_all)
		slot.transfer_requested.connect(_on_container_take_n)
		slot.pour_requested.connect(_on_container_pour)
		slot.brew_requested.connect(_on_container_brew)
		_container_slots.append(slot)


func _container_total_slots() -> int:
	if _open_container != null and _open_container.get("slot_count") != null:
		return int(_open_container.slot_count)
	return COLS * ROWS_CONTAINER


func _build_player_slots() -> void:
	for c in _player_grid.get_children():
		c.queue_free()
	_player_slots.clear()
	var inv: Array = _player.inventory if _player != null else []
	for i in inv.size():
		var slot := InventorySlot.new()
		_player_grid.add_child(slot)
		# 右键菜单：存入 1 / 存入整堆。信号自带 slot_index，不要 .bind()。
		slot.set_menu_labels(tr("ui.container.menu.put_one"), tr("ui.container.menu.put_all"))
		slot.set_transfer_label(tr("ui.container.menu.put_n"))   # 存入 N…（分离面板选份数）
		slot.show_pour = true
		slot.show_brew = true
		slot.use_requested.connect(_on_player_put_one)
		slot.drop_requested.connect(_on_player_put_all)
		slot.transfer_requested.connect(_on_player_put_n)
		slot.pour_requested.connect(_on_player_pour)
		slot.brew_requested.connect(_on_player_brew)
		_player_slots.append(slot)


func _refresh() -> void:
	if _open_container == null or _player == null:
		return
	# 容器内容：读 Player.view_slots（owner-private 同步的「当前页」；server 切片权威 contents）。
	# 仅当 server 确认在看本容器时才用，否则当空（避免渲染上一个目标的残留页）。
	var slots: Array = _view_slots_for_open_container()
	if _is_shelf_open():
		_refresh_shelf_rows(slots)
		_refresh_nav()
		return
	for i in _container_slots.size():
		var data: Dictionary = slots[i] if i < slots.size() else {}
		_container_slots[i].set_slot(i, data)
	_refresh_wallet_controls()
	_refresh_nav()
	# 玩家背包
	var inv: Array = _player.inventory
	if inv.size() != _player_slots.size():
		_build_player_slots()
	for i in _player_slots.size():
		_player_slots[i].set_slot(i, inv[i] if i < inv.size() else {})
	_last_player_snapshot = inv.duplicate(true)


func _refresh_wallet_controls() -> void:
	if _wallet_label == null or _player == null:
		return
	var container_wallet := int(_player.view_wallet_centi) if "view_wallet_centi" in _player else 0
	var player_wallet := int(_player.wallet_centi) if "wallet_centi" in _player else 0
	_wallet_label.text = tr("ui.container.wallet_format") % Money.format_silver_from_centi(container_wallet)
	_wallet_put_btn.disabled = player_wallet <= 0
	_wallet_take_btn.disabled = container_wallet <= 0


# 当前页的容器槽——只有 server 确认在看本容器（kind/target 匹配）才返回，否则空。
func _view_slots_for_open_container() -> Array:
	if _player == null or not ("view_kind" in _player):
		return []
	if str(_player.view_kind) != "container":
		return []
	if str(_player.view_target_id) != _container_id():
		return []
	if "view_page" in _player and int(_player.view_page) != _page:
		return []
	return _player.view_slots


func _refresh_shelf_rows(slots: Array) -> void:
	if _shelf_rows == null:
		return
	var signature := _shelf_signature(slots)
	if signature != _last_shelf_signature:
		_last_shelf_signature = signature
		for c in _shelf_rows.get_children():
			c.queue_free()
		_shelf_row_controls.clear()
		var has_items := false
		for i in slots.size():
			if not (slots[i] is Dictionary):
				continue
			var data: Dictionary = slots[i]
			var view := InventorySlotData.of(data)
			if view.is_empty():
				continue
			has_items = true
			_shelf_rows.add_child(_build_shelf_row(_page * PAGE_SIZE + i, data, view))
		_shelf_empty_label.visible = not has_items
	_update_shelf_buy_states()


func _shelf_signature(slots: Array) -> String:
	var parts: Array[String] = ["page:%d" % _page]
	for i in slots.size():
		if not (slots[i] is Dictionary):
			continue
		var data: Dictionary = slots[i]
		var view := InventorySlotData.of(data)
		if view.is_empty():
			continue
		parts.append("%d:%s:%d:%d:%s:%d" % [
			_page * PAGE_SIZE + i,
			view.id(),
			view.quantity(),
			view.quality(),
			view.shape_type(),
			_slot_price_centi(data),
		])
	return "|".join(parts)


func _build_shelf_row(container_slot_index: int, data: Dictionary, view: InventorySlotData) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)

	var item_label := Label.new()
	item_label.custom_minimum_size = Vector2(260, 0)
	item_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_label.text = "%s x%d" % [view.display_name(), view.quantity()]
	item_label.tooltip_text = ItemTooltipFormatter.format(view, view.template(), view.display_name())
	row.add_child(item_label)

	var price_label := Label.new()
	price_label.custom_minimum_size = Vector2(120, 0)
	price_label.text = Money.format_silver_from_centi(_slot_price_centi(data))
	row.add_child(price_label)

	var spin := SpinBox.new()
	spin.min_value = 1.0
	spin.max_value = maxi(1, view.quantity())
	spin.step = 1.0
	spin.value = 1.0
	spin.custom_minimum_size = Vector2(96, 0)
	row.add_child(spin)

	var buy_btn := Button.new()
	buy_btn.text = tr("ui.shelf.btn_buy")
	buy_btn.custom_minimum_size = Vector2(96, 0)
	buy_btn.pressed.connect(func() -> void: _on_shelf_buy(container_slot_index, spin))
	row.add_child(buy_btn)

	_shelf_row_controls.append({
		"available": view.quantity(),
		"button": buy_btn,
		"price": _slot_price_centi(data),
		"spin": spin,
	})
	return row


func _update_shelf_buy_states() -> void:
	if _player == null:
		return
	var wallet := int(_player.wallet_centi) if "wallet_centi" in _player else 0
	for row_v in _shelf_row_controls:
		var spin := row_v.get("spin", null) as SpinBox
		var buy_btn := row_v.get("button", null) as Button
		if spin == null or buy_btn == null:
			continue
		var available := int(row_v.get("available", 0))
		var price := int(row_v.get("price", 0))
		var max_buy := available
		if price > 0:
			max_buy = mini(available, int(floor(float(wallet) / float(price))))
		var can_buy := available > 0 and max_buy > 0
		spin.editable = can_buy
		spin.max_value = maxf(1.0, float(max_buy))
		if can_buy and int(spin.value) > max_buy:
			spin.value = max_buy
		elif not can_buy:
			spin.value = 1.0
		buy_btn.disabled = not can_buy


func _on_shelf_buy(container_slot_index: int, spin: SpinBox) -> void:
	if spin == null:
		return
	_request_take(container_slot_index, int(spin.value))


func _slot_price_centi(data: Dictionary) -> int:
	var price_v: Variant = data.get("listing_price_centi", null)
	if price_v == null:
		return 0
	return maxi(0, int(price_v))


func _refresh_nav() -> void:
	if _nav_label == null:
		return
	var count := int(_player.view_page_count) if "view_page_count" in _player else 1
	_nav_row.visible = count > 1
	if count <= 1:
		return
	_nav_label.text = tr("ui.container.page_indicator") % [_page + 1, count]
	_nav_prev.disabled = _page <= 0
	_nav_next.disabled = _page >= count - 1


# grid_i 是网格里第 i 格（0..23）；真实容器 slot_index = _page*PAGE_SIZE + grid_i。
func _on_container_take_one(grid_i: int) -> void:
	_request_take(_page * PAGE_SIZE + grid_i, TAKE_PER_CLICK)


func _on_container_take_all(grid_i: int) -> void:
	var slots: Array = _view_slots_for_open_container()
	if grid_i < 0 or grid_i >= slots.size():
		return
	var qty := int((slots[grid_i] as Dictionary).get("quantity", 0))
	if qty <= 0:
		return
	_request_take(_page * PAGE_SIZE + grid_i, qty)


# 取出 N…：分离面板（单量模式）选份数后逐量取出。
func _on_container_take_n(grid_i: int) -> void:
	if _split_panel == null:
		return
	var slots: Array = _view_slots_for_open_container()
	if grid_i < 0 or grid_i >= slots.size():
		return
	var data: Dictionary = slots[grid_i]
	var qty := int(data.get("quantity", 0))
	if qty <= 0:
		return
	var idx := _page * PAGE_SIZE + grid_i
	_split_panel.open({
		"unit": "count",
		"need_target": false,
		"title": tr("ui.split.take_title") % InventorySlotData.of(data).display_name(),
		"max": qty,
		"on_confirm": func(n: int) -> void: _request_take(idx, n),
	})


func _on_player_put_one(slot_index: int) -> void:
	_request_put(slot_index, PUT_PER_CLICK)


# 背包上下文菜单"存入仓库…"：InventoryPanel 委托调用，复用存入 N 逻辑。
func begin_put_split(slot_index: int) -> void:
	if _is_shelf_open():
		return
	_on_player_put_n(slot_index)


# 存入 N…：分离面板（单量模式）选份数后存入容器。
func _on_player_put_n(slot_index: int) -> void:
	if _split_panel == null or _player == null:
		return
	var inv: Array = _player.inventory
	if slot_index < 0 or slot_index >= inv.size():
		return
	var data: Dictionary = inv[slot_index]
	var qty := int(data.get("quantity", 0))
	if qty <= 0:
		return
	_split_panel.open({
		"unit": "count",
		"need_target": false,
		"title": tr("ui.split.put_title") % InventorySlotData.of(data).display_name(),
		"max": qty,
		"on_confirm": func(n: int) -> void: _request_put(slot_index, n),
	})


func _on_player_put_all(slot_index: int) -> void:
	if _player == null:
		return
	var inv: Array = _player.inventory
	if slot_index < 0 or slot_index >= inv.size():
		return
	var qty := int((inv[slot_index] as Dictionary).get("quantity", 0))
	if qty <= 0:
		return
	_request_put(slot_index, qty)


func _request_take(container_slot_index: int, qty: int) -> void:
	if _player == null or _open_container == null:
		return
	if not _player.has_method("request_container_take"):
		return
	_player.request_container_take.rpc_id(1, _container_id(), container_slot_index, qty)


func _request_put(player_slot_index: int, qty: int) -> void:
	if _player == null or _open_container == null:
		return
	if not _player.has_method("request_container_put"):
		return
	_player.request_container_put.rpc_id(1, _container_id(), player_slot_index, qty)


func _on_wallet_put() -> void:
	if _split_panel == null or _player == null:
		return
	var max_centi := int(_player.wallet_centi) if "wallet_centi" in _player else 0
	if max_centi <= 0:
		return
	_split_panel.open({
		"unit": "centi",
		"need_target": false,
		"title": tr("ui.container.wallet_put_title"),
		"max": max_centi,
		"on_confirm": func(n: int) -> void: _request_wallet_transfer("put", n),
	})


func _on_wallet_take() -> void:
	if _split_panel == null or _player == null:
		return
	var max_centi := int(_player.view_wallet_centi) if "view_wallet_centi" in _player else 0
	if max_centi <= 0:
		return
	_split_panel.open({
		"unit": "centi",
		"need_target": false,
		"title": tr("ui.container.wallet_take_title"),
		"max": max_centi,
		"on_confirm": func(n: int) -> void: _request_wallet_transfer("take", n),
	})


func _request_wallet_transfer(direction: String, centi: int) -> void:
	if _player == null or _open_container == null:
		return
	if not _player.has_method("request_container_wallet_transfer"):
		return
	_player.request_container_wallet_transfer.rpc_id(1, _container_id(), direction, centi)


# ── 倒液体：右键容器物→"倒出液体…" 打开 SplitPanel(目标列表模式)（源=该容器物，目标=背包液体容器）──
func _on_container_pour(grid_i: int) -> void:
	var slots: Array = _view_slots_for_open_container()
	if grid_i < 0 or grid_i >= slots.size():
		return
	_open_pour_from(_container_id(), _page * PAGE_SIZE + grid_i, slots[grid_i])


func _on_player_pour(slot_index: int) -> void:
	if _player == null:
		return
	var inv: Array = _player.inventory
	if slot_index < 0 or slot_index >= inv.size():
		return
	_open_pour_from("", slot_index, inv[slot_index])


func _open_pour_from(cid: String, slot_index: int, data: Dictionary) -> void:
	if _split_panel == null:
		return
	var view := InventorySlotData.of(data)
	var cont := view.as_container()
	if cont == null or cont.is_empty():
		return
	var content := cont.content_id()
	# 源在背包时排除自身槽，避免倒回自己。源在容器节点（cid 非空）时背包无此槽，不排除。
	var exclude := slot_index if cid == "" else -1
	_split_panel.open({
		"unit": "liter",
		"need_target": true,
		"title": tr("ui.liquid_pour.title_format") % [view.display_name(), _content_name(content)],
		"content": content,
		"quality": int(cont.quality()),
		"max": int(floor(cont.amount())),
		"exclude_slot": exclude,
		"on_confirm": func(dst: int, amt: int) -> void:
			_player.request_pour_liquid.rpc_id(1, cid, slot_index, "", dst, float(amt)),
	})


func _content_name(content: String) -> String:
	var key := "item.%s.name" % content
	var n := tr(key)
	if n != key:
		return n
	var mat: Substance = Materials.by_id(content)
	return mat.display_name if mat != null and not mat.display_name.is_empty() else content


# ── 酿酒：右键装水的酿酒桶→"酿酒…" 打开 BrewPanel（桶=源，列出可酿的酒）──
func _on_container_brew(grid_i: int) -> void:
	var slots: Array = _view_slots_for_open_container()
	if grid_i < 0 or grid_i >= slots.size():
		return
	_open_brew_from(_container_id(), _page * PAGE_SIZE + grid_i, slots[grid_i])


func _on_player_brew(slot_index: int) -> void:
	if _player == null:
		return
	var inv: Array = _player.inventory
	if slot_index < 0 or slot_index >= inv.size():
		return
	_open_brew_from("", slot_index, inv[slot_index])


func _open_brew_from(cid: String, slot_index: int, data: Dictionary) -> void:
	if _brew_panel == null:
		return
	var view := InventorySlotData.of(data)
	var cont := view.as_container()
	if cont == null or cont.is_empty():
		return
	_brew_panel.open({
		"container_id": cid,
		"slot_index": slot_index,
		"liters": cont.amount(),
		"label": view.display_name(),
	})


func _apply_content_mode() -> void:
	var shelf_mode := _is_shelf_open()
	_container_grid.visible = not shelf_mode
	_player_col.visible = not shelf_mode
	if _shelf_scroll != null:
		_shelf_scroll.visible = shelf_mode
	if _wallet_row != null:
		_wallet_row.visible = not shelf_mode
	_hint.text = tr("ui.shelf.hint_buy") if shelf_mode else _container_hint_text


func _is_shelf_open() -> bool:
	return _is_shelf_node(_open_container)


func _is_shelf_node(node: Node) -> bool:
	if node == null:
		return false
	return node is ShelfNode or node.is_in_group("shelves")


func _is_container(workstation: Node) -> bool:
	if workstation == null:
		return false
	if workstation.is_in_group("containers"):
		return true
	# 兼容尚未加入 containers 组的旧实例
	return workstation is ContainerNode
