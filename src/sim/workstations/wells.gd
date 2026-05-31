class_name Wells

# Well dispatcher 的 GDScript 入口（镜像 Crafting / Farming）。
# 真值在 data/mechanics/well.lua 的 on_draw_cost() hook。
#
# Water = bucket.properties 原地填充，不是 item 变换，所以走不了 crafting reaction 模型；
# well 单独一个 mechanic 文件。这里只暴露 cost 查询，runner 自己持有 inventory mutation
# 逻辑（_check_well_draw / _try_well_draw）。

const _ZERO := {"stamina_cost": 0.0, "duration_seconds": 0.0}


static func draw_cost() -> Dictionary:
	var inv := MechanicHost.invoke("well", "on_draw_cost", {})
	if not bool(inv.get("ok", false)):
		push_warning("[Wells] on_draw_cost failed: %s" % inv.get("error", ""))
		return _ZERO
	var rv: Variant = inv.get("return_value")
	if not (rv is Dictionary):
		push_warning("[Wells] on_draw_cost returned non-dict")
		return _ZERO
	var d: Dictionary = rv as Dictionary
	return {
		"stamina_cost": float(d.get("stamina_cost", 0.0)),
		"duration_seconds": float(d.get("duration_seconds", 0.0)),
	}
