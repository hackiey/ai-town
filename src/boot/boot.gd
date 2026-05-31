extends Node

# Main scene 入口。runtime（headless server）直接进 town；client 先经登录界面，
# login.gd 完成后再切 town。

const SCENE_TOWN := "res://src/levels/town.tscn"
const SCENE_LOGIN := "res://src/ui/main_menu/login.tscn"


func _ready() -> void:
	var target := SCENE_TOWN if RunMode.is_runtime() else SCENE_LOGIN
	get_tree().change_scene_to_file.call_deferred(target)
