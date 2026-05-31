class_name Farming

# Farming dispatcher 的 GDScript 入口（镜像 Crafting）。
# 真值在 data/mechanics/crops.lua 的 on_action_cost(ctx) hook。
#
# Runner 通过此处拿动作开销，再交给 StaminaWallet 扣体力 / FarmActionRunner 设 working 时长。
# 任何动作开销改动都改 lua，不要在 GDScript 写常量。

const _ZERO := {"stamina_cost": 0.0, "duration_seconds": 0.0}


# kind ∈ {"plant", "harvest", "uproot", "pest", "water"}
# 返回 {stamina_cost, duration_seconds}；未知 kind 返回 0/0。
static func resolve_action_cost(kind: String) -> Dictionary:
	var inv := MechanicHost.invoke("crops", "on_action_cost", {"kind": kind})
	if not bool(inv.get("ok", false)):
		push_warning("[Farming] on_action_cost failed (%s): %s" % [kind, inv.get("error", "")])
		return _ZERO
	var rv: Variant = inv.get("return_value")
	if not (rv is Dictionary):
		push_warning("[Farming] on_action_cost returned non-dict for %s" % kind)
		return _ZERO
	var d: Dictionary = rv as Dictionary
	return {
		"stamina_cost": float(d.get("stamina_cost", 0.0)),
		"duration_seconds": float(d.get("duration_seconds", 0.0)),
	}
