extends SceneTree

# 端到端 smoke：直接读 state.db 验证 backend seed 数据 + 关键场景。
# 跑法: godot --headless --path . --script res://scripts/db-smoke-check.gd

func _init() -> void:
	if not ClassDB.class_exists("SQLite"):
		print("[smoke] FAIL: SQLite class not registered (装 GDExtension)")
		quit(1); return
	var db: Object = ClassDB.instantiate("SQLite")
	db.path = ProjectSettings.globalize_path("res://backend/data/state.db")
	if not db.open_db():
		print("[smoke] FAIL: open_db failed")
		quit(1); return

	var ok := true

	# 1. seed: oren_vale ∈ north_wall_wheat_plot
	var oren: Array = db.select_rows("character_groups", "characterId = 'oren_vale'", ["groupId"])
	var oren_ok: bool = oren.size() == 1 and str(oren[0].groupId) == "north_wall_wheat_plot"
	print("[smoke] oren_vale ∈ north_wall_wheat_plot: ", "OK" if oren_ok else "FAIL", " (", oren, ")")
	ok = ok and oren_ok

	# 2. seed: blacksmith_shop 没初始成员
	var smithy: Array = db.select_rows("character_groups", "groupId = 'blacksmith_shop'", ["characterId"])
	var smithy_ok: bool = smithy.size() == 0
	print("[smoke] blacksmith_shop 初始空: ", "OK" if smithy_ok else "FAIL", " (", smithy.size(), " members)")
	ok = ok and smithy_ok

	# 3. /god toggle 模拟：插入再删
	var test_char := "smoke_test_player"
	db.query("DELETE FROM character_groups WHERE characterId = '%s'" % test_char)
	db.query("INSERT INTO character_groups (townId, characterId, groupId, joinedAt, source) VALUES ('town_001', '%s', 'god', '%s', 'runtime')" % [test_char, Time.get_datetime_string_from_system(true)])
	var god: Array = db.select_rows("character_groups", "characterId = '%s' AND groupId = 'god'" % test_char, ["groupId"])
	var god_ok: bool = god.size() == 1
	print("[smoke] add god membership: ", "OK" if god_ok else "FAIL")
	db.query("DELETE FROM character_groups WHERE characterId = '%s'" % test_char)
	ok = ok and god_ok

	# 4. 全表 row count（健康度）
	var counts := {}
	for t in ["character_groups", "character_intents", "world_events", "agent_memories", "agent_sessions", "runtime_sessions"]:
		var r: Array = db.select_rows(t, "", ["COUNT(*) AS c"])
		counts[t] = int(r[0].c) if r.size() > 0 else -1
	print("[smoke] table counts: ", counts)

	db.close_db()
	print("[smoke] result: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
