class_name Effects

# Effect 应用层。把脚本声明的 effect dict 应用到游戏状态。
#
# Effect dict 形状：{ type: String, ...payload }
# 当前支持的 type：
#   "modify_stamina":   { target: Character, amount: float }
#   "modify_hunger":    { target: Character, amount: float }
#   "modify_rest":      { target: Character, amount: float }
#   "modify_hp":        { target: Character, amount: float }
#   "remove_status": { target: Character, status_id: String }
#   "set_alive":        { target: Character, alive: bool } —— 翻转 alive；Character setter 做善后
#   "broadcast_speech": { speaker: Character, text, volume, target_id, affected_ids: Array }
#   "crop_state":       { crop: Crop, fields: Dictionary }
#   "farm_state":       { farm: FarmGroup, fields: Dictionary }
#   "crop_destroy":     { crop: Crop }
#   "give_item":        { receiver: Character, item_id: String, quantity: int, quality: int }
#                       → result.summary 携带 leftover/granted，调用方可从 raw_effects 读
#
# Inventory 套件 (take_item / transfer_item / set_slot_state) 是 **synchronous**，
# 不入此 dispatch —— 在 ScriptApi closure 里直接调 InventoryAdapter 并返回值给 lua。
#   "add_status":    { target: Character, status_id: String,
#                         expires_total_hours: int (0=永久), source: String }
#   "world_event":      { event_type: String, text: String, data: Dictionary }
#
# 加新 type：在 apply() match 里加 case，并在 ScriptApi 里加对应 affect.* 注入。

static func apply(effect: Dictionary) -> Dictionary:
	var type := str(effect.get("type", ""))
	match type:
		"modify_stamina":
			var target := effect.get("target") as Character
			var amount := float(effect.get("amount", 0.0))
			if target == null:
				return { "ok": false, "error": "modify_stamina: target is null" }
			var reason := str(effect.get("reason", "effect"))
			var result := StaminaWallet.grant(target, amount, reason) if amount >= 0.0 \
				else StaminaWallet.try_spend(target, -amount, reason)
			var delta := float(result.get("stamina_after", target.stamina)) - float(result.get("stamina_before", target.stamina))
			return {
				"ok": bool(result.get("ok", false)),
				"summary": "%s.stamina %+.1f → %.1f" % [target.name, delta, target.stamina],
			}
		"modify_hunger":
			var target := effect.get("target") as Character
			var amount := float(effect.get("amount", 0.0))
			if target == null:
				return { "ok": false, "error": "modify_hunger: target is null" }
			var before := target.hunger
			target.hunger = clampf(target.hunger + amount, 0.0, target.max_hunger)
			target.state_io().persist()
			return {
				"ok": true,
				"summary": "%s.hunger %+.1f → %.1f" % [target.name, target.hunger - before, target.hunger],
			}
		"modify_rest":
			var target := effect.get("target") as Character
			var amount := float(effect.get("amount", 0.0))
			if target == null:
				return { "ok": false, "error": "modify_rest: target is null" }
			var before := target.rest
			target.rest = clampf(target.rest + amount, 0.0, target.max_rest)
			target.state_io().persist()
			return {
				"ok": true,
				"summary": "%s.rest %+.1f → %.1f" % [target.name, target.rest - before, target.rest],
			}
		"modify_hp":
			var target := effect.get("target") as Character
			var amount := float(effect.get("amount", 0.0))
			if target == null:
				return { "ok": false, "error": "modify_hp: target is null" }
			var before := target.hp
			target.hp = clampf(roundf(target.hp + amount), 0.0, target.max_hp)
			target.state_io().persist()
			return {
				"ok": true,
				"summary": "%s.hp %+.0f → %.0f" % [target.name, target.hp - before, target.hp],
			}
		"modify_drunk":
			var target := effect.get("target") as Character
			var amount := float(effect.get("amount", 0.0))
			if target == null:
				return { "ok": false, "error": "modify_drunk: target is null" }
			var before := target.drunk
			target.drunk = clampf(target.drunk + amount, 0.0, Character.MAX_IMPAIRMENT)
			target.state_io().persist()
			return {
				"ok": true,
				"summary": "%s.drunk %+.1f → %.1f" % [target.name, target.drunk - before, target.drunk],
			}
		"modify_sickness":
			var target := effect.get("target") as Character
			var amount := float(effect.get("amount", 0.0))
			if target == null:
				return { "ok": false, "error": "modify_sickness: target is null" }
			var before := target.sickness
			target.sickness = clampf(target.sickness + amount, 0.0, Character.MAX_IMPAIRMENT)
			target.state_io().persist()
			return {
				"ok": true,
				"summary": "%s.sickness %+.1f → %.1f" % [target.name, target.sickness - before, target.sickness],
			}
		"remove_status":
			return _apply_remove_status(effect)
		"set_alive":
			return _apply_set_alive(effect)
		"broadcast_speech":
			return _apply_broadcast_speech(effect)
		"crop_state":
			return _apply_crop_state(effect)
		"farm_state":
			return _apply_farm_state(effect)
		"crop_destroy":
			return _apply_crop_destroy(effect)
		"give_item":
			return _apply_give_item(effect)
		"add_status":
			return _apply_add_status(effect)
		"world_event":
			return _apply_world_event(effect)
		_:
			return { "ok": false, "error": "unknown effect type: %s" % type }


