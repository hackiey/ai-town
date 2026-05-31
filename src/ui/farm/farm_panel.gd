class_name FarmPanel
extends CanvasLayer

# 农场管理面板（client only）：
# - EventBus.farm_proximity_changed 维护 _active_farm；进入 → 显示底部 hint
# - E 键打开（再按 E / ESC 关闭）；面板靠右，列表式（适配未来十几个 slot）
# - 玩家拖背包可种植物到行内 drop zone → 该格规划"种植 + seed_id"
# - 勾选 N 行 → toolbar [除虫]/[收获]/[铲除] 对选中行批量打标
# - [💧浇水整片] = 全片操作（与 slot 选择无关）
# - [开始] 编出 ops 列表 RPC 提交；[关闭] 不影响已在跑的队列；想中断在世界里走开即可
#
# 设计：plan §Phase B / Key decision 4；UI 重做：右侧 list + drag-only plant + 铲除动作

const FARM_SLOT_WIDGET := preload("res://src/ui/farm/farm_slot_widget.gd")

var _player: Node = null
var _active_farm: Node = null   # proximity 当前 farm
var _open_farm: Node = null     # 当前面板开着的 farm

# 规划草稿：slot_index → "plant" | "pest" | "harvest" | "uproot"
var _planned_actions: Dictionary = {}
# slot_index → seed_id（plant 专用；值可以是 wheat 这类兼作种粮的物品）
var _planned_seeds: Dictionary = {}
# 整片浇水
var _planned_water: bool = false
# slot_index → bool 选中状态
var _selected: Dictionary = {}

var _slot_widgets: Array = []
var _refresh_accum: float = 0.0

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/Title
@onready var _list: VBoxContainer = $Root/Panel/Margin/VBox/Scroll/List
@onready var _select_all_btn: Button = $Root/Panel/Margin/VBox/SelectionBar/SelectAll
@onready var _invert_btn: Button = $Root/Panel/Margin/VBox/SelectionBar/InvertSelection
@onready var _clear_sel_btn: Button = $Root/Panel/Margin/VBox/SelectionBar/ClearSelection
@onready var _clear_plans_btn: Button = $Root/Panel/Margin/VBox/SelectionBar/ClearPlans
@onready var _pest_btn: Button = $Root/Panel/Margin/VBox/ActionBar/Pest
@onready var _harvest_btn: Button = $Root/Panel/Margin/VBox/ActionBar/Harvest
@onready var _uproot_btn: Button = $Root/Panel/Margin/VBox/ActionBar/Uproot
@onready var _water_btn: Button = $Root/Panel/Margin/VBox/ActionBar/Water
@onready var _start_btn: Button = $Root/Panel/Margin/VBox/Footer/Start
@onready var _cancel_btn: Button = $Root/Panel/Margin/VBox/Footer/Cancel
@onready var _status: Label = $Root/Panel/Margin/VBox/Footer/Status
@onready var _hint: Label = $Hint


func _ready() -> void:
	_root.visible = false
	_hint.visible = false
	EventBus.farm_proximity_changed.connect(_on_proximity_changed)
	_select_all_btn.pressed.connect(_on_select_all)
	_invert_btn.pressed.connect(_on_invert_selection)
	_clear_sel_btn.pressed.connect(_on_clear_selection)
	_clear_plans_btn.pressed.connect(_on_clear_plans)
	_pest_btn.pressed.connect(func() -> void: _apply_batch("pest"))
	_harvest_btn.pressed.connect(func() -> void: _apply_batch("harvest"))
	_uproot_btn.pressed.connect(func() -> void: _apply_batch("uproot"))
	_water_btn.toggled.connect(_on_water_toggled)
	_start_btn.pressed.connect(_on_start_pressed)
	_cancel_btn.pressed.connect(_on_cancel_pressed)


func set_player(player: Node) -> void:
	_player = player


func _process(delta: float) -> void:
	# 面板开着时定时刷新 slot 状态（server 上 crop 在跑，moisture/pest/stage 会变）
	if _open_farm == null:
		return
	_refresh_accum += delta
	if _refresh_accum >= 0.5:
		_refresh_accum = 0.0
		_refresh_slots_from_world()


