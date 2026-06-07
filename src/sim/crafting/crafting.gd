class_name Crafting

# Crafting dispatcher 的 GDScript 入口。
# 真值（reaction 数据 + 匹配 / 失败 / quality / 派生 / 输出）住在 data/mechanics/crafting.lua。
# 这里做：
#   1. 把 ctx 转给 lua 的 on_resolve hook
#   2. 把 lua 返回值（dict）后处理：根据 reaction_id + fail_mode_idx 翻译 fail_mode_name /
#      message i18n 字符串，让下游 UI / world_event 直接读 result.fail_mode_name / .message
#
# 调用方：workstation_action_runner.gd / player.gd

static func resolve(verb: String, workstation_id: String, sub_option: String, inputs: Array, proficiency: Dictionary = {}, work_impair: float = 0.0) -> Dictionary:
	var inv := MechanicHost.invoke("crafting", "on_resolve", {
		"verb": verb,
		"workstation_id": workstation_id,
		"sub_option": sub_option,
		"inputs": inputs,
		"proficiency": proficiency,
		# 醉酒/生病：执行时临时压低有效熟练度（不写回存储值）。lua on_resolve 在取到 p 后减。
		"work_impair": work_impair,
	})
	if not bool(inv.get("ok", false)):
		return _no_match("crafting on_resolve failed: %s" % str(inv.get("error", "")))
	var result_v: Variant = inv.get("return_value")
	if not (result_v is Dictionary):
		return _no_match("crafting on_resolve returned non-dict (lua error?)")
	var result: Dictionary = result_v as Dictionary

	var outcome := str(result.get("outcome", "no_match"))
	if outcome == "no_match":
		result["fail_mode_name"] = ""
		result["message"] = _no_match_message(str(result.get("no_match_reason", "")))
	elif outcome == "failure":
		var rid := str(result.get("reaction_id", ""))
		var idx := int(result.get("fail_mode_idx", -1))
		result["fail_mode_name"] = _failure_label(rid, idx)
		result["message"] = _failure_message(rid, idx)
	else:
		result["fail_mode_name"] = ""
		result["message"] = ""
	return result


static func _no_match(msg: String) -> Dictionary:
	return {
		"ok": false,
		"outcome": "no_match",
		"outputs": [],
		"consumed_input_indices": [],
		"returned_input_indices": [],
		"fail_mode_name": "",
		"message": msg,
		"reaction_id": "",
		"duration_seconds": 0.0,
		"stamina_cost": 0.0,
	}


static func _no_match_message(reason: String) -> String:
	if reason == "ws_verb":
		return "这个工作台干不了这种活"
	return "摆弄了一阵，这堆东西凑不出什么名堂"


static func _failure_label(reaction_id: String, idx: int) -> String:
	# 所有 crafting 失败统一标"熟练度不够" —— 失败本质就是 skill check 没过，
	# 不再用 reaction.X.failure.fN.name 这套（从来没人填）做艺术化别名。
	# Mining 失败走自己的 ui.mine.fail_label（"空铲"，由 mining runner 直接覆盖）。
	if reaction_id.is_empty():
		return ""
	return TranslationServer.translate("ui.craft.fail_label")


static func _failure_message(reaction_id: String, idx: int) -> String:
	return TranslationServer.translate("ui.craft.failure_default")
