class_name FarmingHandlers
extends RefCounted

# farming（瞬时）：plant_seed / water_crop / harvest_crop / remove_pest。
# 由 BackendActionRunner.start() 在识别为 farming action 后调 resolve(...)；
# 返回 {ok, message?, event?: {type, data}}。dispatcher 拿到后负责 emit_world_event +
# runner.finish。handler 自身无副作用（除了 character 本体动作如 try_plant_seed_facing 内部）。


static func resolve(character: Character, action_request: Dictionary) -> Dictionary:
	var action := str(action_request.get("action", ""))
	var target: Variant = action_request.get("target", {})
	var result := _run_farming_action(character, action, target)
	if not bool(result.get("ok", false)):
		return {"ok": false, "message": str(result.get("message", _msg("error.farm.action_failed")))}

	var actor_id := character.backend_character_id()
	var target_dict: Dictionary = target as Dictionary if typeof(target) == TYPE_DICTIONARY else {}
	# Wire contract: backend per-type renderer (event-descriptions/farming.ts) reads
	# target/result fields. Do not pass prose here.
	var event_data := {
		"actorId": actor_id,
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"target": target_dict,
		"result": result,
	}
	return {
		"ok": true,
		"event": {"type": action, "data": event_data},
	}


static func _run_farming_action(character: Character, action: String, target: Variant) -> Dictionary:
	match action:
		"plant_seed":
			var seed_id := _seed_id_from_target(target)
			if seed_id.is_empty():
				return {"ok": false, "message": "plant_seed target.seed is empty"}
			return character.farm_actions().try_plant_seed_facing(seed_id)
		"water_crop":
			return character.farm_actions().try_water_facing()
		"harvest_crop":
			return character.farm_actions().try_harvest_facing()
		"remove_pest":
			return character.farm_actions().try_remove_pest_facing()
		_:
			return {"ok": false, "message": "unsupported farming action: %s" % action}


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


static func _seed_id_from_target(target: Variant) -> String:
	# Wire contract: farming sub-actions (plant_seed/etc) are only invoked via
	# plan_farm_work queue; each op carries seedItemId. Direct LLM calls have no tool factory.
	if typeof(target) == TYPE_DICTIONARY:
		return str((target as Dictionary).get("seedItemId", ""))
	return ""
