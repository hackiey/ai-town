class_name HusbandryRunner
extends RefCounted

# 畜牧操作的单一执行点（喂养 / 宰杀）。玩家(UI)与 NPC(backend tool)都调这里，只有"怎么
# 发起"不同（见 [[feedback_player_npc_same_character]]）。逻辑住在 Character 上，不分叉。
#
# server-only：动物状态权威在 runtime server。返回 {ok, message?, result?} 与 trade_runner 同形。

const _GROUND_ITEM_SPAWNER := preload("res://src/world/ground_item/ground_item_spawner.gd")
const _SLOT_DATA := preload("res://src/sim/items/inventory_slot_data.gd")

const FEED_AMOUNT := 35.0                       # 每次喂养抬高的 fed
const FEED_TAGS := ["fodder", "grain", "hay", "vegetable"]  # 可作饲料的物品标签

var _character: Character


func _init(owner: Character) -> void:
	_character = owner


# 喂养：消耗背包里一份饲料（带 grain/fodder/… 标签，如小麦），抬高动物 fed。
func feed(animal: Animal) -> Dictionary:
	var guard := _guard(animal)
	if not guard.is_empty():
		return {"ok": false, "message": guard}
	var feed_id := _find_feed_item()
	if feed_id.is_empty():
		return {"ok": false, "message": "背包里没有饲料（小麦 / 草料等）"}
	if not _character.inventory_ops().consume_one(feed_id):
		return {"ok": false, "message": "饲料消耗失败"}
	animal.fed = minf(100.0, animal.fed + FEED_AMOUNT)
	animal.persist_lifecycle()
	return {"ok": true, "result": {
		"animalId": animal.animal_id, "species": animal.species_id,
		"fed": int(animal.fed), "consumed": feed_id,
	}}


# 宰杀：产出肉(+皮)进背包，满则掉地。死亡动画 + 清 DB + 延时 free 在 animal.on_slaughtered。
func slaughter(animal: Animal) -> Dictionary:
	var guard := _guard(animal)
	if not guard.is_empty():
		return {"ok": false, "message": guard}
	var yields: Array = animal.slaughter_yields()
	animal.on_slaughtered()
	var produced: Array = []
	for y_v in yields:
		var y: Dictionary = y_v
		var item_id := str(y.get("item_id", ""))
		var qty := int(y.get("quantity", 0))
		if item_id.is_empty() or qty <= 0:
			continue
		var leftover := _character.inventory_ops().add_item(item_id, qty, 100)
		var granted := qty - leftover
		if granted > 0:
			produced.append({"item_id": item_id, "quantity": granted})
		if leftover > 0:
			_drop_leftover(item_id, leftover)
	return {"ok": true, "result": {
		"animalId": animal.animal_id, "species": animal.species_id, "yields": produced,
	}}


# 共同前置：runtime + 目标有效 + 是牲畜 + 活着 + 在交互半径内（fail-closed，见 [[feedback_fail_loud_no_silent_fallback]]）。
func _guard(animal: Animal) -> String:
	if not RunMode.is_runtime():
		return "husbandry must run on server"
	if animal == null or not is_instance_valid(animal):
		return "目标无效"
	if not animal.is_livestock():
		return "这不是可畜牧的牲畜"
	if not animal.alive:
		return "动物已经死了"
	if not _in_reach(animal):
		return "离动物太远，先靠近"
	return ""


func _in_reach(animal: Animal) -> bool:
	var radius := SiteMarker.interaction_radius_of(animal)
	if radius <= 0.0:
		return false
	return _character.global_position.distance_to(animal.global_position) <= radius


# 背包里第一件带饲料标签的物品 id（空 = 没有）。
func _find_feed_item() -> String:
	for s_v in _character.inventory:
		var s: Dictionary = s_v
		var item_id := str(s.get("item_id", ""))
		if item_id.is_empty():
			continue
		var tmpl: Item = Items.by_id(item_id)
		if tmpl == null:
			continue
		for t in tmpl.tags:
			if FEED_TAGS.has(str(t)):
				return item_id
	return ""


# 背包装不下的产出掉在脚边。
func _drop_leftover(item_id: String, qty: int) -> void:
	var slot := _SLOT_DATA.from_template(item_id, 100)
	slot["quantity"] = qty
	_GROUND_ITEM_SPAWNER.spawn_for_character(_character, slot)
