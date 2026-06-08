class_name CharacterPanel
extends CanvasLayer

# 玩家角色面板（client only）：
# - C 键开/关；ESC 关闭
# - 只展示 snapshots().ui_profile()，不承载背包操作
# - 面板可见时比对 snapshot 签名触发重绘；隐藏完全不工作

# 熟练度档位阈值（与 backend/src/agent-shared/prompt-context/sections.ts:22 PROFICIENCY_TIERS 一致）。
# 表现层概念，不放 i18n / 不放 character.gd —— backend renderer 也是文件内常量，对称。
const PROFICIENCY_TIERS: Array[Dictionary] = [
	{ "min": 90, "key": "master" },
	{ "min": 75, "key": "expert" },
	{ "min": 55, "key": "skilled" },
	{ "min": 35, "key": "competent" },
	{ "min": 15, "key": "apprentice" },
	{ "min": 0, "key": "novice" },
]

var _player: Node = null
var _last_profile_signature: String = ""

@onready var _root: Control = $Root
@onready var _tabs: TabContainer = $Root/Panel/Margin/VBox/Tabs
@onready var _attributes_text: RichTextLabel = $Root/Panel/Margin/VBox/Tabs/AttributesText
@onready var _proficiency_text: RichTextLabel = $Root/Panel/Margin/VBox/Tabs/ProficiencyText


func _ready() -> void:
	# Godot TabContainer 默认显示 child node name；i18n 标题必须运行时 set。
	_tabs.set_tab_title(0, tr("ui.character.tab.attributes"))
	_tabs.set_tab_title(1, tr("ui.character.tab.proficiency"))


func set_player(player: Node) -> void:
	_player = player
	_last_profile_signature = ""
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
	if key.physical_keycode == KEY_C:
		toggle()
		get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and _root.visible:
		_root.visible = false
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not _root.visible or _player == null:
		return
	var profile_signature := _profile_signature()
	if profile_signature != _last_profile_signature:
		_refresh()


func _refresh() -> void:
	if _player == null or not _player.has_method("snapshots"):
		_last_profile_signature = ""
		_attributes_text.text = ""
		_proficiency_text.text = ""
		return
	var snapshot: Dictionary = _player.snapshots().ui_profile()
	_last_profile_signature = JSON.stringify(snapshot)
	_attributes_text.text = _render_attributes(snapshot)
	_proficiency_text.text = _render_proficiency(snapshot)


func _profile_signature() -> String:
	if _player == null or not _player.has_method("snapshots"):
		return ""
	return JSON.stringify(_player.snapshots().ui_profile())


func _render_attributes(snapshot: Dictionary) -> String:
	var identity_lines := [
		_field_line("ui.character.field.name", str(snapshot.get("name", ""))),
		_field_line("ui.character.field.id", str(snapshot.get("id", ""))),
		_field_line("ui.character.field.age", str(snapshot.get("age", tr("ui.character.value.none")))),
		_field_line("ui.character.field.occupation", str(snapshot.get("occupation", tr("ui.character.value.none")))),
		_field_line("ui.character.field.personality", str(snapshot.get("personality", tr("ui.character.value.none")))),
		_field_line("ui.character.field.faction", _faction_text(str(snapshot.get("faction", "")))),
	]
	var vitals: Dictionary = snapshot.get("vitals", {})
	var physical_lines := [
		_field_line("ui.character.field.material", _material_text(snapshot)),
		_field_line("ui.character.field.mass", "%.1f kg" % float(snapshot.get("mass", 0.0))),
		_attribute_line("strength", "%.0f" % float(snapshot.get("strength", 0.0))),
		_attribute_line("constitution", "%.0f" % float(snapshot.get("constitution", 0.0))),
		_attribute_line("carry_capacity", "%.1f kg" % float(snapshot.get("maxCarryWeight", 0.0))),
		_field_line("ui.character.field.volume", "%.3f m^3" % float(snapshot.get("volume", 0.0))),
		_field_line("ui.character.field.moisture", "%.0f%%" % (float(snapshot.get("moisture", 0.0)) * 100.0)),
		_field_line("ui.character.field.temperature", "%.1f C" % float(snapshot.get("temperature", 0.0))),
		_field_line("ui.character.field.ignition", _ignition_text(snapshot)),
	]
	var status_ids: Array[String] = []
	for status_id in snapshot.get("statusIds", []):
		status_ids.append(str(status_id))
	var group_ids: Array[String] = []
	for group_id in snapshot.get("groupIds", []):
		group_ids.append(str(group_id))
	var state_lines := [
		_field_line("ui.character.field.sleeping", _bool_text(bool(snapshot.get("sleeping", false)))),
		_field_line("ui.character.field.burning", _bool_text(bool(snapshot.get("burning", false)))),
		_field_line("ui.character.field.statuses", _list_text(_status_texts(status_ids), "ui.character.value.none")),
		_field_line("ui.character.field.groups", _list_text(_group_texts(group_ids), "ui.character.value.none")),
	]
	var equipment: Dictionary = snapshot.get("equipment", {})
	var equipment_lines := []
	for slot_name in ["right_hand", "left_hand", "body", "head"]:
		equipment_lines.append(_field_line(
			"ui.character.slot.%s" % slot_name,
			_item_text(str(equipment.get(slot_name, ""))),
		))
	return "\n\n".join([
		_section("ui.character.section.identity", identity_lines),
		_section("ui.character.section.vitals", [
			_attribute_line("hp", _meter_text(vitals.get("hp", {}))),
			_attribute_line("stamina", _meter_text(vitals.get("stamina", {}))),
			_attribute_line("hunger", _meter_text(vitals.get("hunger", {}))),
			_attribute_line("rest", _meter_text(vitals.get("rest", {}))),
		]),
		_section("ui.character.section.physical", physical_lines),
		_section("ui.character.section.state", state_lines),
		_section("ui.character.section.equipment", equipment_lines),
	])


