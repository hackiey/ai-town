extends Node

# Autoload: PassiveSimulator
#
# 全局定时器 —— "被动反应"(计时转化:晾晒/发酵/将来魔咒…)的唯一推进点,单一写者。
# 取代了旧的 settle-on-access(查看/取出各算一次→逻辑散落易出 bug)。其它地方只读
# slot 当前值,不再自己结算。
#
# 每条被动反应自带 tick_seconds(写在 data/mechanics/crafting.lua 的反应表里),本节点
# 按每条反应各自的下次触发时间调度:慢反应(酿酒 3600s)不被高频扫,快反应(将来魔咒
# 30s)也能秒级跳,互不拖累。
#
# 进行中的 slot 复用既有三字段 transform_age / transform_settle_hour / ferment_ceiling
# (无新增 DB 列);反应身份按成品 output 区分(各反应只推进自己 output 的 slot)。品质
# 0→ceiling 的爬升与"到点定格"逻辑在 lua(ramp_quality / run_tick),GD 只累计 age +
# 写回 + 持久化。设计见 docs/architecture/reaction-schema.md §8.2。

const _MECH := "crafting"

# 从 lua 一次性读出的被动反应静态数据 + 调度状态。每项:
# {id, auto_start, tick_seconds, hours, output, yield, vessel_tag, match_input, _next_fire}
var _reactions: Array = []


func _ready() -> void:
	if Engine.is_editor_hint() or not RunMode.is_runtime():
		set_process(false)
		return
	_load_reactions()
	set_process(not _reactions.is_empty())


func _load_reactions() -> void:
	var raw: Variant = MechanicHost.query(_MECH, "passive_reactions", [])
	if raw == null:
		return
	for row_v in LuaConv.to_array(raw):
		var r := LuaConv.to_dict(row_v)
		# 错峰首发,避免开服同一帧全扫(各反应下次触发 = now + 自己的 tick_seconds)
		r["_next_fire"] = GameClock.game_seconds + float(r.get("tick_seconds", 3600))
		_reactions.append(r)


func _process(_dt: float) -> void:
	var now_sec := GameClock.game_seconds
	for r in _reactions:
		if now_sec >= float(r.get("_next_fire", 0.0)):
			_fire(r, now_sec)
			r["_next_fire"] = now_sec + float(r.get("tick_seconds", 3600))


# 推进一条反应:扫它名下"进行中"的 slot 各推一步,并(若 auto_start)给新匹配的 slot 起头。
# 宿主三类:容器节点内容 / 角色背包 / 地面物品。各自就地改 slot + 持久化。
func _fire(r: Dictionary, now_sec: float) -> void:
	var now_hours := now_sec / GameClock.SECONDS_PER_GAME_HOUR
	var tree := get_tree()
	if tree == null:
		return

	# 1) 容器节点(含晾晒架/酒桶仓库)——passive_tags 提供 vessel 能力
	for node in tree.get_nodes_in_group("containers"):
		var cnode := node as ContainerNode
		if cnode == null:
			continue
		var slots: Array[Dictionary] = cnode.contents
		var cid := cnode.effective_container_id()
		var changed := false
		for i in slots.size():
			if _process_slot(r, slots[i], cnode.passive_tags, now_hours):
				Db.save_container_slot(cid, i, slots[i])
				changed = true
		if changed:
			cnode.contents = slots

	# 2) 角色背包(NPC + 玩家)——背包无 vessel 能力,只靠 item 自身 tag(如 brewing_vessel)
	for grp in ["npcs", "players"]:
		for node in tree.get_nodes_in_group(grp):
			var ch := node as Character
			if ch == null:
				continue
			var inv: Array[Dictionary] = ch.inventory
			var ch_changed := false
			for i in inv.size():
				if _process_slot(r, inv[i], PackedStringArray(), now_hours):
					ch.inventory_ops().persist_slot(i)
					ch_changed = true
			if ch_changed:
				ch.inventory = ch.inventory  # 触发 setter/同步

	# 3) 地面物品
	for node in tree.get_nodes_in_group("ground_items"):
		var gi := node as GroundItem
		if gi == null:
			continue
		if _process_slot(r, gi.slot_data, PackedStringArray(), now_hours):
			Db.save_ground_item(gi.db_id, gi.item_id, gi.global_position, gi.slot_data)


