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
var _last_carry_weight: float = -1.0
var _last_max_carry_weight: float = -1.0
var _slots: Array[InventorySlot] = []
# 上下文转移：灶台/仓库面板打开时，背包格右键多一项"放入灶台…/存入仓库…"，委托给对应面板开分离面板。
var _action_panel: Node = null
var _container_panel: Node = null
var _last_transfer_label: String = ""

@onready var _root: Control = $Root
@onready var _wallet_label: Label = $Root/Panel/Margin/VBox/Wallet
@onready var _backpack_title: Label = $Root/Panel/Margin/VBox/BackpackTitle
@onready var _grid: GridContainer = $Root/Panel/Margin/VBox/Grid


func _ready() -> void:
	_build_slots()


func set_player(player: Node) -> void:
	_player = player
	_last_snapshot.clear()
	_last_wallet_centi = -1
	_last_carry_weight = -1.0
	_last_max_carry_weight = -1.0
	if _root.visible:
		_refresh()


# town.gd 注入：背包格上下文转移要委托给当前打开的灶台/仓库面板。
func set_transfer_panels(action_panel: Node, container_panel: Node) -> void:
	_action_panel = action_panel
	_container_panel = container_panel


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
	_update_transfer_labels()
	var current: Array = _player.inventory
	var wallet := int(_player.get("wallet_centi"))
	var carry := float(_player.get("carry_weight"))
	var max_carry := float(_player.get("max_carry_weight"))
	if wallet != _last_wallet_centi \
			or absf(carry - _last_carry_weight) > 0.001 \
			or absf(max_carry - _last_max_carry_weight) > 0.001 \
			or not _same_inventory(current, _last_snapshot):
		_refresh()


# 按当前打开的面板给每个背包格设置上下文转移项文案；无面板打开则隐藏该项。
func _update_transfer_labels() -> void:
	var label := ""
	if _action_panel != null and _action_panel.has_method("is_open") and _action_panel.is_open():
		label = tr("ui.split.menu.stage")
	elif _container_panel != null and _container_panel.has_method("is_open") and _container_panel.is_open():
		var can_put := true
		if _container_panel.has_method("accepts_backpack_put"):
			can_put = _container_panel.accepts_backpack_put()
		if can_put:
			label = tr("ui.split.menu.store")
	if label == _last_transfer_label:
		return
	_last_transfer_label = label
	for slot in _slots:
		slot.set_transfer_label(label)


# 委托给当前打开的面板开分离面板（灶台 → 放入；仓库 → 存入）。
func _on_slot_transfer(index: int) -> void:
	if _action_panel != null and _action_panel.has_method("is_open") and _action_panel.is_open() \
			and _action_panel.has_method("begin_stage_split"):
		_action_panel.begin_stage_split(index)
	elif _container_panel != null and _container_panel.has_method("is_open") and _container_panel.is_open() \
			and _container_panel.has_method("begin_put_split"):
		if _container_panel.has_method("accepts_backpack_put") and not _container_panel.accepts_backpack_put():
			return
		_container_panel.begin_put_split(index)


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
		slot.transfer_requested.connect(_on_slot_transfer)
		_slots.append(slot)


func _refresh() -> void:
	if _player == null:
		for slot in _slots:
			slot.set_slot(slot.slot_index, {})
		_last_snapshot.clear()
		_last_wallet_centi = -1
		_last_carry_weight = -1.0
		_last_max_carry_weight = -1.0
		_wallet_label.text = tr("ui.inventory.wallet_format") % Money.format_silver_from_centi(0)
		_backpack_title.text = tr("ui.inventory.backpack_title")
		return
	var inv: Array = _player.inventory
	_last_snapshot = inv.duplicate(true)
	_last_wallet_centi = int(_player.get("wallet_centi"))
	_last_carry_weight = float(_player.get("carry_weight"))
	_last_max_carry_weight = float(_player.get("max_carry_weight"))
	_wallet_label.text = tr("ui.inventory.wallet_format") % Money.format_silver_from_centi(_last_wallet_centi)
	_backpack_title.text = tr("ui.inventory.backpack_carry_format") % [_last_carry_weight, _last_max_carry_weight]
	for i in _slots.size():
		if i >= inv.size():
			_slots[i].set_slot(i, {})
			continue
		_slots[i].set_slot(i, inv[i])


# Snapshot 比对：item_id / quantity / quality / 容量(液体) 任一变化触发 refresh。
# 倒液体只改 container_amount/container_content（item_id/quantity/quality 不变），必须比这两项，
# 否则倒空桶后背包面板不重绘、显示停在旧的 20/20。其余字段(shape/materials/tags)跟着 item_id 变。
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
		if _slot_content(sa) != _slot_content(sb):
			return false
		if absf(_slot_amount(sa) - _slot_amount(sb)) > 0.001:
			return false
	return true


# 容器字段可能为 null（非容器槽）；安全取值用于比对。
func _slot_content(slot: Dictionary) -> String:
	var v: Variant = slot.get("container_content", null)
	return "" if v == null else str(v)


func _slot_amount(slot: Dictionary) -> float:
	var v: Variant = slot.get("container_amount", null)
	return 0.0 if v == null else float(v)


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
