class_name ItemEffects
extends RefCounted

# Item 使用效果的算法 + applicator。
# 三个 entry：
#   compute_displayed(view) -> Dictionary   计算最终数值 dict（lua 或默认公式）
#   apply_to_caster(caster, effects)        把 dict 应用到角色（hunger/stamina/hp/...）
#   recompute_slot(slot) -> Dictionary      把 displayed_effects 写回 slot；任何 mutator
#                                           （set_slot / decrement_tool_durability / generate）
#                                           改完字段后调一次，保证 displayed_effects 物理上
#                                           不可能漂移于 base_effects + quality + freshness。
#
# 设计参考 memory：
#   project_item_state_architecture     effects 数据流：base in instance + displayed cached
#   feedback_effects_lua_returns_dict   lua 只返回 dict，不再调 affect.*
#
# Lua compute_effects(ctx) 范式（仅特殊条件物品才写；常见的 base * q * f 留空走默认公式）：
#   function compute_effects(ctx)
#       if ctx.instance.freshness_tier == 1 then
#           return { hunger = 5, sickness = 1 }  -- 馊了致病
#       end
#       local q, f = ctx.quality_multiplier, ctx.freshness_multiplier
#       local out = {}
#       for k, v in pairs(ctx.instance.base_effects) do
#           out[k] = v * q * f
#       end
#       return out
#   end


# 算 view 当前的 displayed effects（不写 slot；caller 决定怎么用）。
# 流程：
#   item.source 有 compute_effects → 调 lua，覆盖默认公式
#   否则默认 base_effects * quality_multiplier * freshness_multiplier
# 没 base_effects（template 也没填）→ 返回 {}，caller 当作"无效果物"。
static func compute_displayed(view: InventorySlotData) -> Dictionary:
	var item := view.template()
	if item == null:
		return {}
	var base: Variant = view.slot.get("base_effects", null)
	if base == null:
		# 起始库存 / 没经过 reaction generate 的物品，slot 上没 base_effects；
		# 从 template 兜底（item.base_effects 是 .tres 配的）。
		base = item.base_effects
	if base == null or not (base is Dictionary):
		return {}
	var base_dict: Dictionary = base as Dictionary
	if base_dict.is_empty():
		return {}

	var quality := view.quality()
	var q_mul := QualityTier.multiplier(quality)
	var tier_v: Variant = view.slot.get("freshness_tier", null)
	var f_mul := 1.0 if tier_v == null else (float(int(tier_v)) / 5.0)

	# Lua override path
	var source := item.source.strip_edges()
	if not source.is_empty():
		var ctx := {
			"caster": null,  # compute 阶段不带 caster；lua 端只读 instance 不调 affect.*
			"item": item,
			"quality": quality,
			"quality_multiplier": q_mul,
			"freshness_multiplier": f_mul,
			"instance": {
				"quality": quality,
				"freshness_tier": tier_v,
				"freshness_age_hours": view.slot.get("freshness_age_hours", null),
				"base_effects": base_dict,
				"materials": view.materials(),
				"shape_type": view.shape_type(),
			},
		}
		var result := ScriptExecutor.execute(source, "compute_effects", ctx)
		if bool(result.get("ok", false)):
			var rv: Variant = result.get("return_value", null)
			if rv is Dictionary:
				return _coerce_number_dict(rv as Dictionary)
		# lua 没 compute_effects entry 或 runtime error → fall through 默认公式

	return _multiply_dict(base_dict, q_mul * f_mul)


# 把 effects dict 应用到 caster。借道 Effects.apply（同一份 mutator 逻辑，避免分叉）。
# 未知 key 只 push_warning 不崩——LLM 可能写错 key。
static func apply_to_caster(caster, effects: Dictionary) -> Array:
	var summaries: Array = []
	if caster == null:
		return summaries
	for k in effects.keys():
		var amount := float(effects[k])
		var key := str(k)
		var effect: Dictionary
		match key:
			"hunger":
				effect = {"type": "modify_hunger", "target": caster, "amount": amount}
			"stamina":
				effect = {"type": "modify_stamina", "target": caster, "amount": amount}
			"hp", "health":
				effect = {"type": "modify_hp", "target": caster, "amount": amount}
			"rest":
				effect = {"type": "modify_rest", "target": caster, "amount": amount}
			"drunk":
				# 醉酒累计值（啤酒等酒类 base_effects drunk:+N）。衰减/影响见 physiology.lua。
				effect = {"type": "modify_drunk", "target": caster, "amount": amount}
			"sickness":
				# 生病累计值。正 = 致病（吃馊食物），负 = 治疗（吃药）。0..MAX_IMPAIRMENT。
				effect = {"type": "modify_sickness", "target": caster, "amount": amount}
			_:
				push_warning("[ItemEffects] unknown effect key: %s" % key)
				continue
		var r := Effects.apply(effect)
		summaries.append(r)
	return summaries


# 写 slot.displayed_effects = compute_displayed(view)。返回 slot（in-place）。
# slot 为空 / template 缺失 / base_effects 为空 → displayed_effects = null。
static func recompute_slot(slot: Dictionary) -> Dictionary:
	var view := InventorySlotData.of(slot)
	if view.is_empty():
		slot["displayed_effects"] = null
		return slot
	var effects := compute_displayed(view)
	slot["displayed_effects"] = null if effects.is_empty() else effects
	return slot


# ── helpers ───────────────────────────────────────────────

static func _multiply_dict(d: Dictionary, factor: float) -> Dictionary:
	var out := {}
	for k in d.keys():
		out[str(k)] = float(d[k]) * factor
	return out


# Lua 返回值过一道：保证 value 都是数字（防 LLM 写错 string）。
static func _coerce_number_dict(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d.keys():
		var v: Variant = d[k]
		if v is int or v is float:
			out[str(k)] = float(v)
	return out
