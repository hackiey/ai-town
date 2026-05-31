class_name ScriptExecutor

# 跑 LLM/玩家提供的 lua 源，在沙箱里调指定 entry 函数，应用所有 effects。
# 设计文档：docs/architecture/scripting-layer.md
#
# 两种使用模式：
#
# 1) 一次性脚本（消耗品 / 法术 / item.on_use）——每次 new state，跑完丢：
#      ScriptExecutor.execute(source, entry, ctx) -> result
#
# 2) 持久 module（mechanic：crops / crafting / speech）——load 一次，反复 call hook：
#      var state = ScriptExecutor.load_module(source, "crops")
#      ScriptExecutor.call_hook(state, "on_tick", ctx) -> result
#
# Effect contract（result.effects[i]）：
#   { type: String, applied: bool, summary: String, error?: String }
#
# 沙箱限制（第一版）：只开 base/string/table/math 库；no io/os/package/debug/coroutine。
# 缺：指令计数 cap、内存上限、wall-clock timeout——LLM 内容上线前必须补齐。

const _SANDBOX_LIBS := (
	LuaState.LUA_BASE | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_MATH
)


# === 一次性执行 ===

static func execute(source: String, entry: String, ctx: Dictionary) -> Dictionary:
	var lua := _new_sandbox()
	var load_result = lua.do_string(source)
	if load_result is LuaError:
		return _failure("lua parse/load error: %s" % str(load_result))
	return _invoke(lua, entry, ctx)


# === 持久 module ===

# 加载一份 lua 源到一个独立 sandbox state。源里的 globals（包括 hook 函数和 module-private
# 数据）保留下来，后续 call_hook 直接复用。失败返回 null 并 push_error。
static func load_module(source: String, mechanic_name: String) -> LuaState:
	var lua := _new_sandbox()
	var result = lua.do_string(source)
	if result is LuaError:
		push_error("[ScriptExecutor] load_module(%s) failed: %s" % [mechanic_name, str(result)])
		return null
	return lua


# 在已加载的 module state 上调 hook(ctx)。每次 call 重新 inject ScriptApi——闭包要绑到本次
# call 的 effects 数组上，不能跨 call 共享。
static func call_hook(state: LuaState, hook: String, ctx: Dictionary) -> Dictionary:
	if state == null:
		return _failure("call_hook: state is null")
	return _invoke(state, hook, ctx)


# === 内部 ===

static func _new_sandbox() -> LuaState:
	var lua := LuaState.new()
	# 沙箱：只开 base/string/table/math。Godot 集成那一组（VARIANT/SINGLETONS/CLASSES）
	# 不开——脚本不该直接 new Object 或拿 OS 单例
	lua.open_libraries(_SANDBOX_LIBS)
	return lua


static func _invoke(lua: LuaState, entry: String, ctx: Dictionary) -> Dictionary:
	var collected_effects: Array = []
	ScriptApi.inject(lua, ctx, collected_effects)

	var entry_fn = lua.globals[entry]
	if entry_fn == null:
		return _failure("entry function '%s' not defined" % entry)

	var lua_ctx: Variant = _gd_to_lua(lua, ctx)
	var call_result = entry_fn.invokev([lua_ctx])
	if call_result is LuaError:
		return _failure("lua runtime error in %s(): %s" % [entry, str(call_result)], collected_effects)

	# Hook 可选 return：
	#   nil / ""        → OK，无返回数据
	#   non-empty string → reject 原因（effects 不 apply）
	#   LuaTable / Dict  → 数据返回，存到 result.return_value（深度转 GDScript 原生）
	if typeof(call_result) == TYPE_STRING and not (call_result as String).is_empty():
		return _failure(str(call_result))
	var return_value: Variant = null
	if call_result != null and typeof(call_result) != TYPE_STRING:
		return_value = LuaConv.to_variant(call_result)

	var applied_summaries: Array = []
	for eff in collected_effects:
		var apply_result := Effects.apply(eff)
		var entry_dict := {
			"type": eff.get("type", ""),
			"applied": bool(apply_result.get("ok", false)),
			"summary": str(apply_result.get("summary", "")),
		}
		if apply_result.has("error"):
			entry_dict["error"] = apply_result["error"]
		applied_summaries.append(entry_dict)

	return {
		"ok": true,
		"effects": applied_summaries,
		"raw_effects": collected_effects,
		"return_value": return_value,
		"error": "",
	}


static func _failure(msg: String, partial_effects: Array = []) -> Dictionary:
	return {
		"ok": false,
		"effects": partial_effects,
		"raw_effects": [],
		"return_value": null,
		"error": msg,
	}


# 把 GDScript 值递归转成 lua 友好结构。
#   - primitive (bool/int/float/String) → 原样
#   - Dictionary → lua table（string-key）
#   - Array → lua table（1-indexed sequential，用 rawset）
#   - Object (Node / Resource) → 原样保留，lua 端只作 token 用
# 不转 Object 是因为 lua 要把它再传回 GDScript 的 affect.* 时需要原引用。
# 注：LuaTable 的 GDScript [] setter 只支持 String key，整数索引必须走 rawset(key, value)。
static func _gd_to_lua(lua: LuaState, v: Variant) -> Variant:
	if v == null:
		return null
	var t := typeof(v)
	if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_STRING:
		return v
	if t == TYPE_DICTIONARY:
		var d: Dictionary = v as Dictionary
		var tbl := lua.create_table()
		for k in d.keys():
			tbl[str(k)] = _gd_to_lua(lua, d[k])
		return tbl
	if t == TYPE_ARRAY or t == TYPE_PACKED_STRING_ARRAY or t == TYPE_PACKED_INT32_ARRAY \
			or t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_FLOAT64_ARRAY:
		var arr: Array = Array(v)
		var tbl := lua.create_table()
		for i in arr.size():
			tbl.rawset(i + 1, _gd_to_lua(lua, arr[i]))  # lua 1-indexed
		return tbl
	# Object / Resource / 其他 → 原样保留
	return v
