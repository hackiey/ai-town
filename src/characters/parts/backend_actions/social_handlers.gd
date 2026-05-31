class_name SocialHandlers
extends RefCounted

# say_to：瞬时 fast tool，不占身体、不打断当前 body action。
# 由 BackendActionRunner.start() 顶部独立分支调，不走 _complete_instant_action。


static func run_say_to(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "error": "say_to target must be object"}
	var target_dict: Dictionary = target as Dictionary
	var text := str(target_dict.get("text", ""))
	var volume := str(target_dict.get("volume", "near"))
	var target_character_id := SpeechController.target_id_from_target(target_dict)
	if target_character_id.is_empty():
		return {"ok": false, "error": "say_to targetCharacterId is empty"}
	var speech := character.speech().emit_say(text, volume, target_character_id)
	if not bool(speech.get("ok", false)):
		return {"ok": false, "error": str(speech.get("error", "say_to failed"))}
	var affected: Array = speech.get("affected_ids", [])
	var heard_by: Array[String] = []
	for listener_id_v in affected:
		var listener_id := str(listener_id_v)
		if listener_id.is_empty() or listener_id == target_character_id:
			continue
		heard_by.append(listener_id)
	return {
		"ok": true,
		"result": {
			"targetCharacterId": target_character_id,
			"text": text,
			"volume": volume,
			"affectedCharacterIds": affected,
			"heardByCharacterIds": heard_by,
		},
	}
