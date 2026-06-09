class_name LedgerHandlers
extends RefCounted

# write / read：通用可书写/可阅读物品机制。当前没有任何实物带 writable/readable，
# 所以普通路径一律失败；特定 (group, item_name) 组合走脏检查到 agent_ledgers 虚拟账册：
#   - royal_treasurer 群成员 + "王室薪水记录" → append/read 玛格达的薪水账册；read 时
#     系统自动拼上 mining_log（最近 7 game-day 逐条流水）当真值层。
# 加新虚拟账册：在 _VIRTUAL_LEDGERS 加一行 (group_id, ledger_name) 即可；如果要附额外
# 真值数据，在 _read_virtual_ledger 里 dispatch 不同账册名拼对应数据。

const _ROYAL_PAYROLL_LEDGER := "王室薪水记录"
const _ROYAL_TREASURER_GROUP := "royal_treasurer"
const _PAYROLL_LOG_DAYS := 7  # mining_log 回看窗口（最近 N 个 game-day）
const _MINER_IDS_FOR_PAYROLL: Array = ["tomas_pike", "harlan_dunn", "wilf_drake"]


static func run_write(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		_emit_write_event(character, "", "", "failure", "write target must be object")
		return {"ok": false, "message": "write target must be object"}
	var t: Dictionary = target as Dictionary
	var item_name := str(t.get("itemName", "")).strip_edges()
	var title := str(t.get("title", "")).strip_edges()
	var content := str(t.get("content", "")).strip_edges()
	if item_name.is_empty() or title.is_empty() or content.is_empty():
		_emit_write_event(character, item_name, title, "failure", "write 需要 itemName + title + content 三个非空字段")
		return {"ok": false, "message": "write 需要 itemName + title + content 三个非空字段"}

	var actor_id := character.backend_character_id()

	# 脏检查：(group, ledger_name) → 虚拟账册
	if item_name == _ROYAL_PAYROLL_LEDGER and Db.is_member_of(actor_id, _ROYAL_TREASURER_GROUP):
		var game_day := GameClock.game_day()
		var game_hour := GameClock.game_hour()
		var ok := Db.append_agent_ledger(actor_id, _ROYAL_PAYROLL_LEDGER, title, content, game_day, game_hour)
		if not ok:
			_emit_write_event(character, item_name, title, "failure", "写入王室薪水记录失败")
			return {"ok": false, "message": "写入王室薪水记录失败"}
		_emit_write_event(character, item_name, title, "success", "")
		return {
			"ok": true,
			"message": "已记入王室薪水记录【%s】：%s" % [title, content],
			"result": {"ledger": _ROYAL_PAYROLL_LEDGER, "title": title},
		}

	# 通用路径：背包或附近容器找名为 item_name 的可书写道具。当前没有任何道具有 writable 标签
	# / aspect → 一律失败。未来加 writable aspect 时在这里实现实物消耗+转化。
	_emit_write_event(character, item_name, title, "failure", "你身上和附近都没有可书写的「%s」（也不是你能动的虚拟账册）" % item_name)
	return {"ok": false, "message": "你身上和附近都没有可书写的「%s」（也不是你能动的虚拟账册）" % item_name}


static func run_read(character: Character, action_request: Dictionary) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		_emit_read_event(character, "", "failure", "read target must be object")
		return {"ok": false, "message": "read target must be object"}
	var t: Dictionary = target as Dictionary
	var title := str(t.get("title", "")).strip_edges()
	if title.is_empty():
		_emit_read_event(character, title, "failure", "read 缺少 title")
		return {"ok": false, "message": "read 缺少 title"}

	var actor_id := character.backend_character_id()

	# 脏检查：虚拟账册路径
	if title == _ROYAL_PAYROLL_LEDGER and Db.is_member_of(actor_id, _ROYAL_TREASURER_GROUP):
		var content := _read_royal_payroll_ledger(character, actor_id)
		_emit_read_event(character, title, "success", "")
		return {"ok": true, "message": content, "result": {"title": title, "content": content}}

	# 通用路径：当前没有任何道具有 readable 标签 → 一律失败。
	_emit_read_event(character, title, "failure", "你身上和附近都没有名为「%s」的可阅读物品（也不是你能动的虚拟账册）" % title)
	return {"ok": false, "message": "你身上和附近都没有名为「%s」的可阅读物品（也不是你能动的虚拟账册）" % title}


static func _emit_write_event(character: Character, item_name: String, title: String, outcome: String, error: String) -> void:
	var data := {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"itemName": item_name,
		"title": title,
		"outcome": outcome,
	}
	if not error.is_empty():
		data["error"] = error
	character.emit_world_event("write", data)


static func _emit_read_event(character: Character, title: String, outcome: String, error: String) -> void:
	var data := {
		"actorId": character.backend_character_id(),
		"affectedCharacterIds": character.perception().voice_affected_character_ids("far"),
		"title": title,
		"outcome": outcome,
	}
	if not error.is_empty():
		data["error"] = error
	character.emit_world_event("read", data)


# 拼系统真值（mining_log 最近 N 个 game-day）+ 玛格达自己写过的所有条目，
# 一并作为"王室薪水记录"内容返回。LLM 自己在两段之间对账。
static func _read_royal_payroll_ledger(character: Character, actor_id: String) -> String:
	var game_day := GameClock.game_day()
	var since_day := maxi(0, game_day - _PAYROLL_LOG_DAYS)
	var mining := Db.recent_mining_log(since_day)
	var ledger := Db.read_agent_ledger(actor_id, _ROYAL_PAYROLL_LEDGER)

	var lines: Array[String] = []
	lines.append("== 系统记录·矿工挖矿流水（最近 %d game-day，自第 %d 天起） ==" % [_PAYROLL_LOG_DAYS, since_day])
	if mining.is_empty():
		lines.append("（窗口内无任何挖矿记录）")
	else:
		# 按 characterId 分组
		var grouped: Dictionary = {}
		for entry_v in mining:
			var entry: Dictionary = entry_v as Dictionary
			var cid := str(entry.get("characterId", ""))
			if not grouped.has(cid):
				grouped[cid] = []
			(grouped[cid] as Array).append(entry)
		# 优先按 _MINER_IDS_FOR_PAYROLL 顺序输出，未列入的矿工追加在后面
		var ordered_ids: Array[String] = []
		for mid in _MINER_IDS_FOR_PAYROLL:
			if grouped.has(mid):
				ordered_ids.append(mid)
		for cid_v in grouped.keys():
			var cid: String = cid_v
			if not ordered_ids.has(cid):
				ordered_ids.append(cid)
		for cid in ordered_ids:
			var miner_name := _miner_display_name(cid)
			var entries: Array = grouped[cid] as Array
			# 同矿工内按矿种汇总 + 列出 entries
			var by_ore: Dictionary = {}
			for e_v in entries:
				var e: Dictionary = e_v as Dictionary
				var ore := str(e.get("oreType", ""))
				by_ore[ore] = int(by_ore.get(ore, 0)) + int(e.get("qty", 0))
			var totals_parts: Array[String] = []
			for ore_v in by_ore.keys():
				var ore: String = ore_v
				totals_parts.append("%s ×%d" % [character.localize_item_name(ore), int(by_ore[ore])])
			lines.append("· %s（%s）共：%s" % [miner_name, cid, ", ".join(totals_parts)])
			for e_v in entries:
				var e: Dictionary = e_v as Dictionary
				lines.append("    第%d天 %02d:00  %s ×%d" % [
					int(e.get("gameDay", 0)),
					int(e.get("gameHour", 0)),
					character.localize_item_name(str(e.get("oreType", ""))),
					int(e.get("qty", 0)),
				])
	lines.append("")
	lines.append("== 你的账册·历次发薪记录 ==")
	if ledger.is_empty():
		lines.append("（账册尚无任何条目；发完薪记得 write('王室薪水记录', '<标题>', '<明细>') 记下来）")
	else:
		for row_v in ledger:
			var row: Dictionary = row_v as Dictionary
			lines.append("· 第%d天 %02d:00  【%s】%s" % [
				int(row.get("gameDay", 0)),
				int(row.get("gameHour", 0)),
				str(row.get("title", "")),
				str(row.get("entry", "")),
			])
	return "\n".join(lines)


static func _miner_display_name(cid: String) -> String:
	if cid.is_empty():
		return ""
	var key := "npc.%s.name" % cid
	# static func 不能调实例 tr()；走 TranslationServer 拿当前 locale 翻译。
	var translated := str(TranslationServer.translate(key))
	if translated != key and not translated.strip_edges().is_empty():
		return translated
	return cid
