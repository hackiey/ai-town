class_name ContainerPanel
extends CanvasLayer

# 玩家容器面板（client only）：
# - 由 ActionPanel 在容器型 workstation 上按 E 时调 open(workstation) 打开
# - 左：容器内容 / 右：玩家背包；两栏均显示 InventorySlot
# - 容器 slot 右键 → 取 1 / 取一整堆；背包 slot 右键 → 存 1 / 存一整堆
# - 实际转移由 server-authoritative RPC 完成（player.request_container_take/put）
# - 玩家走出容器范围或 ESC 关闭

const ROWS_CONTAINER := 4   # 容器格只显示前 N=ROWS_CONTAINER*COLS 槽（vault 有 999 槽，展示不全；放整页够看）
const COLS := 6
const TAKE_PER_CLICK := 1
const PUT_PER_CLICK := 1

var _player: Node = null
var _active_container: Node = null  # ContainerNode 进入 proximity 时记录
var _open_container: Node = null
var _container_slots: Array = []
var _player_slots: Array = []
var _last_container_snapshot: Array = []
var _last_player_snapshot: Array = []

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/Title
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
	EventBus.workstation_proximity_changed.connect(_on_proximity_changed)
	_close_btn.pressed.connect(close)


func set_player(player: Node) -> void:
	_player = player
	if _root.visible:
		_refresh()


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
	_build_container_slots()
	_build_player_slots()
	_refresh()
	_root.visible = true
	set_process(true)


func close() -> void:
	_root.visible = false
	_open_container = null
	set_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_E and _active_container != null and not _root.visible:
		# Group + lock 校验，避免无权限玩家硬开
		if _player != null and not _active_container.can_actually_use(_player):
			EventBus.notification_posted.emit(tr("ui.container.msg_no_access") % String(_active_container.display_name), "warn")
			get_viewport().set_input_as_handled()
			return
		open(_active_container)
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and _root.visible:
		close()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _root.visible:
		_refresh()


func _build_container_slots() -> void:
	for c in _container_grid.get_children():
		c.queue_free()
	_container_slots.clear()
	var capacity := COLS * ROWS_CONTAINER
	for i in capacity:
		var slot := InventorySlot.new()
		_container_grid.add_child(slot)
		# 右键 use → 取一份；drop → 取一整堆。重用 InventorySlot menu 信号语义。
		slot.use_requested.connect(_on_container_take_one.bind(i))
		slot.drop_requested.connect(_on_container_take_all.bind(i))
		_container_slots.append(slot)


func _build_player_slots() -> void:
	for c in _player_grid.get_children():
		c.queue_free()
	_player_slots.clear()
	var inv: Array = _player.inventory if _player != null else []
	for i in inv.size():
		var slot := InventorySlot.new()
		_player_grid.add_child(slot)
		slot.use_requested.connect(_on_player_put_one.bind(i))
		slot.drop_requested.connect(_on_player_put_all.bind(i))
		_player_slots.append(slot)


func _refresh() -> void:
	if _open_container == null or _player == null:
		return
	# 容器内容：从 Containers autoload 拿持久化 slots（server + client 同步同源）。
	var slots: Array = Containers.adapter_slots(_open_container)
	for i in _container_slots.size():
		var data: Dictionary = slots[i] if i < slots.size() else {}
		_container_slots[i].set_slot(i, data)
	_last_container_snapshot = slots.duplicate(true)
	# 玩家背包
	var inv: Array = _player.inventory
	if inv.size() != _player_slots.size():
		_build_player_slots()
	for i in _player_slots.size():
		_player_slots[i].set_slot(i, inv[i] if i < inv.size() else {})
	_last_player_snapshot = inv.duplicate(true)


func _on_container_take_one(slot_index: int) -> void:
	_request_take(slot_index, TAKE_PER_CLICK)


func _on_container_take_all(slot_index: int) -> void:
	var slots: Array = Containers.adapter_slots(_open_container)
	if slot_index < 0 or slot_index >= slots.size():
		return
	var qty := int((slots[slot_index] as Dictionary).get("quantity", 0))
	if qty <= 0:
		return
	_request_take(slot_index, qty)


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
	var cid: String = _open_container.effective_container_id() if _open_container.has_method("effective_container_id") else String(_open_container.workstation_id)
	_player.request_container_take.rpc_id(1, cid, container_slot_index, qty)


func _request_put(player_slot_index: int, qty: int) -> void:
	if _player == null or _open_container == null:
		return
	if not _player.has_method("request_container_put"):
		return
	var cid: String = _open_container.effective_container_id() if _open_container.has_method("effective_container_id") else String(_open_container.workstation_id)
	_player.request_container_put.rpc_id(1, cid, player_slot_index, qty)


func _is_container(workstation: Node) -> bool:
	if workstation == null:
		return false
	if workstation.is_in_group("containers"):
		return true
	# 兼容尚未加入 containers 组的旧实例
	return workstation is ContainerNode
