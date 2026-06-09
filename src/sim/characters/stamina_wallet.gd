class_name StaminaWallet

# 体力扣/给的唯一入口。所有 runner 和 effect 必经此处。
#
# 设计：cost 的"产生"在 lua mechanic 层（crafting/crops/mining/well），
# cost 的"消费"在这里。Runner 只负责 wiring，不持有数字也不持有 spend 逻辑。
# 这样新增一条 reaction / farm action / 动作类型时，runner 不变，cost 自动从 mechanic
# 流过来，不可能"漏扣"——commit 路径写死调 try_spend(result.stamina_cost)。
#
# 唯一允许 bypass wallet 直接写 character.stamina 的场景：
#   1. 初始化（character.gd _ready：stamina = max_stamina）
#   2. DB 反序列化（character.gd hydrate：stamina = row.stamina）
#   3. NPC 启动唤醒重置（npc.gd _maybe_wake_from_boot：stamina = effective_cap）
# 这些是 lifecycle 而不是 gameplay mutation。其他任何地方写 stamina 都视为 bug。
#
# Reason 字符串纯做日志/telemetry：
#   "craft:mill_grind" / "farm:plant" / "mining:attempt" / "well:draw" / "effect:..."
#
# Hunger 联动：每消耗 1 stamina 额外掉 HUNGER_PER_STAMINA hunger。体力活越重越饿。
# 物理意义：stamina 是肌肉燃料，主动消耗时身体把食物能量转过去；自然回血（grant）不收费。
# 阈值检查走 physiology.on_slow_tick，最多滞后一个 tick (~10 game-min)，可接受。

const HUNGER_PER_STAMINA: float = 0.1


static func can_afford(character, cost: float) -> bool:
	if cost <= 0.0:
		return true
	return character.stamina + 0.0001 >= cost


# 扣体力。cost <= 0 视为 no-op（返回 ok=true）；不够返回 stamina_depleted；够则扣并 persist。
# 返回 dict 字段：{ok, code?, message?, stamina_cost, stamina_before, stamina_after, reason }
static func try_spend(character, cost: float, reason: String) -> Dictionary:
	if cost < 0.0:
		push_warning("[StaminaWallet] negative cost rejected (%s): %.2f" % [reason, cost])
		return _result_ok(character, 0.0, character.stamina, reason)
	if cost <= 0.0:
		return _result_ok(character, 0.0, character.stamina, reason)
	# 负重惩罚：背得越重，同一动作越费体力（倍率与负重平滑成比例）。所有体力扣点必经此处，单点生效。
	if character.has_method("carry_ratio"):
		cost *= Impairment.encumber_stamina_mult(character.carry_ratio())
	if character.stamina + 0.0001 < cost:
		return {
			"ok": false,
			"code": "stamina_depleted",
			"message": _fmt("error.stamina.not_enough_format", [reason, cost, character.stamina]),
			"stamina_cost": cost,
			"stamina_before": character.stamina,
			"stamina_after": character.stamina,
			"stamina_current": character.stamina,
			"reason": reason,
		}
	var before: float = character.stamina
	character.stamina = clampf(before - cost, 0.0, character.max_stamina)
	var hunger_cost: float = cost * HUNGER_PER_STAMINA
	if hunger_cost > 0.0 and "hunger" in character:
		character.hunger = clampf(character.hunger - hunger_cost, 0.0, character.max_hunger)
	if character.has_method("_persist_state"):
		character.call("_persist_state")
	return _result_ok(character, cost, before, reason)


# 给体力（regen / 食物效果 / 睡眠）。上限是 character.max_stamina，physiology 的动态 cap
# 在调用方算好后传 max_cap；为 0 时走 max_stamina。
static func grant(character, amount: float, reason: String, max_cap: float = -1.0) -> Dictionary:
	if amount < 0.0:
		push_warning("[StaminaWallet] negative grant rejected (%s): %.2f" % [reason, amount])
		return _result_ok(character, 0.0, character.stamina, reason)
	if amount <= 0.0:
		return _result_ok(character, 0.0, character.stamina, reason)
	var cap: float = character.max_stamina if max_cap <= 0.0 else max_cap
	var before: float = character.stamina
	character.stamina = clampf(before + amount, 0.0, cap)
	if character.has_method("_persist_state"):
		character.call("_persist_state")
	return _result_ok(character, character.stamina - before, before, reason)


static func _result_ok(character, spent: float, before: float, reason: String) -> Dictionary:
	return {
		"ok": true,
		"stamina_cost": spent,
		"stamina_before": before,
		"stamina_after": character.stamina,
		"reason": reason,
	}


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key


static func _fmt(key: String, args: Array) -> String:
	return _msg(key) % args
