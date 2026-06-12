class_name HusbandryHandlers

# tend_animal backend action：NPC 用 LLM tool 喂养 / 宰杀牲畜。逻辑走 Character.husbandry()
# ——与玩家 UI 完全同一执行点（见 [[feedback_player_npc_same_character]]）。
#
# Godot 是权威（见 [[feedback_godot_is_authority]]）：tool 只带 species（NPC 没法给每头动物
# 起人类名字），这里在场景里找最近的同物种活牲畜，交给 husbandry_runner 做交互半径 /
# 活着 / 是否牲畜的 fail-closed 校验。找不到 / 太远 → 返回明确错误给 agent。
#
# 注：当前是即时动作，不自动走到动物旁——NPC 需自己先靠近（自主感知 + 走向动物属后续
# 的畜牧 perception 集成）。


static func run_tend_animal(character: Character, action_request: Dictionary) -> Dictionary:
	var target_v: Variant = action_request.get("target", {})
	if typeof(target_v) != TYPE_DICTIONARY:
		return {"ok": false, "message": "tend_animal target must be object"}
	var target: Dictionary = target_v
	var verb := str(target.get("verb", ""))
	var species := str(target.get("species", "")).strip_edges().to_lower()
	if species.is_empty():
		return {"ok": false, "message": "tend_animal 缺 species"}
	var animal := _nearest_livestock(character, species)
	if animal == null:
		return {"ok": false, "message": "附近没有可畜牧的 %s" % species}
	match verb:
		"feed":
			return character.husbandry().feed(animal)
		"slaughter":
			return character.husbandry().slaughter(animal)
		_:
			return {"ok": false, "message": "未知畜牧操作: %s" % verb}


static func _nearest_livestock(character: Character, species: String) -> Animal:
	var tree := character.get_tree()
	if tree == null:
		return null
	var best: Animal = null
	var best_d := INF
	for n in tree.get_nodes_in_group("animals"):
		var a := n as Animal
		if a == null or not a.alive or not a.is_livestock():
			continue
		if a.species_id != species:
			continue
		var d := character.global_position.distance_to(a.global_position)
		if d < best_d:
			best_d = d
			best = a
	return best
