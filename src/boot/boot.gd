extends Node

# Main scene 入口。runtime（headless server）直接进 town；client 先经登录界面，
# login.gd 完成后再切 town。

const SCENE_TOWN := "res://src/levels/town.tscn"
const SCENE_TOWN_2D := "res://src2d/levels/town_2d.tscn"
const SCENE_TOWN_EDITOR := "res://src2d/editor/town_editor.tscn"
const SCENE_LOGIN := "res://src/ui/main_menu/login.tscn"


func _ready() -> void:
	var target := SCENE_TOWN_EDITOR if RunMode.is_town_editor() else (SCENE_TOWN_2D if RunMode.is_2d_prototype() else (SCENE_TOWN if RunMode.is_runtime() else SCENE_LOGIN))
	get_tree().change_scene_to_file.call_deferred(target)
