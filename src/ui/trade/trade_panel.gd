class_name TradePanel
extends CanvasLayer

# 玩家右键 NPC → "提出交易" 弹出的面板（client only）。
# - 左半「我给出」：玩家背包列表，每行 [☐] [中文名 × N] [SpinBox(qty)]。默认不勾选；
#   Send 时只收集勾选行的 item × qty。没有"已选"额外列表，复选框本身就是选择。
# - 右半「我要求」：搜索框 + 过滤 ItemList（实时按中文名 contains 过滤所有 47 个物品），
#   选中后 SpinBox + 添加 按钮 → 加入 request 列表。
# - 底部：发送 / 取消。
# - Send → 构造 {action:"offer", target:{character, offer, request}} 通过
#   Player.request_propose_trade RPC 走现成的 BackendActionRunner._run_offer pipeline
#   （request 非空走 trade 谈判；request:[] 走 _run_give 单向赠送同步即收）。
#
# 面板纯程序化构建（参考 NpcHoverStatus / NpcContextMenu 同款做法）；不再单独写 .tscn。

const COLUMN_WIDTH := 340.0
const REQUEST_LIST_HEIGHT := 180.0

var _player: Node = null
var _target_id: String = ""
var _target_name: String = ""

# Offer：从勾选框 + spin 实时算，不存
# Request：明确添加才有
var _request_lines: Array = []     # [{"item": "bread", "count": 2}, ...]

# 左侧 offer 行的 control 引用：每行 { "item_id": String, "check": CheckBox, "spin": SpinBox }
var _offer_rows: Array = []

# 右侧物品索引：中文名 → item_id；以及全量 (display_name, item_id) 列表（按中文名排序）
var _all_items: Array = []          # [{"id": "bread", "name": "面包"}, ...]

var _root: Control = null
var _title: Label = null
var _inventory_list: VBoxContainer = null
var _request_list: VBoxContainer = null
var _request_search: LineEdit = null
var _request_results: ItemList = null
var _request_qty_input: SpinBox = null
var _request_add_button: Button = null
var _send_button: Button = null
var _last_inventory_snapshot: Array = []
var _selected_request_item_id: String = ""


func _ready() -> void:
	layer = 11
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_item_catalog()
	_build_ui()


func set_player(player: Node) -> void:
	_player = player
	_last_inventory_snapshot.clear()
	if _root.visible:
		_refresh_inventory()


# town.gd 在 NPC 菜单"提出交易"被选时调用。
func open(player: Node, target_id: String, target_name: String) -> void:
	_player = player
	_target_id = target_id.strip_edges()
	_target_name = target_name.strip_edges()
	_request_lines.clear()
	_selected_request_item_id = ""
	_request_search.text = ""
	_request_qty_input.value = 1
	_title.text = tr("ui.trade_panel.title_format") % (_target_name if not _target_name.is_empty() else _target_id)
	_root.visible = true
	_refresh_inventory()
	_refresh_request_results("")
	_refresh_request_list()
	_update_request_add_enabled()


func _close() -> void:
	_root.visible = false
	_request_lines.clear()
	_selected_request_item_id = ""


func _unhandled_input(event: InputEvent) -> void:
	if not _root.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_close()
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not _root.visible or _player == null:
		return
	var current: Array = _player.inventory
	if not _same_inventory(current, _last_inventory_snapshot):
		_refresh_inventory()


# ────────────────────────── UI 构建 ──────────────────────────

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(panel)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -380.0
	panel.offset_top = -280.0
	panel.offset_right = 380.0
	panel.offset_bottom = 280.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	_title = Label.new()
	_title.text = tr("ui.trade_panel.title_format") % "?"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 18)
	_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48, 1.0))
	vbox.add_child(_title)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(hbox)

	hbox.add_child(_build_offer_column())
	hbox.add_child(_build_request_column())

	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_END
	button_row.add_theme_constant_override("separation", 12)
	vbox.add_child(button_row)

	_send_button = Button.new()
	_send_button.text = tr("ui.trade_panel.button.send")
	_send_button.pressed.connect(_on_send_pressed)
	button_row.add_child(_send_button)

	var cancel := Button.new()
	cancel.text = tr("ui.trade_panel.button.cancel")
	cancel.pressed.connect(_close)
	button_row.add_child(cancel)


