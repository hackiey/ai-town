extends Node

const EDITOR_SCENE := preload("res://src2d/editor/town_editor.tscn")
const OUTPUT_PATH := "/tmp/ai-games-character-editor.png"
const LIBRARY_OUTPUT_PATH := "/tmp/ai-games-character-presets-library.png"


func _ready() -> void:
	get_window().size = Vector2i(1600, 1000)
	call_deferred("_capture")


func _capture() -> void:
	var editor := EDITOR_SCENE.instantiate()
	get_tree().root.add_child(editor)
	await get_tree().process_frame
	await get_tree().process_frame
	var tabs: TabContainer = editor.get("_editor_tabs")
	tabs.current_tab = 2
	var panel: Node = editor.get("_character_editor_panel")
	var selector: OptionButton = panel.get("_profile_selector")
	selector.select(1)
	panel.call("_on_profile_selected", 1)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	if not _save_screenshot(OUTPUT_PATH):
		get_tree().quit(1)
		return
	tabs.current_tab = 1
	editor.call("_show_asset_primary_category", "characters", "residents")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	if not _save_screenshot(LIBRARY_OUTPUT_PATH):
		get_tree().quit(1)
		return
	print("[CharacterEditorCapture] PASS %s %s" % [OUTPUT_PATH, LIBRARY_OUTPUT_PATH])
	get_tree().quit(0)


func _save_screenshot(path: String) -> bool:
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		return true
	push_error("[CharacterEditorCapture] failed to save %s: %d" % [path, error])
	return false
