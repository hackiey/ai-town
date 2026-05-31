class_name LuaConv

# Lua → GDScript 转换工具。
# LuaTable 在 GDScript 端 [] 只支持 string key，数字 key 会报错；
# 用内置 to_array() / to_dictionary() 整表转换。
#
# ─── 边界约定 (Lua → GDScript typed sink) ───────────────────────────────────
# Lua 的 `{}` 同时是空 array 和空 dict，语言层无法判别。约定在边界层归一：
#
#   1. 空 lua 表 `{}` 在任意 typed 入口都被接受
#      - dict-edged sink (to_dict)  → 收为 `{}`
#      - array-edged sink (to_array) → 收为 `[]`
#
#   2. 非空但类型错（非空 array 传 to_dict / 非空 dict 传 to_array）
#      → push_warning 并返回空集合。这是类型边界的真正保护对象。
#
#   3. Lua 端无需记每个 API 的"空到底写 nil 还是 {}"：写 `{}` 永远安全。
#      GDScript 端无需每个 lambda 写 `null` 兜底：直接 LuaConv.to_dict(x)。
#
# 不要在 to_dict / to_array 调用点上做 per-API "if null then {}" 的兜底 ——
# 那是把语言级歧义往每个调用点散布，欠新债。所有归一都收敛在本文件。
# ────────────────────────────────────────────────────────────────────────────

static func to_array(t) -> Array:
	if t == null:
		return []
	if t is Array:
		return t
	# Empty LuaTable deep-converted via to_variant() becomes {} (see to_variant
	# fallthrough below); treat any Dictionary here as "values only".
	if t is Dictionary:
		return (t as Dictionary).values()
	if t is Object and t.has_method("to_array"):
		return t.to_array()
	push_warning("[LuaConv] to_array: unsupported type %s" % typeof(t))
	return []


# LuaTable (string-keyed) → Dictionary。递归深转：嵌套 LuaTable 也会变成原生
# Dictionary / Array，否则 set_slot / world_event 等会把 LuaTable 当 value 漏进
# 下游 GDScript 路径，触发 "Invalid cast to Dictionary" 之类的崩溃。
static func to_dict(t) -> Dictionary:
	if t == null:
		return {}
	var v: Variant = to_variant(t)
	if v is Dictionary:
		return v as Dictionary
	# 空 lua 表 `{}` 在 to_variant 里默认归 Array（lua 惯例 `tags={}` 是空 list）。
	# dict-edged sink 把它视为空 dict —— 见文件头"边界约定"。
	if v is Array and (v as Array).is_empty():
		return {}
	push_warning("[LuaConv] to_dict: value not a dictionary (typeof=%d)" % typeof(v))
	return {}


# Deep-convert lua-returned value (LuaTable / primitive / nested) → native GDScript.
# Sequential lua tables (int 1..N keys) → Array, otherwise → Dictionary.
# Recurses into nested tables. Used for hook return values.
static func to_variant(v):
	if v == null:
		return null
	if v is bool or v is int or v is float or v is String:
		return v
	if v is Array:
		var out_a: Array = []
		for x in v:
			out_a.append(to_variant(x))
		return out_a
	if v is Dictionary:
		var out_d: Dictionary = {}
		for k in v.keys():
			out_d[k] = to_variant(v[k])
		return out_d
	# LuaTable: detect array vs dict by trying to_array() first.
	# Empty lua table is ambiguous; default to Array since lua convention treats
	# `{}` as an empty list (tags = {}, outputs = {}, ...). Returning Dictionary
	# would surprise downstream code that expects iteration / PackedStringArray.
	if v.has_method("to_array") and v.has_method("to_dictionary"):
		var arr = v.to_array()
		if arr.size() > 0:
			var out_arr: Array = []
			for x in arr:
				out_arr.append(to_variant(x))
			return out_arr
		var dict = v.to_dictionary()
		if dict.is_empty():
			return []
		var out_dict: Dictionary = {}
		for k in dict.keys():
			out_dict[k] = to_variant(dict[k])
		return out_dict
	return v


static func to_string_array(t) -> Array[String]:
	var out: Array[String] = []
	for v in to_array(t):
		out.append(str(v))
	return out


static func to_float_array(t) -> Array[float]:
	var out: Array[float] = []
	for v in to_array(t):
		out.append(float(v))
	return out


# Lua 端 {r, g, b, a} 4 元素数组 → Color
static func to_color(t) -> Color:
	var arr := to_array(t)
	var r := float(arr[0]) if arr.size() > 0 else 1.0
	var g := float(arr[1]) if arr.size() > 1 else 1.0
	var b := float(arr[2]) if arr.size() > 2 else 1.0
	var a := float(arr[3]) if arr.size() > 3 else 1.0
	return Color(r, g, b, a)


# Lua 端 {{r,g,b,a}, {r,g,b,a}, ...} → Array[Color]
static func to_color_array(t) -> Array[Color]:
	var out: Array[Color] = []
	for inner in to_array(t):
		out.append(to_color(inner))
	return out


# GDScript 值递归转 lua 友好 (LuaTable / primitive)。给 affect 同步路径返 lua 时用。
# 与 ScriptExecutor._gd_to_lua 同语义，独立公开版本（避免循环依赖）。
static func to_lua(lua: LuaState, v: Variant) -> Variant:
	if v == null:
		return null
	var t := typeof(v)
	if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_STRING:
		return v
	if t == TYPE_DICTIONARY:
		var d: Dictionary = v as Dictionary
		var tbl := lua.create_table()
		for k in d.keys():
			tbl[str(k)] = to_lua(lua, d[k])
		return tbl
	if t == TYPE_ARRAY or t == TYPE_PACKED_STRING_ARRAY or t == TYPE_PACKED_INT32_ARRAY \
			or t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_FLOAT64_ARRAY:
		var arr: Array = Array(v)
		var tbl := lua.create_table()
		for i in arr.size():
			tbl.rawset(i + 1, to_lua(lua, arr[i]))  # lua 1-indexed
		return tbl
	# Object / Resource / 其他 → 原样保留（lua 端只作 token）
	return v