# Speech 广播：RPC 给所有 client 显示气泡 + 上行 backend world event。
static func _apply_broadcast_speech(effect: Dictionary) -> Dictionary:
	var speaker := effect.get("speaker") as Character
	if speaker == null:
		return { "ok": false, "error": "broadcast_speech: speaker is null" }
	var text := str(effect.get("text", ""))
	var volume := str(effect.get("volume", "near"))
	var target_id := str(effect.get("target_id", ""))
	var affected_raw: Variant = effect.get("affected_ids", [])
	var affected: Array = []
	if affected_raw is Array:
		for v in (affected_raw as Array):
			affected.append(str(v))

	var character_id := speaker.backend_character_id()
	# Wire contract: SayToEventData (world-events.ts). Spoken words go on the
	# top-level spokenText field, not duplicated into data. Display name is
	# resolved by backend from actorId — never shipped, Godot has no locale.
	var event_data := {
		"actorId": character_id,
		"volume": volume,
		"affectedCharacterIds": affected,
	}
	if not target_id.is_empty():
		event_data["targetCharacterId"] = target_id

	# 气泡立刻弹（视觉反馈），world_event 同步上行——say_to 是瞬时 fast tool。
	# 节流（避免 NPC 互相 sensory 触发刷屏）由 backend tool handler 端处理。
	var affected_packed := PackedStringArray()
	for aid in affected:
		affected_packed.append(aid)
	speaker.show_speech.rpc(text, volume, target_id, affected_packed)

	var backend := speaker.get_node_or_null("/root/BackendRuntimeClient")
	if backend != null and backend.has_method("send_world_event"):
		backend.call("send_world_event", "say_to", event_data, text)

	return {
		"ok": true,
		"summary": "%s say (%s, target=%s, heard=%d)" % [character_id, volume, target_id, affected.size()],
	}


# Bulk-set crop fields. 任何 Crop 上声明的 var 都可以通过 fields 设置（setter 会触发 _apply_visual）。
# 末尾自动 persist_to_db（避免 lua 端关心持久化）。
static func _apply_crop_state(effect: Dictionary) -> Dictionary:
	var crop := effect.get("crop") as Crop
	if crop == null or not is_instance_valid(crop):
		return { "ok": false, "error": "crop_state: crop is null/freed" }
	var fields_v: Variant = effect.get("fields", {})
	if not fields_v is Dictionary:
		return { "ok": false, "error": "crop_state: fields must be Dictionary" }
	var fields: Dictionary = fields_v as Dictionary
	for k in fields.keys():
		crop.set(str(k), fields[k])
	if crop.has_method("persist_to_db"):
		crop.persist_to_db()
	return {
		"ok": true,
		"summary": "crop_state %s set %d fields" % [crop.name, fields.size()],
	}


# Bulk-set farm fields. 公共字段（moisture）走 setter；私有 _pest_count_today /
# _last_processed_day 通过 FarmGroup 暴露的 setter 走。末尾自动 persist。
static func _apply_farm_state(effect: Dictionary) -> Dictionary:
	var farm := effect.get("farm") as FarmGroup
	if farm == null or not is_instance_valid(farm):
		return { "ok": false, "error": "farm_state: farm is null/freed" }
	var fields_v: Variant = effect.get("fields", {})
	if not fields_v is Dictionary:
		return { "ok": false, "error": "farm_state: fields must be Dictionary" }
	var fields: Dictionary = fields_v as Dictionary
	for k in fields.keys():
		farm.set_mechanic_field(str(k), fields[k])
	farm.persist_mechanic_state()
	return {
		"ok": true,
		"summary": "farm_state %s set %d fields" % [farm.effective_farm_id(), fields.size()],
	}


static func _apply_crop_destroy(effect: Dictionary) -> Dictionary:
	var crop := effect.get("crop") as Crop
	if crop == null or not is_instance_valid(crop):
		return { "ok": false, "error": "crop_destroy: crop is null/freed" }
	var label := crop.variety_id
	crop.clear_from_db()
	crop.queue_free()
	return {
		"ok": true,
		"summary": "crop_destroy %s" % label,
	}


# 给角色背包加 item。返回 summary 含 granted/leftover；调用方可从 raw_effects 读 effect dict
# 自身（包含完整 payload）。
static func _apply_give_item(effect: Dictionary) -> Dictionary:
	var receiver := effect.get("receiver") as Character
	if receiver == null or not is_instance_valid(receiver):
		return { "ok": false, "error": "give_item: receiver is null/freed" }
	var item_id := str(effect.get("item_id", ""))
	var quantity := int(effect.get("quantity", 0))
	var quality := int(effect.get("quality", Character.ITEM_DEFAULT_QUALITY))
	if item_id.is_empty() or quantity <= 0:
		return { "ok": false, "error": "give_item: item_id empty or quantity <= 0" }
	var leftover := receiver.inventory_ops().add_item(item_id, quantity, quality)
	# stash 结果回 effect dict，方便调用方在 raw_effects 里读
	effect["_leftover"] = leftover
	effect["_granted"] = quantity - leftover
	return {
		"ok": true,
		"summary": "give_item %s x%d (q=%d) → %s, leftover=%d" % [item_id, quantity, quality, receiver.name, leftover],
	}


