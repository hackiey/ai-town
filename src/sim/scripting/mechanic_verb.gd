class_name MechanicVerb

# Backend action verb → lua mechanic 的统一 wrapper（Q4 决议，plan §4.2）。
#
# 目的：让 backend_action_runner._run_<verb> 退化成 5 行：
#   func _run_buy_from_shelf(req):
#       return MechanicVerb.resolve("buy_from_shelf", { actor, shelf, item_id, quantity })
#
# 责任：
#   1) 调 MechanicHost.invoke(verb_name, "on_resolve", ctx)
#   2) Normalize 返回（拒绝/通过/payload）
#   3) 自动 world_event 上行（如果 lua return 里包含 world_event 字段）
#
# Lua 约定（mechanic 文件 data/mechanics/<verb_name>.lua 实现 on_resolve(ctx)）:
#   通过：return { ok=true, message="...", result={...}?, world_event={event_type, text, data}? }
#   拒绝：return { ok=false, message="..." }
#   或非空 string → 当 reject 原因（兼容 speech.lua 的简单返回风格）
#
# Crafting / Speech 不走这条 —— 它们 lifecycle 不同（前者两阶段，后者纯广播）。


static func resolve(verb_name: String, ctx: Dictionary, hook: String = "on_resolve") -> Dictionary:
	if not MechanicHost.has_mechanic(verb_name):
		return { "ok": false, "message": _fmt("error.mechanic.verb_unregistered_format", [verb_name]) }

	var invoke_result := MechanicHost.invoke(verb_name, hook, ctx)
	if not bool(invoke_result.get("ok", false)):
		# Lua 解析错误 / hook 不存在 / lua 端 return 非空 string
		return {
			"ok": false,
			"message": str(invoke_result.get("error", "verb rejected")),
		}

	var rv: Variant = invoke_result.get("return_value", null)
	# Lua hook 没显式 return → 当 ok 处理（已经走完所有 affect）
	if rv == null:
		return { "ok": true, "message": "" }

	# Lua return 是 dict 形式
	if rv is Dictionary:
		var ret: Dictionary = rv as Dictionary
		var ok := bool(ret.get("ok", true))
		var message := str(ret.get("message", ""))
		if not ok:
			return { "ok": false, "message": message }
		# 自动 world_event：lua 不需要直接调 affect.world_event，return 里塞一份就够。
		# Lua 端不要再写 world_event.text —— 自然语言由 backend per-type renderer 渲染。
		var we: Variant = ret.get("world_event", null)
		if we is Dictionary:
			var we_dict: Dictionary = we as Dictionary
			var event_type := str(we_dict.get("event_type", ""))
			if not event_type.is_empty():
				var event_data := _event_data_with_default_visibility(
					(we_dict.get("data", {}) as Dictionary) if we_dict.get("data") is Dictionary else {},
					ctx
				)
				_emit_world_event(event_type, event_data)
		var out := { "ok": true, "message": message }
		if ret.has("result"):
			out["result"] = ret["result"]
		return out

	# 不识别的返回类型（比如 lua 直接 return 一个数字 / array）
	return {
		"ok": true,
		"message": str(rv),
	}


static func _emit_world_event(event_type: String, data: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var backend := tree.root.get_node_or_null("BackendRuntimeClient")
	if backend == null or not backend.has_method("send_world_event"):
		return
	backend.call("send_world_event", event_type, data)


static func _event_data_with_default_visibility(data: Dictionary, ctx: Dictionary) -> Dictionary:
	# 契约：data 必须带 actorId / affectedCharacterIds。lua mech 漏写时这里兜一个默认值，
	# 但不再做 snake/camel 别名合并 —— canonical 见 backend/src/godot-link/world-events.ts。
	var out := data.duplicate(true)
	if not out.has("actorId") and ctx.has("actor_id"):
		out["actorId"] = str(ctx.get("actor_id", ""))
	if out.has("affectedCharacterIds"):
		return out
	var actor: Variant = ctx.get("actor", null)
	if actor is Object and (actor as Object).has_method("voice_affected_character_ids"):
		out["affectedCharacterIds"] = (actor as Object).call("voice_affected_character_ids", "far")
	else:
		out["affectedCharacterIds"] = []
	return out


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


static func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
