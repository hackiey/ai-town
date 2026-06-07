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
var _pour_panel: Node = null  # LiquidPourPanel; 右键"倒出液体"时打开
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

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/Title
@onready var _container_col: VBoxContainer = $Root/Panel/Margin/VBox/HBox/ContainerCol
@onready var _container_grid: GridContainer = $Root/Panel/Margin/VBox/HBox/ContainerCol/Grid
@onready var _player_grid: GridContainer = $Root/Panel/Margin/VBox/HBox/PlayerCol/Grid
@onready var _container_label: Label = $Root/Panel/Margin/VBox/HBox/ContainerCol/Label
@onready var _player_label: Label = $Root/Panel/Margin/VBox/HBox/PlayerCol/Label
@onready var _close_btn: Button = $Root/Panel/Margin/VBox/Footer/Close
@onready var _hint: Label = $Root/Panel/Margin/VBox/Footer/Hint


func _ready() -> void:
	_root.visible = false
	_container_grid.columns = COLS
	_player_grid.columns = 5
	_build_nav()
	EventBus.workstation_proximity_changed.connect(_on_proximity_changed)
	_close_btn.pressed.connect(close)


# 容器列底部的分页导航：[‹ 上一页] 第 X/Y 页 [下一页 ›]，只在多页时显示。
func _build_nav() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	_nav_prev = Button.new()
	_nav_prev.text = tr("ui.container.page_prev")
	_nav_prev.pressed.connect(_on_prev_page)
	row.add_child(_nav_prev)
	_nav_label = Label.new()
	row.add_child(_nav_label)
	_nav_next = Button.new()
	_nav_next.text = tr("ui.container.page_next")
	_nav_next.pressed.connect(_on_next_page)
	row.add_child(_nav_next)
	row.visible = false
	_container_col.add_child(row)


func set_player(player: Node) -> void:
	_player = player
	if _root.visible:
		_refresh()


func set_pour_panel(panel: Node) -> void:
	_pour_panel = panel


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
	_title.text = String(workstation.display_name)
	_container_label.text = tr("ui.container.label_storage")
	_player_label.text = tr("ui.container.label_backpack")
	_page = 0
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
	_build_container_slots()
	_request_view()


func _on_next_page() -> void:
	var count := int(_player.view_page_count) if _player != null and "view_page_count" in _player else 1
	if _page >= count - 1:
		return
	_page += 1
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
		slot.show_pour = true   # 装着液体的容器物会多出"倒出液体…"
		slot.show_brew = true   # 装水的酿酒桶会多出"酿酒…"
		slot.use_requested.connect(_on_container_take_one)
		slot.drop_requested.connect(_on_container_take_all)
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
		slot.show_pour = true
		slot.show_brew = true
		slot.use_requested.connect(_on_player_put_one)
		slot.drop_requested.connect(_on_player_put_all)
		slot.pour_requested.connect(_on_player_pour)
		slot.brew_requested.connect(_on_player_brew)
		_player_slots.append(slot)


func _refresh() -> void:
	if _open_container == null or _player == null:
		return
	# 容器内容：读 Player.view_slots（owner-private 同步的「当前页」；server 切片权威 contents）。
	# 仅当 server 确认在看本容器时才用，否则当空（避免渲染上一个目标的残留页）。
	var slots: Array = _view_slots_for_open_container()
	for i in _container_slots.size():
		var data: Dictionary = slots[i] if i < slots.size() else {}
		_container_slots[i].set_slot(i, data)
	_refresh_nav()
	# 玩家背包
	var inv: Array = _player.inventory
	if inv.size() != _player_slots.size():
		_build_player_slots()
	for i in _player_slots.size():
		_player_slots[i].set_slot(i, inv[i] if i < inv.size() else {})
	_last_player_snapshot = inv.duplicate(true)


# 当前页的容器槽——只有 server 确认在看本容器（kind/target 匹配）才返回，否则空。
func _view_slots_for_open_container() -> Array:
	if _player == null or not ("view_kind" in _player):
		return []
	if str(_player.view_kind) != "container":
		return []
	if str(_player.view_target_id) != _container_id():
		return []
	return _player.view_slots


func _refresh_nav() -> void:
	if _nav_label == null:
		return
	var count := int(_player.view_page_count) if "view_page_count" in _player else 1
	var nav_row: Node = _nav_label.get_parent()
	nav_row.visible = count > 1
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


func _on_player_put_one(slot_index: int) -> void:
	_request_put(slot_index, PUT_PER_CLICK)


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


# ── 倒液体：右键容器物→"倒出液体…" 打开 LiquidPourPanel（源=该容器物，目标=背包液体容器）──
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
	if _pour_panel == null:
		return
	var view := InventorySlotData.of(data)
	var cont := view.as_container()
	if cont == null or cont.is_empty():
		return
	_pour_panel.open({
		"container_id": cid,
		"slot_index": slot_index,
		"content": cont.content_id(),
		"quality": int(cont.quality()),
		"amount": cont.amount(),
		"label": view.display_name(),
	})


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


func _is_container(workstation: Node) -> bool:
	if workstation == null:
		return false
	if workstation.is_in_group("containers"):
		return true
	# 兼容尚未加入 containers 组的旧实例
	return workstation is ContainerNode
