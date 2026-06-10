class_name SpeechController
extends RefCounted

# Speech 子系统：emit_say + show_speech RPC handler 收口。
#
# Server 路径：所有"角色发出 say_to"的入口走 emit_say(...)。规则（半径、目标距离校验、
# 听众过滤）住在 data/mechanics/speech.lua；本类只做物理查询（拿其他角色 + 距离）→ 调 lua
# → effects.gd 应用 broadcast_speech。结果里的 affected_ids 直接喂 character.show_speech.rpc。
#
# Client 路径：Character 的 @rpc show_speech 转发 handle_remote_speech(...)。本地玩家是否听见
# = speech.lua 算出的 affected_character_ids 中包含本地玩家 → 弹气泡 + 信号；否则静默。
# Backend 路径上 NPC say_to event 的 affectedCharacterIds 走同一份判定，两条路用同一份
# 听众判定，逻辑只在 speech.lua 一处。

var _character: Character


func _init(owner: Character) -> void:
	_character = owner


# Server 入口。返回 { ok: bool, error: String, affected_ids: Array[String] }。
func emit_say(text: String, volume: String, target_character_id: String = "") -> Dictionary:
	assert(RunMode.is_runtime(), "emit_say must run on the runtime server")
	var character_id := _character.backend_character_id()
	var target_id := target_character_id.strip_edges()
	if not target_id.is_empty() and target_id == character_id:
		return { "ok": false, "error": "say_to target cannot be self", "affected_ids": [] }

	# 物理查询：所有其他角色 + 与 self 距离。lua 端做规则决策。
	var candidates: Array = []
	for node in _character.perception().iter_other_characters():
		var other_id := _character.perception().character_id_of(node)
		if other_id.is_empty():
			continue
		candidates.append({
			"id": other_id,
			"distance": _character.global_position.distance_to(node.global_position),
			"is_sleeping": node.sleep_controller().is_sleeping() if node is Character else false,
		})

	# 醉酒说话：按说话者醉酒程度把话糊掉（蹦乱码）。糊后的文本既进气泡 RPC，也进
	# world_event 上报 backend——所有人听到的都是这版含混话。生病不触发（只醉酒专属）。
	var spoken := Impairment.garble_text(text, Impairment.drunk_level(_character))

	var ctx := {
		"speaker": _character,
		"speaker_id": character_id,
		"text": spoken,
		"volume": volume,
		"target_id": target_id,
		"candidates": candidates,
	}
	var result := MechanicHost.invoke("speech", "on_speak", ctx)
	if not bool(result.get("ok", false)):
		return { "ok": false, "error": str(result.get("error", "speech rejected")), "affected_ids": [] }

	# 从 broadcast_speech effect 拿 lua 算出的 affected_ids
	var affected: Array = []
	for eff in result.get("raw_effects", []):
		if typeof(eff) == TYPE_DICTIONARY and eff.get("type", "") == "broadcast_speech":
			var ids_v: Variant = eff.get("affected_ids", [])
			if ids_v is Array:
				for v in (ids_v as Array):
					affected.append(str(v))
			break

	# 大声喊话（far / shout）能把睡觉的人吵醒：speech.lua 已经按 waking_volumes 把睡着的
	# id 放进 affected。这里给每个原本在睡觉、且被 say_to 命中的 NPC fire 唤醒流程
	# （remove sleeping status + woke_up event）。say_to event 已经发出，woke_up 事件
	# 紧随其后；backend 按 event 顺序处理，merge 窗会把两个 trigger 合并成同一次 LLM turn。
	var sleeping_ids := {}
	for cand_v in candidates:
		var cand: Dictionary = cand_v as Dictionary
		if bool(cand.get("is_sleeping", false)):
			sleeping_ids[str(cand.get("id", ""))] = true
	for affected_id in affected:
		if not sleeping_ids.has(affected_id):
			continue
		var target_char := _character.perception().other_character_node_by_id(affected_id)
		if target_char is Character:
			(target_char as Character).sleep_controller().wake_from_external_stimulus("loud speech by %s" % character_id)

	return {
		"ok": true,
		"error": "",
		"affected_ids": affected,
	}


# Client 入口：Character 的 @rpc show_speech 转发到这里。
# 听众权威 = speech.lua 算出的 affected_character_ids（不含 speaker 自己）。
# RPC 广播给所有 client（避免 server 端额外维护 character→peer 映射），但接收端
# 在这里一次性判断"本地玩家是否在听众里"：听不到 → 气泡不弹 + 信号不 emit。
func handle_remote_speech(text: String, volume: String, target_character_id: String, affected_character_ids: PackedStringArray) -> void:
	if not _local_player_hears(affected_character_ids):
		return
	var duration := _character.head_status().show_speech_bubble(text)
	_character.play_speech_animation(duration)
	EventBus.character_spoke.emit(_character.backend_character_id(), text, volume, target_character_id, affected_character_ids)


# Wire contract: say_to.targetCharacterId. See backend/src/godot-link/actions.ts SayToTarget.
static func target_id_from_target(target: Dictionary) -> String:
	return str(target.get("targetCharacterId", "")).strip_edges()


# speaker 是本地玩家自己 → 永远听到；否则查本地玩家是否在 server 算出的听众里。
# local_character_id 为空（未登录完）→ 视为听不到。
func _local_player_hears(affected_character_ids: PackedStringArray) -> bool:
	var me := Players.local_character_id.strip_edges()
	if me.is_empty():
		return false
	if _character.backend_character_id() == me:
		return true
	return affected_character_ids.has(me)