func _build_offer_column() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)

	var section := Label.new()
	section.text = tr("ui.trade_panel.section.offer")
	section.add_theme_font_size_override("font_size", 14)
	col.add_child(section)

	var hint := Label.new()
	hint.text = tr("ui.trade_panel.hint.check_to_offer")
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	col.add_child(hint)

	var inv_scroll := ScrollContainer.new()
	inv_scroll.custom_minimum_size = Vector2(0, 320)
	inv_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(inv_scroll)

	_inventory_list = VBoxContainer.new()
	_inventory_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inventory_list.add_theme_constant_override("separation", 4)
	inv_scroll.add_child(_inventory_list)

	return col


func _build_request_column() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)

	var section := Label.new()
	section.text = tr("ui.trade_panel.section.request")
	section.add_theme_font_size_override("font_size", 14)
	col.add_child(section)

	_request_search = LineEdit.new()
	_request_search.placeholder_text = tr("ui.trade_panel.field.search_item")
	_request_search.text_changed.connect(_on_request_search_changed)
	col.add_child(_request_search)

	_request_results = ItemList.new()
	_request_results.custom_minimum_size = Vector2(0, REQUEST_LIST_HEIGHT)
	_request_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_request_results.item_selected.connect(_on_request_result_selected)
	col.add_child(_request_results)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 6)
	col.add_child(input_row)

	_request_qty_input = SpinBox.new()
	_request_qty_input.min_value = 1
	_request_qty_input.max_value = 999
	_request_qty_input.value = 1
	_request_qty_input.step = 1
	_request_qty_input.custom_minimum_size = Vector2(80, 0)
	input_row.add_child(_request_qty_input)

	_request_add_button = Button.new()
	_request_add_button.text = tr("ui.trade_panel.button.add_request")
	_request_add_button.disabled = true
	_request_add_button.pressed.connect(_on_add_request_pressed)
	_request_add_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_row.add_child(_request_add_button)

	var sep := HSeparator.new()
	col.add_child(sep)

	_request_list = VBoxContainer.new()
	_request_list.add_theme_constant_override("separation", 4)
	col.add_child(_request_list)

	return col


# ────────────────────────── 左侧（offer）刷新 ──────────────────────────

func _refresh_inventory() -> void:
	# 保留勾选状态：用 item_id 作为 key（同 id 的不同 stack 会被合并视图——勾选 = 全勾）。
	# 钱包行用 "silver_coin" 作 key，spin 是 float（银），其他 item 是 int（件）。
	var prior_checks: Dictionary = {}
	var prior_qty: Dictionary = {}
	for row in _offer_rows:
		var iid := str(row.get("item_id", ""))
		if iid.is_empty():
			continue
		prior_checks[iid] = (row.get("check") as CheckBox).button_pressed
		prior_qty[iid] = float((row.get("spin") as SpinBox).value)

	for child in _inventory_list.get_children():
		child.queue_free()
	_offer_rows.clear()

	if _player == null:
		_last_inventory_snapshot.clear()
		return

	# 钱包行（如有余额）置顶：silver_coin / gold_coin 不在 inventory，但仍是合法的 offer line。
	var wallet_centi: int = int(_player.wallet_centi) if "wallet_centi" in _player else 0
	if wallet_centi > 0:
		var prior_silver: float = float(prior_qty.get("silver_coin", wallet_centi / 100.0))
		var wallet_row := _make_wallet_row(wallet_centi,
				bool(prior_checks.get("silver_coin", false)),
				prior_silver)
		_inventory_list.add_child(wallet_row.get("control") as Control)
		_offer_rows.append(wallet_row)

	var inv: Array = _player.inventory
	_last_inventory_snapshot = inv.duplicate(true)

	# 合并同 id 库存到一行（玩家关心"我有多少 bread"，不关心分了几堆）
	var aggregated: Dictionary = {}  # item_id → total_qty（保序用 order list）
	var order: Array[String] = []
	for slot_v in inv:
		var slot: Dictionary = slot_v
		var qty := int(slot.get("quantity", 0))
		if qty <= 0:
			continue
		var item_id := str(slot.get("item_id", ""))
		if item_id.is_empty():
			continue
		if aggregated.has(item_id):
			aggregated[item_id] = int(aggregated[item_id]) + qty
		else:
			aggregated[item_id] = qty
			order.append(item_id)

	for item_id in order:
		var total := int(aggregated[item_id])
		var row := _make_inventory_row(item_id, total,
				bool(prior_checks.get(item_id, false)),
				int(prior_qty.get(item_id, 1)))
		_inventory_list.add_child(row.get("control") as Control)
		_offer_rows.append(row)


