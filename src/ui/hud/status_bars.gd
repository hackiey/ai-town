class_name StatusBars
extends CanvasLayer

# 屏幕左上角的状态条 HUD：HP / Stamina / Hunger / Rest + 关键状态标签。
# 绑定 local player 后每帧从 player 字段刷新；这些字段都通过 owner-private
# MultiplayerSynchronizer 同步到本地 owner client。
#
# UI 是纯 client 概念，server（headless）不实例化。

@onready var _hp_bar: ProgressBar = $Root/HpRow/HpBar
@onready var _hp_label: Label = $Root/HpRow/HpLabel
@onready var _stamina_bar: ProgressBar = $Root/StaminaRow/StaminaBar
@onready var _stamina_label: Label = $Root/StaminaRow/StaminaLabel
@onready var _hunger_bar: ProgressBar = $Root/HungerRow/HungerBar
@onready var _hunger_label: Label = $Root/HungerRow/HungerLabel
@onready var _rest_bar: ProgressBar = $Root/RestRow/RestBar
@onready var _rest_label: Label = $Root/RestRow/RestLabel
@onready var _condition_label: Label = $Root/ConditionLabel
@onready var _god_badge: Label = $GodBadge

var _player: Character = null


func set_player(player: Character) -> void:
	_player = player
	set_process(player != null)
	_render()


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	_render()


func _render() -> void:
	if _player == null:
		_god_badge.visible = false
		_condition_label.text = ""
		return
	_god_badge.visible = _player.groups.has("god")
	_hp_bar.max_value = _player.max_hp
	_hp_bar.value = _player.hp
	_hp_label.text = _meter_label("hp", _player.hp, _player.max_hp)

	_stamina_bar.max_value = _player.snapshots().effective_stamina_max()
	_stamina_bar.value = _player.stamina
	_stamina_label.text = _meter_label("stamina", _player.stamina, _player.snapshots().effective_stamina_max())

	_hunger_bar.max_value = _player.max_hunger
	_hunger_bar.value = _player.hunger
	_hunger_label.text = _meter_label("hunger", _player.hunger, _player.max_hunger)

	_rest_bar.max_value = _player.max_rest
	_rest_bar.value = _player.rest
	_rest_label.text = _meter_label("rest", _player.rest, _player.max_rest)

	var labels: Array[String] = []
	if not _player.alive:
		labels.append(tr("ui.status.condition.dead"))
	if _player.burning:
		labels.append(tr("ui.status.condition.burning"))
	for c in _player.active_conditions:
		var t := str(c.get("type", ""))
		match t:
			"hungry": labels.append(tr("ui.status.condition.hungry"))
			"sleeping": labels.append(tr("ui.status.condition.sleeping"))
			_: labels.append(t)
	_condition_label.text = "  ".join(labels) if labels.size() > 0 else ""


func _meter_label(attribute_id: String, current: float, max_value: float) -> String:
	return tr("ui.status.meter_format") % [tr("attribute.%s.name" % attribute_id), current, max_value]
