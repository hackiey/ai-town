class_name ContainerHandlers
extends RefCounted

# 三个容器 verb 全部走 data/mechanics/container.lua（Step 6.1 迁移）。
# GDScript 端只负责：解析 args、resolve 容器节点、access check、调 wrapper。
# 业务规则（消息文案 / 找不到物品的报错 / world_event 内容）住 lua。


static func run_deposit(character: Character, action_request: Dictionary) -> Dictionary:
	return _run_container_verb(character, action_request, "deposit", true)


static func run_withdraw(character: Character, action_request: Dictionary) -> Dictionary:
	return _run_container_verb(character, action_request, "withdraw", true)


static func run_inspect(character: Character, action_request: Dictionary) -> Dictionary:
	return _run_container_verb(character, action_request, "inspect", false)


static func _run_container_verb(character: Character, action_request: Dictionary, op: String, needs_item: bool) -> Dictionary:
	var target: Variant = action_request.get("target", {})
	if typeof(target) != TYPE_DICTIONARY:
		return {"ok": false, "message": "%s target must be object" % op}
	var t: Dictionary = target as Dictionary
	var container_input := str(t.get("containerId", "")).strip_edges()
	if container_input.is_empty():
		return {"ok": false, "message": "%s 缺少 containerId" % op}
	var item_id := ""
	var quantity := 0
	if needs_item:
		item_id = str(t.get("itemId", "")).strip_edges()
		quantity = int(t.get("quantity", 0))
		if item_id.is_empty() or quantity <= 0:
			return {"ok": false, "message": "%s 缺少 itemId/quantity" % op}
	if Containers == null:
		return {"ok": false, "message": "Containers autoload is unavailable"}
	var resolution := Containers.resolve_for_actor(character, container_input)
	var node: ContainerNode = resolution.get("node") as ContainerNode
	# 容器找不到 → 直接拒，不进 lua（lua 期望 ctx.container 是 ContainerNode）
	if node == null:
		return {"ok": false, "message": str(resolution.get("message", "找不到容器"))}
	return MechanicVerb.resolve("container", {
		"actor": character,
		"actor_id": character.backend_character_id(),
		"container": node,
		"container_id": str(resolution.get("container_id", "")),
		"container_name": str(resolution.get("container_name", container_input)),
		"op": op,
		"item_id": item_id,
		"item_name": character.localize_item_name(item_id),
		"quantity": quantity,
		"access_ok": bool(resolution.get("ok", false)),
		"access_reason": str(resolution.get("message", "")),
	})