func _make_inventory_row(item_id: String, available_qty: int, checked: bool, qty_value: int) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var check := CheckBox.new()
	check.button_pressed = checked
	row.add_child(check)

	var name_label := Label.new()
	name_label.text = "%s × %d" % [_item_display_name(item_id), available_qty]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var spin := SpinBox.new()
	spin.min_value = 1
	spin.max_value = available_qty
	spin.value = clampi(qty_value, 1, available_qty)
	spin.step = 1
	spin.custom_minimum_size = Vector2(80, 0)
	row.add_child(spin)

	return {
		"control": row,
		"item_id": item_id,
		"check": check,
		"spin": spin,
		"is_currency": false,
	}


# 钱包行：item_id = "silver_coin"，spin value 单位是"银"（float, step 0.01），上限 = 钱包余额。
# _collect_offer_lines 看 is_currency 走 float count。
func _make_wallet_row(wallet_centi: int, checked: bool, qty_silver: float) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var check := CheckBox.new()
	check.button_pressed = checked
	row.add_child(check)

	var max_silver := wallet_centi / 100.0
	var name_label := Label.new()
	name_label.text = "%s × %.2f 银" % [_item_display_name("silver_coin"), max_silver]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var spin := SpinBox.new()
	spin.min_value = 0.01
	spin.max_value = max_silver
	spin.step = 0.01
	spin.value = clampf(qty_silver, 0.01, max_silver)
	spin.custom_minimum_size = Vector2(100, 0)
	row.add_child(spin)

	return {
		"control": row,
		"item_id": "silver_coin",
		"check": check,
		"spin": spin,
		"is_currency": true,
	}


# ────────────────────────── 右侧（request）刷新 ──────────────────────────

func _build_item_catalog() -> void:
	_all_items.clear()
	for id_v in Items.all_ids():
		var id := str(id_v)
		var item := Items.by_id(id)
		if item == null:
			continue
		var name := item.display_name.strip_edges()
		if name.is_empty():
			name = id
		_all_items.append({"id": id, "name": name})
	_all_items.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))


func _on_request_search_changed(text: String) -> void:
	_refresh_request_results(text)


func _refresh_request_results(filter: String) -> void:
	_request_results.clear()
	_selected_request_item_id = ""
	_update_request_add_enabled()
	var needle := filter.strip_edges().to_lower()
	for entry_v in _all_items:
		var entry: Dictionary = entry_v
		var name := str(entry["name"])
		var id := str(entry["id"])
		if not needle.is_empty():
			# 同时按中文名和 id 模糊匹配，避免有人输入英文 id
			if not (name.to_lower().contains(needle) or id.to_lower().contains(needle)):
				continue
		var idx := _request_results.add_item(name)
		_request_results.set_item_metadata(idx, id)


func _on_request_result_selected(index: int) -> void:
	var meta: Variant = _request_results.get_item_metadata(index)
	_selected_request_item_id = str(meta)
	_apply_request_qty_mode(_selected_request_item_id)
	_update_request_add_enabled()


# silver_coin / gold_coin: step 0.01, min 0.01。其他 item: step 1, min 1。
func _apply_request_qty_mode(item_id: String) -> void:
	if _request_qty_input == null:
		return
	if _is_currency_item(item_id):
		_request_qty_input.step = 0.01
		_request_qty_input.min_value = 0.01
		if _request_qty_input.value < 0.01:
			_request_qty_input.value = 0.01
	else:
		_request_qty_input.step = 1
		_request_qty_input.min_value = 1
		if _request_qty_input.value < 1:
			_request_qty_input.value = 1


func _is_currency_item(item_id: String) -> bool:
	return item_id == "silver_coin" or item_id == "gold_coin"


func _update_request_add_enabled() -> void:
	_request_add_button.disabled = _selected_request_item_id.is_empty()


