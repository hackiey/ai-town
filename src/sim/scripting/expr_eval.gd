class_name ExprEval

# 表达式求值器（reaction-schema.md §4.5b）。递归下降，沙箱：只读 vars，只支持
#   数字字面量、@变量路径、+ - * /、一元负号、括号、min/max/clamp 三个函数。
# 变量路径：@power → vars["power"]；@target.hp → 读属性/键；@input[0].quality → 索引 + 键；
# 路径中途遇到 String 当成 material id 自动 Materials 查（@x.materials.body.hardness）。
# 用法：ExprEval.eval("-8 - 12 * @power", {"power": 1.4}) -> -24.8
# 调用方先判：String 且（以 @ 开头 或 含运算符）才送进来；纯字面量直接用，不必进求值器。

static func eval(formula: String, vars: Dictionary) -> float:
	var p := _Parser.new(formula, vars)
	var v := p.parse()
	if not p.error.is_empty():
		push_error("[ExprEval] '%s': %s" % [formula, p.error])
		return 0.0
	return v


static func is_expression(v: Variant) -> bool:
	if typeof(v) != TYPE_STRING:
		return false
	var s := (v as String).strip_edges()
	if s.is_empty():
		return false
	return s.begins_with("@") or s.contains("@") \
		or s.contains("+") or s.contains("-") or s.contains("*") or s.contains("/") \
		or s.contains("(")


class _Parser:
	var _vars: Dictionary
	var _toks: Array = []      # 每项 {t: "num"|"var"|"id"|"op", v}
	var _i: int = 0
	var error: String = ""

	func _init(src: String, vars: Dictionary) -> void:
		_vars = vars
		_tokenize(src)

	func _tokenize(src: String) -> void:
		var n := src.length()
		var i := 0
		while i < n:
			var c := src[i]
			if c == " " or c == "\t" or c == "\n":
				i += 1
				continue
			if c == "@":
				var j := i + 1
				while j < n and (_is_path_char(src[j])):
					j += 1
				_toks.append({"t": "var", "v": src.substr(i + 1, j - i - 1)})
				i = j
				continue
			if _is_alpha(c):
				var j := i
				while j < n and _is_alpha(src[j]):
					j += 1
				_toks.append({"t": "id", "v": src.substr(i, j - i)})
				i = j
				continue
			if _is_digit(c) or c == ".":
				var j := i
				while j < n and (_is_digit(src[j]) or src[j] == "."):
					j += 1
				_toks.append({"t": "num", "v": src.substr(i, j - i).to_float()})
				i = j
				continue
			if c in ["+", "-", "*", "/", "(", ")", ","]:
				_toks.append({"t": "op", "v": c})
				i += 1
				continue
			error = "unexpected char '%s'" % c
			return

	func _is_digit(c: String) -> bool:
		return c >= "0" and c <= "9"

	func _is_alpha(c: String) -> bool:
		return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"

	func _is_path_char(c: String) -> bool:
		return _is_alpha(c) or _is_digit(c) or c == "." or c == "[" or c == "]"

	func _peek() -> Dictionary:
		return _toks[_i] if _i < _toks.size() else {}

	func _next() -> Dictionary:
		var t := _peek()
		_i += 1
		return t

	func _is_op(t: Dictionary, op: String) -> bool:
		return t.get("t", "") == "op" and str(t.get("v", "")) == op

	func parse() -> float:
		var v := _expr()
		if error.is_empty() and _i != _toks.size():
			error = "trailing tokens"
		return v

	func _expr() -> float:
		var v := _term()
		while error.is_empty() and (_is_op(_peek(), "+") or _is_op(_peek(), "-")):
			var op := str(_next()["v"])
			var r := _term()
			v = v + r if op == "+" else v - r
		return v

	func _term() -> float:
		var v := _factor()
		while error.is_empty() and (_is_op(_peek(), "*") or _is_op(_peek(), "/")):
			var op := str(_next()["v"])
			var r := _factor()
			v = v * r if op == "*" else (v / r if r != 0.0 else 0.0)
		return v

	func _factor() -> float:
		var t := _peek()
		if t.is_empty():
			error = "unexpected end"
			return 0.0
		if _is_op(t, "-"):
			_next()
			return -_factor()
		if _is_op(t, "("):
			_next()
			var v := _expr()
			if not _is_op(_peek(), ")"):
				error = "expected ')'"
				return 0.0
			_next()
			return v
		match str(t.get("t", "")):
			"num":
				_next()
				return float(t["v"])
			"var":
				_next()
				return _resolve(str(t["v"]))
			"id":
				return _call_func()
		error = "unexpected token"
		return 0.0

	func _call_func() -> float:
		var name := str(_next()["v"])
		if not _is_op(_peek(), "("):
			error = "expected '(' after %s" % name
			return 0.0
		_next()
		var args: Array[float] = []
		if not _is_op(_peek(), ")"):
			args.append(_expr())
			while _is_op(_peek(), ","):
				_next()
				args.append(_expr())
		if not _is_op(_peek(), ")"):
			error = "expected ')' in %s()" % name
			return 0.0
		_next()
		match name:
			"min":
				if args.size() != 2:
					error = "min() takes 2 args"; return 0.0
				return minf(args[0], args[1])
			"max":
				if args.size() != 2:
					error = "max() takes 2 args"; return 0.0
				return maxf(args[0], args[1])
			"clamp":
				if args.size() != 3:
					error = "clamp() takes 3 args"; return 0.0
				return clampf(args[0], args[1], args[2])
		error = "unknown function '%s'" % name
		return 0.0

	# @path → 值。path 例：power / target.hp / input[0].materials.body.hardness
	func _resolve(path: String) -> float:
		var segs := _split_path(path)
		if segs.is_empty():
			error = "empty var path"
			return 0.0
		var cur: Variant = _vars.get(str(segs[0]), null)
		for k in range(1, segs.size()):
			cur = _step(cur, segs[k])
			if not error.is_empty():
				return 0.0
		if cur == null:
			error = "var '@%s' is null" % path
			return 0.0
		return float(cur)

	func _step(cur: Variant, seg: Variant) -> Variant:
		if typeof(seg) == TYPE_INT:
			if cur is Array:
				return (cur as Array)[int(seg)]
			error = "index on non-array"
			return null
		var field := str(seg)
		if cur is Dictionary:
			return (cur as Dictionary).get(field, null)
		if cur is String:
			# material id 自动 deref（@x.materials.body.<field>）
			var m: Substance = Materials.by_id(cur as String)
			return m.get_field(field) if m != null else null
		if cur is Object:
			return (cur as Object).get(field)
		error = "cannot read '.%s'" % field
		return null

	# "input[0].materials.body" → ["input", 0, "materials", "body"]
	func _split_path(path: String) -> Array:
		var out: Array = []
		var buf := ""
		var i := 0
		var n := path.length()
		while i < n:
			var c := path[i]
			if c == ".":
				if not buf.is_empty():
					out.append(buf); buf = ""
				i += 1
			elif c == "[":
				if not buf.is_empty():
					out.append(buf); buf = ""
				var j := path.find("]", i)
				if j < 0:
					error = "unclosed '['"; return out
				out.append(int(path.substr(i + 1, j - i - 1)))
				i = j + 1
			else:
				buf += c
				i += 1
		if not buf.is_empty():
			out.append(buf)
		return out
