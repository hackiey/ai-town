extends Node

# Autoload: MechanicHost
#
# 启动时扫 data/mechanics/*.lua，每个文件 = 一个机制（speech / crops / crafting ...）。
# 每个机制是一份独立 sandbox state，源里的 globals（hook 函数 + module-private 数据）持久存活。
#
# 调用：
#   MechanicHost.invoke("crops", "on_tick", { crop = crop_dict })
#
# 返回 ScriptExecutor 的 result dict { ok, effects, error }。
#
# 加新机制：放一个 .lua 到 data/mechanics/，重启游戏即可。运行时 reload 留给后面的 god mode。

const MECHANICS_DIR := "res://data/mechanics/"

var _modules: Dictionary = {}  # mechanic_name -> LuaState


func _ready() -> void:
	_load_all()


func has_mechanic(mechanic_name: String) -> bool:
	return _modules.has(mechanic_name)


func invoke(mechanic_name: String, hook: String, ctx: Dictionary) -> Dictionary:
	var state = _modules.get(mechanic_name)
	if state == null:
		return {
			"ok": false,
			"effects": [],
			"error": "mechanic not loaded: %s" % mechanic_name,
		}
	return ScriptExecutor.call_hook(state, hook, ctx)


# 直接读 lua module 的 global 函数，不走 effect 通道。返回值是 lua 原生（primitive 或
# LuaTable）。GDScript 端按需用 LuaTable[k] / LuaConv 转换。
# 用于"纯 query"——GDScript 需要 lua 持有的 variety/recipe 等数据时用。
func query(mechanic_name: String, fn_name: String, args: Array = []) -> Variant:
	var state = _modules.get(mechanic_name)
	if state == null:
		return null
	var fn = state.globals[fn_name]
	if fn == null:
		return null
	return fn.invokev(args)


# 启动期一次性导出 reaction 元数据。每个 active reaction 一行：
#   {id, skill_id, difficulty, workstation, verb, sub_option}
# backend 通过 BackendRuntimeClient 握手时收到并缓存，给 prompt / tool schema 查询用。
# 来源为 data/mechanics/crafting.lua 的 list_reaction_metadata —— lua 是 reaction 真值，
# 这里只做语言 boundary 翻译，不在 GDScript 端维护任何镜像。
func get_reaction_catalog() -> Array:
	var raw: Variant = query("crafting", "list_reaction_metadata")
	if raw == null:
		return []
	var out: Array = []
	for row in LuaConv.to_array(raw):
		out.append(LuaConv.to_dict(row))
	return out


func _load_all() -> void:
	var dir := DirAccess.open(MECHANICS_DIR)
	if dir == null:
		push_warning("[MechanicHost] dir not found: %s" % MECHANICS_DIR)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".lua"):
			var mech_name := fname.get_basename()
			_load_one(mech_name, MECHANICS_DIR + fname)
		fname = dir.get_next()
	dir.list_dir_end()


func _load_one(mech_name: String, path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("[MechanicHost] missing: %s" % path)
		return
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		push_warning("[MechanicHost] empty: %s" % path)
		return
	var state := ScriptExecutor.load_module(source, mech_name)
	if state == null:
		return
	_modules[mech_name] = state
