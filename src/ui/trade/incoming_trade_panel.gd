class_name IncomingTradePanel
extends CanvasLayer

# NPC / 其他角色向本地玩家发起 offer 议价时弹出的响应面板（client only）。
# 只负责展示 pending trade 和把 accept/reject RPC 发回 Player；真实撮合仍走 TradeRunner。

var _player: Node = null
var _root: Control = null
var _title: Label = null
var _subtitle: Label = null
var _offer_list: VBoxContainer = null
var _request_list: VBoxContainer = null
var _accept_button: Button = null
var _reject_button: Button = null

var _current_trade: Dictionary = {}
var _queue: Array = []


func _ready() -> void:
	layer = 12
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.incoming_trade_received.connect(_on_incoming_trade_received)


func set_player(player: Node) -> void:
	_player = player
	if _player == null:
		_current_trade.clear()
		_queue.clear()
		if _root != null:
			_root.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if _root == null or not _root.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_respond("reject")
			get_viewport().set_input_as_handled()


func _on_incoming_trade_received(trade: Dictionary) -> void:
	if _player == null or not _is_trade_for_player(trade):
		return
	if str(trade.get("status", "pending")) != "pending":
		return
	if _root.visible:
		_queue.append(trade.duplicate(true))
		return
	_open_trade(trade)


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
	panel.offset_left = -260.0
	panel.offset_top = -210.0
	panel.offset_right = 260.0
	panel.offset_bottom = 210.0
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
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 18)
	_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48, 1.0))
	vbox.add_child(_title)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.add_theme_color_override("font_color", Color(0.84, 0.80, 0.72, 1.0))
	vbox.add_child(_subtitle)

	vbox.add_child(_build_line_section(tr("ui.incoming_trade.section.offer"), true))
	vbox.add_child(_build_line_section(tr("ui.incoming_trade.section.request"), false))

	var hint := Label.new()
	hint.text = tr("ui.incoming_trade.hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.68, 0.66, 0.60, 1.0))
	vbox.add_child(hint)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 10)
	vbox.add_child(buttons)

	_reject_button = Button.new()
	_reject_button.text = tr("ui.incoming_trade.button.reject")
	_reject_button.pressed.connect(func() -> void: _respond("reject"))
	buttons.add_child(_reject_button)

	_accept_button = Button.new()
	_accept_button.text = tr("ui.incoming_trade.button.accept")
	_accept_button.pressed.connect(func() -> void: _respond("accept"))
	buttons.add_child(_accept_button)


func _build_line_section(title: String, is_offer: bool) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.92, 0.88, 0.76, 1.0))
	box.add_child(label)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 3)
	box.add_child(list)
	if is_offer:
		_offer_list = list
	else:
		_request_list = list
	return box


func _open_trade(trade: Dictionary) -> void:
	_current_trade = trade.duplicate(true)
	var buyer_id := str(_current_trade.get("from_character_id", ""))
	var buyer_name := _character_display_name(buyer_id)
	_title.text = tr("ui.incoming_trade.title")
	_subtitle.text = tr("ui.incoming_trade.subtitle_format") % buyer_name
	_set_trade_lines(_offer_list, _current_trade.get("offer", []), tr("ui.incoming_trade.empty_offer"))
	_set_trade_lines(_request_list, _current_trade.get("request", []), tr("ui.incoming_trade.empty_request"))
	_root.visible = true


func _set_trade_lines(parent: VBoxContainer, value: Variant, empty_text: String) -> void:
	for child in parent.get_children():
		child.queue_free()
	var lines := _format_trade_lines(value)
	if lines.is_empty():
		var empty := Label.new()
		empty.text = empty_text
		empty.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70, 1.0))
		parent.add_child(empty)
		return
	for line in lines:
		var label := Label.new()
		label.text = line
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		parent.add_child(label)


func _format_trade_lines(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		return out
	for entry_v in (value as Array):
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_v as Dictionary
		var item_id := str(entry.get("item", "")).strip_edges()
		var count := float(entry.get("count", 0.0))
		if item_id.is_empty() or count <= 0.0:
			continue
		out.append(tr("ui.incoming_trade.line_format") % [_item_display_name(item_id), _format_trade_count(item_id, count)])
	return out


func _respond(response: String) -> void:
	if _current_trade.is_empty():
		_close_and_show_next()
		return
	var trade_id := str(_current_trade.get("trade_id", "")).strip_edges()
	if _player != null and not trade_id.is_empty() and _player.has_method("request_respond_trade"):
		_player.request_respond_trade.rpc_id(1, trade_id, response)
	_close_and_show_next()


func _close_and_show_next() -> void:
	_current_trade.clear()
	_root.visible = false
	while not _queue.is_empty():
		var next: Dictionary = _queue.pop_front()
		if _is_trade_for_player(next) and str(next.get("status", "pending")) == "pending":
			_open_trade(next)
			return


func _is_trade_for_player(trade: Dictionary) -> bool:
	if _player == null or not _player.has_method("backend_character_id"):
		return false
	return str(trade.get("to_character_id", "")) == str(_player.call("backend_character_id"))


func _character_display_name(character_id: String) -> String:
	var cid := character_id.strip_edges()
	if cid.is_empty():
		return "?"
	var tree := get_tree()
	if tree != null:
		for group_name in ["npcs", "players"]:
			for node in tree.get_nodes_in_group(group_name):
				if not (node is Character):
					continue
				var ch := node as Character
				if ch.backend_character_id() == cid:
					var display := ch.head_ui_display_name().strip_edges()
					return display if not display.is_empty() else cid
	var key := "npc.%s.name" % cid
	var translated := tr(key)
	if translated != key and not translated.strip_edges().is_empty():
		return translated
	return cid


func _item_display_name(item_id: String) -> String:
	if item_id.is_empty():
		return "?"
	if Items.has_id(item_id):
		var item := Items.by_id(item_id)
		if item != null:
			var display := item.display_name.strip_edges()
			if not display.is_empty():
				return display
	return item_id


func _format_trade_count(item_id: String, count: float) -> String:
	if _is_currency_item(item_id):
		var centi := int(round(count * 100.0))
		if centi % 100 == 0:
			return str(centi / 100)
		if centi % 10 == 0:
			return "%.1f" % (centi / 100.0)
		return "%.2f" % (centi / 100.0)
	return str(int(round(count)))


func _is_currency_item(item_id: String) -> bool:
	return item_id == "silver_coin" or item_id == "gold_coin"


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.07, 0.06, 0.98)
	style.border_color = Color(0.88, 0.70, 0.38, 0.88)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	return style