func _refresh_request_list() -> void:
	for child in _request_list.get_children():
		child.queue_free()
	if _request_lines.is_empty():
		var empty := Label.new()
		empty.text = tr("ui.trade_panel.empty_request")
		empty.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
		_request_list.add_child(empty)
		return
	for i in _request_lines.size():
		var line: Dictionary = _request_lines[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var label := Label.new()
		var line_item := str(line.get("item", ""))
		var count_text := _format_trade_count(line_item, line.get("count", 0))
		label.text = tr("ui.trade_panel.line_format") % [_item_display_name(line_item), count_text]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var remove_button := Button.new()
		remove_button.text = tr("ui.trade_panel.button.remove")
		var captured_index := i
		remove_button.pressed.connect(func() -> void:
			_remove_request_at(captured_index)
		)
		row.add_child(remove_button)
		_request_list.add_child(row)


func _on_add_request_pressed() -> void:
	var item_id := _selected_request_item_id
	if item_id.is_empty():
		return
	var raw: float = float(_request_qty_input.value)
	var is_currency := _is_currency_item(item_id)
	# currency 走 float 累加（0.01 精度），其他 item 走 int 累加。
	if is_currency:
		var add_silver: float = round(raw * 100.0) / 100.0
		if add_silver < 0.01:
			return
		for line_v in _request_lines:
			var line: Dictionary = line_v
			if str(line.get("item", "")) == item_id:
				var prev: float = float(line.get("count", 0.0))
				line["count"] = round((prev + add_silver) * 100.0) / 100.0
				_refresh_request_list()
				return
		_request_lines.append({"item": item_id, "count": add_silver})
	else:
		var qty := int(raw)
		if qty <= 0:
			return
		for line_v in _request_lines:
			var line: Dictionary = line_v
			if str(line.get("item", "")) == item_id:
				line["count"] = int(line.get("count", 0)) + qty
				_refresh_request_list()
				return
		_request_lines.append({"item": item_id, "count": qty})
	_refresh_request_list()


func _remove_request_at(index: int) -> void:
	if index < 0 or index >= _request_lines.size():
		return
	_request_lines.remove_at(index)
	_refresh_request_list()


# ────────────────────────── 发送 ──────────────────────────

func _collect_offer_lines() -> Array:
	var out: Array = []
	for row in _offer_rows:
		var check := row.get("check") as CheckBox
		if check == null or not check.button_pressed:
			continue
		var item_id := str(row.get("item_id", ""))
		if item_id.is_empty():
			continue
		var spin_value: float = float((row.get("spin") as SpinBox).value)
		if bool(row.get("is_currency", false)):
			# 钱包行：spin 单位是银（float），归一到 0.01 精度后下传
			var silver: float = round(spin_value * 100.0) / 100.0
			if silver < 0.01:
				continue
			out.append({"item": item_id, "count": silver})
		else:
			var qty := int(spin_value)
			if qty <= 0:
				continue
			out.append({"item": item_id, "count": qty})
	return out


func _on_send_pressed() -> void:
	if _player == null or _target_id.is_empty():
		return
	var offer_lines := _collect_offer_lines()
	if offer_lines.is_empty() and _request_lines.is_empty():
		# 双向空交易没意义，直接关
		_close()
		return
	if not _player.has_method("request_propose_trade"):
		push_warning("[trade_panel] player 缺 request_propose_trade RPC")
		return
	var action_request := {
		"id": "ui_offer_%d" % Time.get_ticks_msec(),
		"action": "offer",
		"target": {
			"characterId": _target_id,
			"offer": offer_lines,
			"request": _request_lines.duplicate(true),
		},
	}
	_player.request_propose_trade.rpc_id(1, action_request)
	_close()


# ────────────────────────── 辅助 ──────────────────────────

func _format_trade_count(item_id: String, count: Variant) -> String:
	if _is_currency_item(item_id):
		# 0.01 网格：1.00 → "1"，0.75 → "0.75"，2.50 → "2.5"。
		var centi := int(round(float(count) * 100.0))
		if centi % 100 == 0:
			return str(centi / 100)
		if centi % 10 == 0:
			return "%.1f" % (centi / 100.0)
		return "%.2f" % (centi / 100.0)
	return str(int(count))


func _item_display_name(item_id: String) -> String:
	if item_id.is_empty():
		return "?"
	if Items.has_id(item_id):
		var item := Items.by_id(item_id)
		if item != null:
			var name := item.display_name
			if not name.strip_edges().is_empty():
				return name
	return item_id


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
	return true


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.07, 0.06, 0.97)
	style.border_color = Color(0.88, 0.70, 0.38, 0.85)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	return style
