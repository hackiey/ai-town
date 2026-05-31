class_name InventoryPanel
extends CanvasLayer

# 玩家 UI（client only）：
# - B 键开/关；ESC 关闭
# - 5x4 InventorySlot 背包网格
# - server 权威库存；右键菜单（使用 / 丢弃）和拖拽换位都通过 RPC 打到 server
# - 面板可见时浅比对 inventory 触发重绘；隐藏完全不工作
# - chat_bar 的 LineEdit 拿焦点时会吞掉 B 键，不会冲突

const COLS := 5
const ROWS := 4
const SLOT_COUNT := COLS * ROWS

const Money = preload("res://src/sim/characters/money.gd")

var _player: Node = null
var _last_snapshot: Array = []
var _last_wallet_centi: int = -1
var _slots: Array[InventorySlot] = []

@onready var _root: Control = $Root
@onready var _wallet_label: Label = $Root/Panel/Margin/VBox/Wallet
@onready var _grid: GridContainer = $Root/Panel/Margin/VBox/Grid


func _ready() -> void:
	_build_slots()


func set_player(player: Node) -> void:
	_player = player
	_last_snapshot.clear()
	_last_wallet_centi = -1
	if _root.visible:
		_refresh()


func toggle() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_B:
		toggle()
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and _root.visible:
		_root.visible = false
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not _root.visible or _player == null:
		return
	var current: Array = _player.inventory
	var wallet := int(_player.get("wallet_centi"))
	if wallet != _last_wallet_centi or not _same_inventory(current, _last_snapshot):
		_refresh()


func _build_slots() -> void:
	for child in _grid.get_children():
		child.queue_free()
	_slots.clear()
	for i in SLOT_COUNT:
		var slot := InventorySlot.new()
		_grid.add_child(slot)
		slot.use_requested.connect(_on_slot_use)
		slot.drop_requested.connect(_on_slot_drop)
		slot.swap_requested.connect(_on_slot_swap)
		_slots.append(slot)


func _refresh() -> void:
	if _player == null:
		for slot in _slots:
			slot.set_slot(slot.slot_index, {})
		_last_snapshot.clear()
		_last_wallet_centi = -1
		_wallet_label.text = tr("ui.inventory.wallet_format") % Money.format_silver_from_centi(0)
		return
	var inv: Array = _player.inventory
	_last_snapshot = inv.duplicate(true)
	_last_wallet_centi = int(_player.get("wallet_centi"))
	_wallet_label.text = tr("ui.inventory.wallet_format") % Money.format_silver_from_centi(_last_wallet_centi)
	for i in _slots.size():
		if i >= inv.size():
			_slots[i].set_slot(i, {})
			continue
		_slots[i].set_slot(i, inv[i])


# Snapshot 比对：item_id / quantity / quality 任一变化触发 refresh。Phase 2 新增字段
# (shape_type / materials / tags / properties) 一般跟着 item_id 变，这里不深比，避免每帧
# 跑 dict==dict 的开销；如果 modify 反应（无 item_id 变化只改 properties）需要刷新，
# 后续接 EventBus 信号驱动重绘即可。
func _same_inventory(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var sa: Dictionary = a[i]
		var sb: Dictionary = b[i]
		if str(sa.get("item_id", "")) != str(sb.get("item_id", "")):
			return false
		if int(sa.get("quantity", 0)) != int(sb.get("quantity", 0)):
			return false
		if int(sa.get("quality", 0)) != int(sb.get("quality", 0)):
			return false
	return true


func _on_slot_use(index: int) -> void:
	if _player == null or not _player.has_method("request_use_item"):
		return
	_player.request_use_item.rpc_id(1, index)


# 当前默认"丢弃整堆"。需要丢 1 个时另接入 shift+右键之类。
func _on_slot_drop(index: int) -> void:
	if _player == null or not _player.has_method("request_drop_item"):
		return
	var inv: Array = _player.inventory
	if index < 0 or index >= inv.size():
		return
	var qty := int((inv[index] as Dictionary).get("quantity", 0))
	if qty <= 0:
		return
	_player.request_drop_item.rpc_id(1, index, qty)


func _on_slot_swap(from_index: int, to_index: int) -> void:
	if _player == null or not _player.has_method("request_swap_slots"):
		return
	_player.request_swap_slots.rpc_id(1, from_index, to_index)
