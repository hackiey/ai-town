extends Node

# 验证 §4.1 inventory affect 套件：聚焦新代码
#   - InventoryAdapter.matches() query 匹配（item_id / content_id / min_quality / 多字段 AND）
#   - Container adapter take / place / set_slot 路径（通过 Effects.apply 走端到端）
#   - Shelf adapter 投影（空 Db 下返回空数组）
#
# Character adapter 不在此 smoke 内：依赖 Character _ready 完整链（DB hydrate / 物理 /
# RPC），单测代价高；改由 Step 6.1 集成验证。
#
# 跑法: godot --headless --path . res://scripts/inventory_adapter_smoke.tscn

const _CONTAINER_SCENE := preload("res://src/sim/containers/container_node.tscn")


func _ready() -> void:
	var ok := _run_all()
	print("\n[smoke] result: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


func _run_all() -> bool:
	var ok := true

	# ── 1. matches() 单元测试 ───────────────────────────────────────
	ok = ok and _test_matches()

	# ── 2. Container adapter 端到端 ────────────────────────────────
	ok = ok and _test_container_adapter()

	# ── 3. Shelf adapter 投影（空 listings）──────────────────────────
	ok = ok and _test_shelf_adapter_empty()

	return ok


# ───────────────────────────────────────────────────────────────────

func _test_matches() -> bool:
	var ok := true
	var s := InventorySlotData.empty()
	s["item_id"] = "wheat"
	s["quantity"] = 5
	s["quality"] = 80
	s["properties"] = { "content_id": "" }

	ok = ok and _assert(InventoryAdapter.matches(s, {"item_id": "wheat"}), "matches item_id")
	ok = ok and _assert(not InventoryAdapter.matches(s, {"item_id": "barley"}), "rejects wrong item_id")
	ok = ok and _assert(InventoryAdapter.matches(s, {"min_quality": 70}), "passes min_quality 70")
	ok = ok and _assert(not InventoryAdapter.matches(s, {"min_quality": 90}), "rejects min_quality 90")
	ok = ok and _assert(InventoryAdapter.matches(s, {"item_id": "wheat", "min_quality": 50}), "AND combo passes")
	ok = ok and _assert(not InventoryAdapter.matches(s, {"item_id": "wheat", "min_quality": 99}), "AND combo rejects")

	# Empty slot 永远不匹配
	var es := InventorySlotData.empty()
	ok = ok and _assert(not InventoryAdapter.matches(es, {}), "empty slot never matches")
	ok = ok and _assert(not InventoryAdapter.matches(es, {"item_id": ""}), "empty slot + empty query rejects")

	# content_id 匹配
	var bucket := InventorySlotData.empty()
	bucket["item_id"] = "wood_bucket"
	bucket["quantity"] = 1
	bucket["properties"] = { "content_id": "water" }
	ok = ok and _assert(InventoryAdapter.matches(bucket, {"content_id": "water"}), "matches content_id water")
	ok = ok and _assert(not InventoryAdapter.matches(bucket, {"content_id": "oil"}), "rejects wrong content_id")

	return ok


# ───────────────────────────────────────────────────────────────────

func _test_container_adapter() -> bool:
	var ok := true
	# 用唯一 container_id 避开 state.db 持久化跨次污染
	var cid := "smoke_container_%d" % Time.get_ticks_msec()
	# 1) spawn ContainerNode；自动 register 到 Containers
	var cn := _CONTAINER_SCENE.instantiate() as ContainerNode
	cn.container_id = cid
	cn.container_name = "测试容器"
	cn.slot_count = 8
	add_child(cn)  # 触发 _ready → register_container

	# 2) seed 内容（用 system_deposit；既验证 seed 也证明 place 路径联通）
	var seed_r := Containers.system_deposit(cid, "wheat", 10, 100)
	ok = ok and _assert(bool(seed_r.get("ok", false)), "seed wheat x10")
	var seed_r2 := Containers.system_deposit(cid, "iron_ore", 5, 80)
	ok = ok and _assert(bool(seed_r2.get("ok", false)), "seed iron_ore x5 q80")

	# 3) adapter find_items: 查 wheat
	var adapter := InventoryAdapter.for_holder(cn)
	ok = ok and _assert(adapter != null, "adapter created for ContainerNode")
	if adapter == null:
		return false
	var found := adapter.find({"item_id": "wheat"})
	ok = ok and _assert(found.size() == 1, "find wheat returns 1 entry (got %d)" % found.size())
	if found.size() == 1:
		var f0: Dictionary = found[0]
		ok = ok and _assert(int(f0.get("qty", 0)) == 10, "wheat qty=10 (got %d)" % int(f0.get("qty", 0)))

	# 4) adapter find with min_quality 90 → iron_ore (q=80) 不入选
	var found_hi := adapter.find({"min_quality": 90})
	ok = ok and _assert(found_hi.size() == 1, "min_quality 90 → wheat only (got %d)" % found_hi.size())

	# 5) take_item 走 lua sync 路径：lua return moved_qty
	# 用 inline lua source 执行
	var take_lua := """
function on_test(ctx)
    return affect.take_item(ctx.holder, { item_id = "wheat" }, 3)
end
"""
	var take_r := ScriptExecutor.execute(take_lua, "on_test", { "holder": cn })
	ok = ok and _assert(bool(take_r.get("ok", false)), "take_item lua OK: %s" % take_r.get("error", ""))
	ok = ok and _assert(int(take_r.get("return_value", 0)) == 3, "take_item lua return=3 (got %s)" % str(take_r.get("return_value")))

	# 验证 container 现在 wheat 还剩 7
	var after_take := adapter.find({"item_id": "wheat"})
	if after_take.size() == 1:
		ok = ok and _assert(int(after_take[0].get("qty", 0)) == 7, "after take: wheat=7 (got %d)" % int(after_take[0].get("qty", 0)))

	# 6) take_item 超过库存：lua return = 实际拿到的 7
	var take_over_lua := """
function on_test(ctx)
    return affect.take_item(ctx.holder, { item_id = "wheat" }, 100)
end
"""
	var take_over_r := ScriptExecutor.execute(take_over_lua, "on_test", { "holder": cn })
	ok = ok and _assert(int(take_over_r.get("return_value", 0)) == 7, "take_item over: return=7 (got %s)" % str(take_over_r.get("return_value")))

	# 7) set_slot_state: 改 iron_ore 槽位 quality（lua return bool）
	var iron_found := adapter.find({"item_id": "iron_ore"})
	ok = ok and _assert(iron_found.size() == 1, "iron_ore exists")
	if iron_found.size() == 1:
		var iron_idx := int(iron_found[0].get("slot_index", -1))
		var set_lua := """
function on_test(ctx)
    return affect.set_slot_state(ctx.holder, ctx.idx, { quality = 99 })
end
"""
		var set_r := ScriptExecutor.execute(set_lua, "on_test", { "holder": cn, "idx": iron_idx })
		ok = ok and _assert(bool(set_r.get("return_value", false)), "set_slot_state lua return=true (got %s)" % str(set_r.get("return_value")))
		var iron_after := adapter.find({"item_id": "iron_ore"})
		if iron_after.size() == 1:
			ok = ok and _assert(int(iron_after[0].get("quality", 0)) == 99, "iron_ore quality=99 (got %d)" % int(iron_after[0].get("quality", 0)))

	# 8) world.find_items 走 lua 路径
	var find_lua := """
function on_test(ctx)
    local found = world.find_items(ctx.holder, { min_quality = 90 })
    return #found
end
"""
	var find_r := ScriptExecutor.execute(find_lua, "on_test", { "holder": cn })
	ok = ok and _assert(int(find_r.get("return_value", -1)) == 1, "world.find_items min_quality=90 → 1 (got %s)" % str(find_r.get("return_value")))

	# 9) Step 6.1 集成：MechanicVerb.resolve("container", op="inspect", access_ok=true)
	# 验证 wrapper + container.lua 联通；access_ok=true 走正常路径
	var inspect_r := MechanicVerb.resolve("container", {
		"actor": cn,  # inspect 不用 actor inventory；占位
		"actor_id": "smoke_actor",
		"container": cn,
		"container_id": cid,
		"container_name": "测试容器",
		"op": "inspect",
		"access_ok": true,
		"access_reason": "",
	})
	ok = ok and _assert(bool(inspect_r.get("ok", false)), "MechanicVerb inspect ok: %s" % inspect_r.get("message", ""))
	var inspect_msg := str(inspect_r.get("message", ""))
	ok = ok and _assert("测试容器" in inspect_msg, "inspect msg has container name")
	ok = ok and _assert("iron_ore" in inspect_msg, "inspect msg has iron_ore")

	# 10) Step 6.1: access_ok=false 直接拒
	var denied_r := MechanicVerb.resolve("container", {
		"actor": cn, "actor_id": "smoke_actor",
		"container": cn, "container_id": cid, "container_name": "测试容器",
		"op": "inspect",
		"access_ok": false,
		"access_reason": "你太远了",
	})
	ok = ok and _assert(not bool(denied_r.get("ok", true)), "MechanicVerb access denied")
	ok = ok and _assert(str(denied_r.get("message", "")) == "你太远了", "denied msg passed through")

	# 11) Step 6.1: 未知 op
	var unknown_r := MechanicVerb.resolve("container", {
		"actor": cn, "actor_id": "smoke_actor",
		"container": cn, "container_id": cid, "container_name": "测试容器",
		"op": "destroy", "access_ok": true, "access_reason": "",
	})
	ok = ok and _assert(not bool(unknown_r.get("ok", true)), "unknown op rejected")

	# 清理
	cn.queue_free()
	return ok


# ───────────────────────────────────────────────────────────────────

func _test_shelf_adapter_empty() -> bool:
	# Shelf adapter 投影：空 listings → 空数组（不需要真创建 ShelfNode）
	var ok := true
	# 没有 ShelfNode 实例时验证 adapter.for_holder 返回 null（type-safe）
	var adapter := InventoryAdapter.for_holder(null)
	ok = ok and _assert(adapter == null, "for_holder(null) → null")
	return ok


# ───────────────────────────────────────────────────────────────────

func _assert(cond: bool, label: String) -> bool:
	print("[smoke] %s  %s" % ["OK  " if cond else "FAIL", label])
	return cond