# 对单个 slot 跑反应 r:进行中→推一步;未开始且 r.auto_start 且匹配→起头。返回是否改动。
func _process_slot(r: Dictionary, slot: Dictionary, host_tags: PackedStringArray, now_hours: float) -> bool:
	var view := InventorySlotData.of(slot)
	if view.is_empty():
		return false
	var in_progress: bool = slot.get("transform_age", null) != null and slot.get("ferment_ceiling", null) != null
	if in_progress:
		# 反应只推进自己成品 output 的 slot(液体看 content、离散看 item_id),避免互相串台。
		var output_id := view.id()
		var cont := view.as_container()
		if cont != null and not cont.is_empty():
			output_id = cont.content_id()
		if str(r.get("output", "")) != output_id:
			return false
		return _advance(r, slot, now_hours)
	# 未开始:只有 auto_start 反应(晾晒)会自动起头;发酵由 brew 动作起头。
	if not bool(r.get("auto_start", false)):
		return false
	if view.id() != str(r.get("match_input", "")):
		return false
	if not _vessel_ok(r, host_tags, view):
		return false
	return _start_ramp(r, slot, now_hours)


# 推进:累计 age(含 catch-up:now - 上次结算),交反应的 on_tick 算品质/是否完成,写回。
func _advance(r: Dictionary, slot: Dictionary, now_hours: float) -> bool:
	var settled := float(slot.get("transform_settle_hour", now_hours))
	var age := float(slot.get("transform_age", 0.0)) + maxf(0.0, now_hours - settled)
	var ceiling := int(slot.get("ferment_ceiling", 0))
	var ctx := {"ceiling": ceiling, "age": age, "hours": float(r.get("hours", 0.0))}
	var patch_v: Variant = MechanicHost.query(_MECH, "run_tick", [str(r.get("id", "")), ctx])
	var patch := LuaConv.to_dict(patch_v) if patch_v != null else {}
	slot["quality"] = int(patch.get("quality", ceiling))
	if bool(patch.get("done", false)):
		slot["transform_age"] = null
		slot["transform_settle_hour"] = null
		slot["ferment_ceiling"] = null
	else:
		slot["transform_age"] = age
		slot["transform_settle_hour"] = now_hours
	return true


# 起头(晾晒):输入物立刻变身成 output(品质0、数量×yield),上限=输入品质,开始爬升。
func _start_ramp(r: Dictionary, slot: Dictionary, now_hours: float) -> bool:
	var input_quality := InventorySlotData.of(slot).quality()
	var old_qty := int(slot.get("quantity", 0))
	var yield_qty := maxi(1, int(r.get("yield", 1)))
	var swapped := InventorySlotData.from_template(str(r.get("output", "")), 0)
	swapped["quantity"] = maxi(1, old_qty) * yield_qty
	slot.clear()
	for k in swapped:
		slot[k] = swapped[k]
	slot["transform_age"] = 0.0
	slot["transform_settle_hour"] = now_hours
	slot["ferment_ceiling"] = input_quality
	InventorySlotData.normalize(slot)
	return true


# vessel 能力匹配:宿主容器 passive_tags 或 item 自身 tag 命中即可(统一晾晒看宿主、发酵看物品)。
func _vessel_ok(r: Dictionary, host_tags: PackedStringArray, view: InventorySlotData) -> bool:
	var want := str(r.get("vessel_tag", ""))
	if want.is_empty():
		return true
	return host_tags.has(want) or view.has_tag(want)