func _on_proximity_changed(farm: Node, entered: bool) -> void:
	if entered:
		_active_farm = farm
		if not _root.visible:
			_show_hint()
	else:
		if farm == _active_farm:
			_active_farm = null
			_hint.visible = false
		# 离开 farm 时关面板（避免远距离误操作）
		if farm == _open_farm and _root.visible:
			close()


func _show_hint() -> void:
	if _active_farm == null:
		return
	_hint.text = "%s · %s" % [tr("ui.farm.hint.press_e_to_plant"), _farm_display_name(_active_farm)]
	_hint.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_E and _active_farm != null and not _root.visible:
		open(_active_farm)
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_E and _root.visible:
		close()
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and _root.visible:
		close()
		get_viewport().set_input_as_handled()


func open(farm: Node) -> void:
	_open_farm = farm
	_planned_actions.clear()
	_planned_seeds.clear()
	_selected.clear()
	_planned_water = false
	_water_btn.set_pressed_no_signal(false)
	_title.text = tr("ui.farm.title_format") % _farm_display_name(farm)
	_build_slot_rows()
	_refresh_slots_from_world()
	_update_status()
	_root.visible = true
	_hint.visible = false
	set_process(true)


func close() -> void:
	_root.visible = false
	_open_farm = null
	_planned_actions.clear()
	_planned_seeds.clear()
	_selected.clear()
	_planned_water = false
	_water_btn.set_pressed_no_signal(false)
	set_process(false)
	if _active_farm != null:
		_show_hint()


func _farm_id(farm: Node) -> String:
	if farm is FarmGroup:
		return (farm as FarmGroup).effective_farm_id()
	return String(farm.name)


func _farm_display_name(farm: Node) -> String:
	if farm is FarmGroup:
		return (farm as FarmGroup).effective_display_name()
	return String(farm.name)


func _build_slot_rows() -> void:
	for c in _list.get_children():
		c.queue_free()
	_slot_widgets.clear()
	if _open_farm == null or not _open_farm.has_method("slots"):
		return
	var n: int = (_open_farm.slots() as Array).size()
	for i in n:
		var w := FARM_SLOT_WIDGET.new()
		w.slot_index = i
		w.selection_changed.connect(_on_slot_selection_changed)
		w.seed_dropped.connect(_on_seed_dropped)
		w.plan_cleared.connect(_on_plan_cleared)
		_list.add_child(w)
		_slot_widgets.append(w)


func _refresh_slots_from_world() -> void:
	if _open_farm == null or not _open_farm.has_method("describe_for_context"):
		return
	var desc: Dictionary = _open_farm.describe_for_context()
	var slot_states: Array = desc.get("slots", [])
	for i in _slot_widgets.size():
		if i >= slot_states.size():
			continue
		var widget = _slot_widgets[i]
		widget.set_state(slot_states[i])
		var planned := String(_planned_actions.get(i, ""))
		var seed_id := String(_planned_seeds.get(i, ""))
		widget.set_planned(planned, seed_id)
		widget.set_selected(bool(_selected.get(i, false)))


func _on_slot_selection_changed(idx: int, selected: bool) -> void:
	if selected:
		_selected[idx] = true
	else:
		_selected.erase(idx)


func _on_select_all() -> void:
	for w in _slot_widgets:
		_selected[w.slot_index] = true
	_refresh_slots_from_world()


func _on_invert_selection() -> void:
	for w in _slot_widgets:
		var idx: int = w.slot_index
		if _selected.has(idx):
			_selected.erase(idx)
		else:
			_selected[idx] = true
	_refresh_slots_from_world()


func _on_clear_selection() -> void:
	_selected.clear()
	_refresh_slots_from_world()


func _on_clear_plans() -> void:
	_planned_actions.clear()
	_planned_seeds.clear()
	_planned_water = false
	_water_btn.set_pressed_no_signal(false)
	_refresh_slots_from_world()
	_update_status()


# 把 kind 应用到所有"选中且适用"的格子；plant 不通过这条路径。
func _apply_batch(kind: String) -> void:
	if _selected.is_empty():
		_status.text = tr("ui.farm.status.must_select_slot")
		return
	var applied := 0
	var skipped := 0
	for w in _slot_widgets:
		var idx: int = w.slot_index
		if not _selected.get(idx, false):
			continue
		if not _is_action_valid_for(kind, w):
			skipped += 1
			continue
		_planned_actions[idx] = kind
		_planned_seeds.erase(idx)  # plant 与其它互斥
		applied += 1
	_refresh_slots_from_world()
	_update_status_after_batch(kind, applied, skipped)


