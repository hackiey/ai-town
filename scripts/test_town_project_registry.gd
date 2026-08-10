extends SceneTree

const TOWN_PROJECT := preload("res://src2d/data/town_project.gd")
const CHARACTER_PART_CATALOG := preload("res://src2d/characters/character_part_catalog.gd")
const TEST_ID := "registry_smoke_town"
const CREATED_ID := "registry_created_smoke"
const REMOTE_ID := "registry_remote_smoke"

var _test_directory := ""


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	_test_directory = OS.get_temp_dir().path_join("ai-games-registry-smoke")
	TOWN_PROJECT.unregister_project(TEST_ID)
	TOWN_PROJECT.unregister_project(CREATED_ID)
	_cleanup_files()
	_cleanup_user_project(CREATED_ID)
	_cleanup_user_project("remote_%s" % REMOTE_ID)
	var created := TOWN_PROJECT.create_project(CREATED_ID, "新建注册测试", 18, 14)
	if created.is_empty() or not _is_registered(CREATED_ID):
		_fail("新建小镇没有自动加入项目注册表")
		return
	TOWN_PROJECT.unregister_project(CREATED_ID)
	_cleanup_user_project(CREATED_ID)
	var remote_local_id := TOWN_PROJECT.cache_remote_project(REMOTE_ID, "远程缓存测试", TOWN_PROJECT.make_default_map(12, 10, "远程缓存测试"))
	if remote_local_id.is_empty() or _is_registered(remote_local_id):
		_fail("服务器下载缓存不应加入本地项目注册表")
		return
	_cleanup_user_project(remote_local_id)
	if DirAccess.make_dir_recursive_absolute(_test_directory) != OK:
		_fail("无法创建临时工程目录")
		return
	var manifest := {
		"format": "ai_town",
		"version": 1,
		"id": TEST_ID,
		"name": "注册表测试小镇",
		"map": "map.json",
		"source": "user",
	}
	var map_data := TOWN_PROJECT.make_default_map(16, 12, "注册表测试小镇")
	map_data["character_profiles"] = [{
		"id": "registry_hero",
		"name": "注册表人物",
		"appearance": CHARACTER_PART_CATALOG.default_appearance(),
	}]
	map_data["player_character_id"] = "registry_hero"
	map_data["characters"] = [{
		"id": "character_registry_hero",
		"name": "注册表人物",
		"asset": "character_composite",
		"character_id": "registry_hero",
		"appearance": CHARACTER_PART_CATALOG.default_appearance(),
		"cell": [4, 5],
		"footprint": [1, 1],
		"controller": {
			"type": "player",
			"move_speed": 180,
			"behavior": "idle",
			"wander_radius": 4,
		},
	}]
	if not _write_json(_test_directory.path_join("town.json"), manifest) or not _write_json(_test_directory.path_join("map.json"), map_data):
		_fail("无法写入临时工程")
		return
	if TOWN_PROJECT.register_existing_project(_test_directory) != TEST_ID:
		_fail("无法导入外部工程路径")
		return
	var found := false
	for project_value in TOWN_PROJECT.list_registered_projects():
		if project_value is Dictionary and str(project_value.get("id", "")) == TEST_ID:
			found = str(project_value.get("directory", "")) == _test_directory and bool(project_value.get("available", false))
			break
	if not found:
		_fail("注册表没有返回外部工程")
		return
	var loaded := TOWN_PROJECT.load_map(TEST_ID)
	if loaded.get("size", []) != [16, 12]:
		_fail("无法通过注册表路径读取地图")
		return
	if str(loaded.get("player_character_id", "")) != "registry_hero" or loaded.get("character_profiles", []).size() != 1 or loaded.get("characters", []).size() != 1:
		_fail("人物档案或人物实例没有通过地图文件往返")
		return
	var loaded_controller: Dictionary = loaded.get("characters", [])[0].get("controller", {})
	if str(loaded_controller.get("type", "")) != "player" or not is_equal_approx(float(loaded_controller.get("move_speed", 0.0)), 180.0):
		_fail("人物 Controller 没有通过地图文件往返")
		return
	if not TOWN_PROJECT.save_project(TEST_ID, "注册表测试小镇 v2", loaded):
		_fail("无法通过注册表路径保存地图")
		return
	if str(TOWN_PROJECT.load_manifest(TEST_ID).get("name", "")) != "注册表测试小镇 v2":
		_fail("工程保存到了错误目录")
		return
	if not TOWN_PROJECT.unregister_project(TEST_ID):
		_fail("无法从项目列表移除测试工程")
		return
	_cleanup_files()
	print("[TownProjectRegistryTest] PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("[TownProjectRegistryTest] %s" % message)
	TOWN_PROJECT.unregister_project(TEST_ID)
	TOWN_PROJECT.unregister_project(CREATED_ID)
	_cleanup_files()
	_cleanup_user_project(CREATED_ID)
	_cleanup_user_project("remote_%s" % REMOTE_ID)
	quit(1)


func _cleanup_files() -> void:
	for file_name in ["town.json", "map.json"]:
		var file_path := _test_directory.path_join(file_name)
		if FileAccess.file_exists(file_path):
			DirAccess.remove_absolute(file_path)
	if not _test_directory.is_empty() and DirAccess.dir_exists_absolute(_test_directory):
		DirAccess.remove_absolute(_test_directory)


func _cleanup_user_project(project_id: String) -> void:
	var directory_path := ProjectSettings.globalize_path(TOWN_PROJECT.USER_ROOT + "/" + project_id)
	for file_name in ["town.json", "map.json"]:
		var file_path := directory_path.path_join(file_name)
		if FileAccess.file_exists(file_path):
			DirAccess.remove_absolute(file_path)
	if DirAccess.dir_exists_absolute(directory_path):
		DirAccess.remove_absolute(directory_path)


func _is_registered(project_id: String) -> bool:
	for project_value in TOWN_PROJECT.list_registered_projects():
		if project_value is Dictionary and str(project_value.get("id", "")) == project_id:
			return true
	return false


func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "  "))
	return true
