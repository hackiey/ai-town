extends Control

# Client 登录界面。输入名字 → 写 Players.pending_login_name → 切到 town.tscn 让
# town.gd 的 auth callback 把名字交给 server。被 server 拒（同名在线 / 其他错误）
# 时 town.gd 会写 Players.last_login_error 并 change_scene 回这里。

const _CFG_PATH := "user://login.cfg"
const _CFG_SECTION := "login"
const _CFG_KEY_NAME := "name"
const _TOWN_SCENE := "res://src/levels/town.tscn"

@onready var _name_edit: LineEdit = %NameEdit
@onready var _enter_button: Button = %EnterButton
@onready var _error_label: Label = %ErrorLabel


func _ready() -> void:
	_name_edit.text = _load_saved_name()
	_name_edit.caret_column = _name_edit.text.length()
	_name_edit.grab_focus()
	_name_edit.text_submitted.connect(_on_text_submitted)
	_enter_button.pressed.connect(_on_enter_pressed)
	if Players.last_login_error.is_empty():
		_error_label.hide()
	else:
		_error_label.text = Players.last_login_error
		_error_label.show()
		Players.last_login_error = ""


func _on_text_submitted(_text: String) -> void:
	_submit()


func _on_enter_pressed() -> void:
	_submit()


func _submit() -> void:
	var name := _name_edit.text.strip_edges()
	if name.is_empty():
		_error_label.text = "请输入名字"
		_error_label.show()
		return
	_save_name(name)
	Players.pending_login_name = name
	get_tree().change_scene_to_file(_TOWN_SCENE)


func _load_saved_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(_CFG_PATH) != OK:
		return ""
	return str(cfg.get_value(_CFG_SECTION, _CFG_KEY_NAME, ""))


func _save_name(name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_CFG_PATH)
	cfg.set_value(_CFG_SECTION, _CFG_KEY_NAME, name)
	cfg.save(_CFG_PATH)