func _is_action_valid_for(kind: String, widget) -> bool:
	match kind:
		"pest":
			return widget.is_occupied() and widget.has_pest()
		"harvest":
			return widget.is_occupied() and widget.is_ripe()
		"uproot":
			return widget.is_occupied()
		"plant":
			return not widget.is_occupied()
	return false


func _update_status_after_batch(kind: String, applied: int, skipped: int) -> void:
	var action_name := _kind_display_name(kind)
	if applied == 0:
		_status.text = tr("ui.farm.status.no_applicable") % [action_name, skipped]
	elif skipped > 0:
		_status.text = tr("ui.farm.status.planned_with_skipped") % [action_name, applied, skipped]
	else:
		_update_status()


func _kind_display_name(kind: String) -> String:
	match kind:
		"plant": return tr("ui.farm.action_short.plant")
		"pest": return tr("ui.farm.action_short.pest")
		"harvest": return tr("ui.farm.action_short.harvest")
		"uproot": return tr("ui.farm.action_short.uproot")
		"water": return tr("ui.farm.action_short.water")
	return kind


# 拖入可种植物 → 该格规划 plant + seed_id（覆盖任何已有规划，包括 pest/harvest/uproot）
func _on_seed_dropped(idx: int, seed_id: String) -> void:
	if _player == null:
		return
	# 校验背包里仍有这份可种植物（拖完可能被别处用掉了）
	var have: int = 0
	if _player.has_method("count_item"):
		have = int(_player.inventory_ops().count_item(seed_id))
	if have <= 0:
		_status.text = tr("ui.farm.status.no_seed")
		return
	# 简单防呆：避免同一个种植物被规划在超出库存数量的格子上
	var same_seed_planned := 0
	for k in _planned_seeds.keys():
		if String(_planned_seeds[k]) == seed_id and int(k) != idx:
			same_seed_planned += 1
	if same_seed_planned + 1 > have:
		_status.text = tr("ui.farm.status.seed_short") % [seed_id, same_seed_planned + 1, have]
		return
	_planned_actions[idx] = "plant"
	_planned_seeds[idx] = seed_id
	_refresh_slots_from_world()
	_update_status()


func _on_plan_cleared(idx: int) -> void:
	if _planned_actions.get(idx, "") == "plant":
		_planned_actions.erase(idx)
		_planned_seeds.erase(idx)
		_refresh_slots_from_world()
		_update_status()


func _on_water_toggled(pressed: bool) -> void:
	_planned_water = pressed
	_update_status()


func _update_status() -> void:
	var n := _planned_actions.size() + (1 if _planned_water else 0)
	if n == 0:
		_status.text = tr("ui.farm.status.unplanned")
	else:
		_status.text = tr("ui.farm.status.planned_count") % n


func _on_cancel_pressed() -> void:
	close()


# 提交：编 ops → RPC。Server 端按 slot_index 反查 FarmSlot。
# 顺序：plant → pest → harvest → uproot → water。slot_index 升序，character 走位更顺。
func _on_start_pressed() -> void:
	if _open_farm == null or _player == null:
		return
	var ops: Array = []
	var indices: Array = _planned_actions.keys()
	indices.sort()
	for kind_filter in ["plant", "pest", "harvest", "uproot"]:
		for idx in indices:
			if _planned_actions[idx] != kind_filter:
				continue
			var op := {
				"kind": kind_filter,
				"slot_index": int(idx),
			}
			if kind_filter == "plant":
				op["seed_id"] = String(_planned_seeds.get(idx, ""))
			ops.append(op)
	if _planned_water:
		ops.append({"kind": "water"})
	if ops.is_empty():
		_status.text = tr("ui.farm.status.nothing_planned")
		return
	if not _player.has_method("request_queue_farm_actions"):
		push_warning("[FarmPanel] player 缺 request_queue_farm_actions")
		return
	_player.request_queue_farm_actions.rpc_id(1, _farm_id(_open_farm), ops)
	close()