func _section(title_key: String, lines: Array) -> String:
	return "[b]%s[/b]\n%s" % [tr(title_key), "\n".join(lines)]


func _field_line(label_key: String, value: String) -> String:
	return "%s: %s" % [tr(label_key), value]


func _attribute_line(attribute_id: String, value: String) -> String:
	return "%s: %s" % [tr("attribute.%s.name" % attribute_id), value]


func _meter_text(value: Variant) -> String:
	if not (value is Dictionary):
		return tr("ui.character.value.none")
	var meter: Dictionary = value
	return "%.0f / %.0f" % [float(meter.get("current", 0.0)), float(meter.get("max", 0.0))]


func _bool_text(value: bool) -> String:
	return tr("ui.character.value.yes") if value else tr("ui.character.value.no")


func _material_text(snapshot: Dictionary) -> String:
	var localized := str(snapshot.get("materialName", "")).strip_edges()
	var material_id := str(snapshot.get("materialId", "")).strip_edges()
	if localized.is_empty():
		return material_id if not material_id.is_empty() else tr("ui.character.value.none")
	if material_id.is_empty():
		return localized
	return "%s (%s)" % [localized, material_id]


func _ignition_text(snapshot: Dictionary) -> String:
	var ignition := float(snapshot.get("ignitionPoint", -1.0))
	if ignition < 0.0:
		return tr("ui.character.value.not_flammable")
	return "%.0f C" % ignition


func _faction_text(faction_id: String) -> String:
	if faction_id.strip_edges().is_empty():
		return tr("ui.character.value.none")
	var key := "group.%s.name" % faction_id
	var localized := tr(key)
	return localized if localized != key else faction_id


func _status_texts(status_ids: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for status_id in status_ids:
		var key := "ui.status.status.%s" % status_id
		var localized := tr(key)
		var label := localized if localized != key else status_id
		var effect_key := "ui.status.status_effect.%s" % status_id
		var effect := tr(effect_key)
		if effect != effect_key:
			var format_key := "ui.status.status_with_effect_format"
			var format := tr(format_key)
			label = (format % [label, effect]) if format != format_key else "%s (%s)" % [label, effect]
		out.append(label)
	return out


func _group_texts(group_ids: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for group_id in group_ids:
		var key := "group.%s.name" % group_id
		var localized := tr(key)
		out.append(localized if localized != key else group_id)
	return out


func _item_text(item_id: String) -> String:
	var resolved := item_id.strip_edges()
	if resolved.is_empty():
		return tr("ui.character.value.empty")
	var key := "item.%s.name" % resolved
	var localized := tr(key)
	return localized if localized != key else resolved


func _list_text(values: Array[String], empty_key: String) -> String:
	return " / ".join(values) if values.size() > 0 else tr(empty_key)


# 手艺 tab：9 项 skill 一行一行展开。skill 名 + tier 名直接复用 prompt.context.proficiency.*
# 这套 key —— catalog 共享 dict，前缀只是历史首发地，不重复维护两份。
func _render_proficiency(snapshot: Dictionary) -> String:
	var entries_v: Variant = snapshot.get("proficiency", [])
	if not (entries_v is Array):
		return ""
	var lines: Array[String] = []
	var format_key := "ui.character.proficiency.line_format"
	var format := tr(format_key)
	if format == format_key:
		format = "%s: %s (%d)"
	for entry_v in entries_v:
		if not (entry_v is Dictionary):
			continue
		var entry: Dictionary = entry_v
		var skill_id := str(entry.get("skillId", ""))
		var value := float(entry.get("value", 0.0))
		var skill_label := tr("prompt.context.proficiency.skill.%s" % skill_id)
		var tier_label := tr("prompt.context.proficiency.tier.%s" % _proficiency_tier(value))
		lines.append(format % [skill_label, tier_label, int(round(value))])
	return "\n".join(lines)


func _proficiency_tier(value: float) -> String:
	for tier in PROFICIENCY_TIERS:
		if value >= float(tier.get("min", 0)):
			return str(tier.get("key", "novice"))
	return "novice"
