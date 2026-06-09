class_name BrewHandlers
extends RefCounted

# 酿酒动作 = 给一个"被动发酵反应"起头。把装着基底液体(水)的酿酒桶(brewing_vessel)
# + 背包原料(麦芽) → 发酵中的酒。之后由 PassiveSimulator 全局定时器把品质从 0 爬到上限。
#
# 配方全在 data/mechanics/crafting.lua 的反应表(trigger=passive),本文件不含任何
# malt/beer/小时数/公式字面量——加新酒只改反应表。NPC `brew` 工具与玩家 request_brew
# 共用本函数(服务端权威)。
#
# action_request: { target = { barrel = Endpoint }, recipe = <reaction_id, 可选> }
#   Endpoint 同 put_take(backpack/node 里的酿酒桶 slot);recipe 省略 → DEFAULT_RECIPE。

const DEFAULT_RECIPE := "ferment_beer"


static func run_brew(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "brew target must be object"}
	var ep_v: Variant = (target as Dictionary).get("barrel", {})
	var ep := ContainerHandlers._resolve_liquid_endpoint(character, ep_v)
	if not bool(ep.get("ok", false)):
		return {"ok": false, "message": str(ep.get("message", _msg("error.brew.barrel_missing")))}

	var recipe_id := str(action_request.get("recipe", "")).strip_edges()
	if recipe_id.is_empty():
		recipe_id = DEFAULT_RECIPE
	var rec_v: Variant = MechanicHost.query("crafting", "passive_recipe", [recipe_id])
	if rec_v == null:
		return {"ok": false, "message": _msg("error.brew.recipe_missing")}
	var rec := LuaConv.to_dict(rec_v)

	var slot: Dictionary = ep["slot"]
	var view := InventorySlotData.of(slot)
	if not view.has_tag(str(rec.get("vessel_tag", ""))):
		return {"ok": false, "message": _msg("error.brew.not_vessel")}
	var c := view.as_container()
	if c == null or c.content_id() != str(rec.get("base_liquid", "")) or c.amount() <= 0.0:
		return {"ok": false, "message": _msg("error.brew.no_base_liquid")}
	if slot.get("ferment_ceiling", null) != null or slot.get("transform_age", null) != null:
		return {"ok": false, "message": _msg("error.brew.already_fermenting")}

	var liters := int(ceil(c.amount()))
	var per := maxi(1, int(rec.get("ingredient_per_liter", 1)))
	var need := liters * per
	var ingredient := str(rec.get("ingredient", ""))
	var have := character.inventory_ops().count_item(ingredient)
	if have < need:
		return {"ok": false, "message": _fmt("error.brew.ingredient_not_enough_format", [_item_name(ingredient), need, have])}

	var ext := character.inventory_ops().extract_item_id_across_stacks(ingredient, need)
	if not bool(ext.get("ok", false)):
		return {"ok": false, "message": _msg("error.brew.extract_failed")}
	var ingredient_quality := _avg_quality(ext.get("stacks", []))

	# 上限 = ferment_ceiling(熟练度, 配方难度, 原料品质)。公式在 crafting.lua,单一真值。
	var p := float(character.get_proficiency_table().get(str(rec.get("skill_id", "")), 0.0))
	var ceiling_v: Variant = MechanicHost.query("crafting", "ferment_ceiling", [p, float(rec.get("difficulty", 0)), ingredient_quality])
	var ceiling := int(ceiling_v) if ceiling_v != null else 0

	# 起头:基底液体立刻变身成成品酒(品质0),写发酵态;simulator 接手爬升。
	slot["container_content"] = str(rec.get("output", ""))
	slot["quality"] = 0
	slot["transform_age"] = 0.0
	slot["transform_settle_hour"] = LiquidOps.now_hours()
	slot["ferment_ceiling"] = ceiling
	(ep["commit"] as Callable).call()

	character.emit_world_event("brewed", {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"liters": liters,
		"ceiling": ceiling,
		"recipe": recipe_id,
		"content": str(rec.get("output", "")),
	})
	return {
		"ok": true,
		"message": _fmt("tool.tool_result.brew.started_format", [liters, ceiling, int(rec.get("hours", 0))]),
		"result": {"liters": liters, "ceiling": ceiling},
	}


# 抽取出的原料按数量加权平均品质 → 决定成品上限。
static func _avg_quality(stacks: Array) -> float:
	var total_q := 0.0
	var total_n := 0
	for s_v in stacks:
		if typeof(s_v) != TYPE_DICTIONARY:
			continue
		var n := int((s_v as Dictionary).get("quantity", 0))
		total_q += float((s_v as Dictionary).get("quality", 0)) * n
		total_n += n
	return total_q / float(total_n) if total_n > 0 else 0.0


static func _item_name(item_id: String) -> String:
	var key := "item.%s.name" % item_id
	var n := str(TranslationServer.translate(key))
	return n if n != key else item_id


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


static func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