# 给角色挂 status。同 type 已存在 → 续期（取较晚的过期时间），不重复 append。
# expires_total_hours = 0 视为永久（never expire），存负数到 dict 表示永久。
static func _apply_add_status(effect: Dictionary) -> Dictionary:
	var target := effect.get("target") as Character
	if target == null or not is_instance_valid(target):
		return { "ok": false, "error": "add_status: target is null/freed" }
	var status_id := str(effect.get("status_id", ""))
	if status_id.is_empty():
		return { "ok": false, "error": "add_status: status_id empty" }
	var expires_in: int = int(effect.get("expires_total_hours", 0))
	var expires_total_hours := -1 if expires_in <= 0 else expires_in
	var source := str(effect.get("source", ""))

	var existing_idx := -1
	for i in target.active_statuses.size():
		if str(target.active_statuses[i].get("type", "")) == status_id:
			existing_idx = i
			break
	if existing_idx >= 0:
		var existing: Dictionary = target.active_statuses[existing_idx]
		var prev: int = int(existing.get("expires_total_hours", -1))
		# 永久 (-1) 吸收任何续期；否则取较晚的 expiry
		if prev != -1 and (expires_total_hours == -1 or expires_total_hours > prev):
			existing["expires_total_hours"] = expires_total_hours
	else:
		target.active_statuses.append({
			"type": status_id,
			"started_at": Time.get_ticks_msec() / 1000.0,
			"expires_total_hours": expires_total_hours,
			"source_id": source,
		})
	target.refresh_statuses()
	return {
		"ok": true,
		"summary": "%s +status %s (expires_total_hours=%d)" % [target.name, status_id, expires_total_hours],
	}


# 解除某个 status（按 type 移除所有匹配条目）。不存在时静默 no-op，不算错误——
# lua 一般在做"该不该解除"判断后才声明，但 hot reload / race 下可能慢半拍。
static func _apply_remove_status(effect: Dictionary) -> Dictionary:
	var target := effect.get("target") as Character
	if target == null or not is_instance_valid(target):
		return { "ok": false, "error": "remove_status: target is null/freed" }
	var status_id := str(effect.get("status_id", ""))
	if status_id.is_empty():
		return { "ok": false, "error": "remove_status: status_id empty" }
	var removed := false
	for i in range(target.active_statuses.size() - 1, -1, -1):
		if str(target.active_statuses[i].get("type", "")) == status_id:
			target.active_statuses.remove_at(i)
			removed = true
	if removed:
		# 不走 refresh_statuses —— 那会再触发 physiology hook，产生重复阈值检查。
		# 这里只刷 head_status + persist。
		target.head_status().sync_to_clients()
		target.state_io().persist()
	return {
		"ok": true,
		"summary": "%s -status %s%s" % [target.name, status_id, "" if removed else " (not present)"],
	}


# 翻转 alive。GDScript Character.alive 是 setter；setter 内部调虚 hook _on_alive_changed
# 让子类 NPC/Player 做物理善后（NavMesh 移除、RPC 停发、动画切死亡）。
static func _apply_set_alive(effect: Dictionary) -> Dictionary:
	var target := effect.get("target") as Character
	if target == null or not is_instance_valid(target):
		return { "ok": false, "error": "set_alive: target is null/freed" }
	var new_alive := bool(effect.get("alive", true))
	if target.alive == new_alive:
		return { "ok": true, "summary": "%s.alive already %s" % [target.name, new_alive] }
	target.alive = new_alive
	return { "ok": true, "summary": "%s.alive → %s" % [target.name, new_alive] }


# Lua 侧主动发 world_event 给 backend。actorId 由 lua 自己塞 data 里（caller 知道是谁）。
# Lua 端不要再写 effect.text —— 自然语言由 backend per-type renderer 渲染。
static func _apply_world_event(effect: Dictionary) -> Dictionary:
	var event_type := str(effect.get("event_type", ""))
	if event_type.is_empty():
		return { "ok": false, "error": "world_event: event_type empty" }
	var data: Dictionary = effect.get("data", {})
	if not data is Dictionary:
		data = {}
	# Backend client 是 autoload，从场景树根取
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return { "ok": false, "error": "world_event: no SceneTree" }
	var backend := tree.root.get_node_or_null("BackendRuntimeClient")
	if backend == null or not backend.has_method("send_world_event"):
		return { "ok": false, "error": "world_event: BackendRuntimeClient unavailable" }
	backend.call("send_world_event", event_type, data)
	return {
		"ok": true,
		"summary": "world_event %s (data=%d keys)" % [event_type, data.size()],
	}
