class_name LiquidOps
extends RefCounted

# 液体/物质"份"模型的即时原语：
#  - transfer_between_slots(): 两个液体容器互倒，按量加权平均品质（含发酵态迁移）
#  - fill_from_source(): 从无限源（水井）灌进容器
#
# 单位：液体按"升"（=container_amount）；1 份水 = 1 升水。品质复用 slot.quality。
# 被动转换（晾晒/发酵的品质爬升与定格）不在这里——由 PassiveSimulator 全局定时器
# 单一写者推进（见 src/autoload/passive_simulator.gd + data/mechanics/crafting.lua）。
# 发酵态字段：ferment_ceiling（上限）/ transform_age（累计转化小时）/ transform_settle_hour。


# 当前 game 时间（小数小时）。
static func now_hours() -> float:
	return GameClock.game_seconds / GameClock.SECONDS_PER_GAME_HOUR


static func blend_quality(amt_a: float, q_a: float, amt_b: float, q_b: float) -> float:
	var total := amt_a + amt_b
	if total <= 0.0:
		return q_a
	return (q_a * amt_a + q_b * amt_b) / total


# 两个液体容器 slot 互倒 amount 升。原地改两个 slot。
# 同 content（或目标空）才行；品质按量加权平均；发酵态随液体迁移并按量混合。
# 返回 {ok, moved, message}。
static func transfer_between_slots(src_slot: Dictionary, dst_slot: Dictionary, amount: float) -> Dictionary:
	var src := InventorySlotData.of(src_slot).as_container()
	var dst := InventorySlotData.of(dst_slot).as_container()
	if src == null or dst == null:
		return {"ok": false, "moved": 0.0, "message": _msg("error.liquid.not_container")}
	if src.is_empty():
		return {"ok": false, "moved": 0.0, "message": _msg("error.liquid.source_empty")}
	var content := src.content_id()
	if not dst.is_empty() and dst.content_id() != content:
		return {"ok": false, "moved": 0.0, "message": _msg("error.liquid.incompatible_content")}
	var room := dst.capacity() - dst.amount()
	var move := minf(amount, minf(src.amount(), room))
	if move <= 0.0:
		return {"ok": false, "moved": 0.0, "message": _msg("error.liquid.no_room_or_source")}

	var dst_amt_before := dst.amount()
	var src_fermenting := src_slot.get("ferment_ceiling", null) != null
	_apply_pour(src_slot, dst_slot, content, src.quality(), move)
	# 发酵态迁移：源是发酵中的酒 → 目标也按量混合发酵进度。
	if src_fermenting:
		_blend_ferment_state(src_slot, dst_slot, dst_amt_before, move)
	return {"ok": true, "moved": move, "message": ""}


# 从无限源（水井）灌 amount 升 content（品质 src_quality）进 dst 容器。原地改 dst。
static func fill_from_source(dst_slot: Dictionary, content: String, src_quality: float, amount: float) -> Dictionary:
	var dst := InventorySlotData.of(dst_slot).as_container()
	if dst == null:
		return {"ok": false, "moved": 0.0, "message": _msg("error.liquid.not_container")}
	if not dst.is_empty() and dst.content_id() != content:
		return {"ok": false, "moved": 0.0, "message": _msg("error.liquid.incompatible_content")}
	var room := dst.capacity() - dst.amount()
	var move := minf(amount, room)
	if move <= 0.0:
		return {"ok": false, "moved": 0.0, "message": _msg("error.liquid.container_full")}
	var dfields := dst.with_blended(move, src_quality, content)
	dst_slot["container_amount"] = dfields["container_amount"]
	dst_slot["container_content"] = dfields["container_content"]
	dst_slot["quality"] = int(round(float(dfields["quality"])))
	return {"ok": true, "moved": move, "message": ""}


# ── 内部 ──────────────────────────────────────────────

static func _apply_pour(src_slot: Dictionary, dst_slot: Dictionary, content: String, src_quality: float, move: float) -> void:
	var dst := InventorySlotData.of(dst_slot).as_container()
	var dfields := dst.with_blended(move, src_quality, content)
	dst_slot["container_amount"] = dfields["container_amount"]
	dst_slot["container_content"] = dfields["container_content"]
	dst_slot["quality"] = int(round(float(dfields["quality"])))
	var src := InventorySlotData.of(src_slot).as_container()
	var sfields := src.with_consumed(move)
	src_slot["container_amount"] = sfields["container_amount"]
	src_slot["container_content"] = sfields["container_content"]
	# 源倒空 → 清发酵态
	if float(sfields["container_amount"]) <= 0.0:
		src_slot["transform_age"] = null
		src_slot["transform_settle_hour"] = null
		src_slot["ferment_ceiling"] = null


# 把源的发酵进度按量混入目标（目标可能本来空 / 也在发酵）。
# age 与 ceiling 都按"目标已有量 vs 新倒入量"加权平均，保持线性 ramp 一致。
static func _blend_ferment_state(src_slot: Dictionary, dst_slot: Dictionary, dst_amt_before: float, move: float) -> void:
	var src_age := float(src_slot.get("transform_age", 0.0))
	var src_ceiling := float(src_slot.get("ferment_ceiling", 100))
	var dst_age := float(dst_slot.get("transform_age", src_age))
	var dst_ceiling := float(dst_slot.get("ferment_ceiling", src_ceiling))
	dst_slot["transform_age"] = blend_quality(dst_amt_before, dst_age, move, src_age)
	dst_slot["ferment_ceiling"] = int(round(blend_quality(dst_amt_before, dst_ceiling, move, src_ceiling)))
	dst_slot["transform_settle_hour"] = now_hours()


static func _msg(key: String) -> String:
	var translated := str(TranslationServer.translate(key))
	return translated if not translated.is_empty() and translated != key else key
