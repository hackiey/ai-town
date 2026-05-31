extends Node

signal runtime_connected
signal runtime_disconnected
signal action_received(action_payload: Dictionary)

const MSG_RUNTIME_ACCEPTED := "runtime.accepted"
const MSG_ACTION_SUBMIT := "action.submit"
const MSG_ACTION_CANCEL := "action.cancel"
const MSG_AGENT_THINKING := "agent.thinking"
const MSG_CHARACTER_GROUPS_REFRESH := "character.groups.refresh"
# backend 回的可用模型列表（AI 托管模型下拉用）。响应 RUNTIME_REQUEST_AVAILABLE_MODELS。
const MSG_AVAILABLE_MODELS := "available.models"
const MSG_PONG := "pong"
const MSG_ERROR := "error"

const RUNTIME_HEARTBEAT := "runtime.heartbeat"
const RUNTIME_PERCEPTION_MANIFEST := "character.perception_manifest"
const RUNTIME_CHARACTER_REGISTER := "character.register"
const RUNTIME_CHARACTER_UNREGISTER := "character.unregister"
const RUNTIME_ACTION_ACK := "action.ack"
const RUNTIME_ACTION_REQUEST := "action.request"
const RUNTIME_WORLD_EVENT := "world.event"
const RUNTIME_PLAYER_COMMAND := "player.command"
# 向 backend 请求可用模型列表（AI 托管弹窗打开时）。backend 回 MSG_AVAILABLE_MODELS。
const RUNTIME_REQUEST_AVAILABLE_MODELS := "request.available_models"
const RUNTIME_PROTOCOL_ACK := "protocol.ack"
# 启动期一次性发送 reaction 元数据 dump。lua = reaction 真值；backend 缓存供 LLM tool
# schema 注入难度提示 / proficiency 反查 axis。详见 docs/proficiency_issues.md #4-#5。
const RUNTIME_REACTION_CATALOG := "runtime.reaction_catalog_sync"
const AGENT_HOST_HELLO := "agent.host.hello"
const PROTOCOL_VERSION := "1.0.0"
const REPLAY_MESSAGE_TYPES := [RUNTIME_WORLD_EVENT]

@export var auto_connect: bool = true
@export var agent_host_bind_address: String = "127.0.0.1"
@export var agent_host_port: int = 3100
@export var town_id: String = "town_001"
@export var instance_id: String = "headless_godot"
@export var runtime_token: String = "dev-headless-only-token"
@export var heartbeat_interval: float = 10.0
@export var action_dedup_cache_limit: int = 200
@export var replay_buffer_limit: int = 500

var _server := TCPServer.new()
var _socket := WebSocketPeer.new()
var _has_socket := false
var _characters_by_id: Dictionary = {}
var _player_character_ids: Dictionary = {}
var _recent_action_ids: Array[String] = []
var _recent_action_lookup: Dictionary = {}
var _active_actions: Dictionary = {}
var _finished_actions: Dictionary = {}
var _last_backend_seq: int = 0
var _last_agent_ack_seq: int = 0
var _next_seq: int = 1
var _replay_buffer: Array[Dictionary] = []
var _was_open := false
var _accepted := false
var _heartbeat_timer := 0.0
# backend 推来的可用模型列表（raw "provider:model[/level]"）。连接时拉一次，缓存供弹窗用。
var _available_models: Array = []


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	# 只在 headless server 进程激活：client 进程不和 backend 直连，
	# 所有玩家可见的事都通过 Godot multiplayer 走 godot server。
	if not RunMode.is_runtime():
		set_process(false)
		return
	town_id = RunMode.town_id
	runtime_connected.connect(_on_runtime_connected)
	if auto_connect:
		_start_server()


func _process(delta: float) -> void:
	_accept_agent_host_if_available()
	if not _has_socket:
		return

	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
		_drain_messages()
		if _accepted:
			_tick_heartbeat(delta)
		return

	if state == WebSocketPeer.STATE_CLOSING:
		return

	if state == WebSocketPeer.STATE_CLOSED:
		_reset_socket()


func register_npc(npc: Node) -> void:
	var character_id := str(npc.get("npc_id"))
	if character_id.is_empty():
		return
	_register_character(character_id, npc, "NPC")


func unregister_npc(npc: Node) -> void:
	var character_id := str(npc.get("npc_id"))
	if character_id.is_empty():
		return
	_unregister_character(character_id, npc)


func register_player(player: Node) -> void:
	var player_id := _player_backend_id(player)
	if player_id.is_empty():
		return
	_register_character(player_id, player, "Player")
	_player_character_ids[player_id] = true
	# 通知 backend 这是一个 runtime character（player），把它纳入 alias index，
	# 让 resolveCharacterIdByName / characterName 等能命中。displayName 来自
	# 登录名（spawn 时由 town.gd 写到 player.character_name），缺失才退到 player_xxx。
	_send_character_register(player_id, _player_display_name(player), "player")


func unregister_player(player: Node) -> void:
	var player_id := _player_backend_id(player)
	if player_id.is_empty():
		return
	_unregister_character(player_id, player)
	_player_character_ids.erase(player_id)
	_send_character_unregister(player_id)


func _on_runtime_connected() -> void:
	# 重连：把已登记的 player 重放给 backend，重建 runtime registry。
	# NPC 已经在 backend 静态 npcs.json 里，不用重放。
	for character_id in _player_character_ids.keys():
		var character: Node = _characters_by_id.get(character_id)
		if character == null:
			continue
		_send_character_register(str(character_id), _player_display_name(character), "player")
	for character in _characters_by_id.values():
		if character is Node and character.has_method("send_perception_manifest"):
			character.call_deferred("send_perception_manifest")
	# 连接即拉一次可用模型，AI 托管弹窗打开时通常已就位。
	request_available_models()


# 玩家展示名 —— spawn 时 town.gd 把登录名（player_accounts.name）写到 player.character_name，
# 这里优先取它；fallback 到 backend_character_id（"player_<8hex>"）。
func _player_display_name(player: Node) -> String:
	if player == null:
		return ""
	var explicit := str(player.get("character_name")) if player.has_method("get") else ""
	if not explicit.strip_edges().is_empty():
		return explicit.strip_edges()
	return _player_backend_id(player)


func _send_character_register(character_id: String, display_name: String, kind: String) -> void:
	if character_id.is_empty():
		return
	if not is_runtime_connected():
		# 等 _on_runtime_connected 时统一重放
		return
	_send_message(RUNTIME_CHARACTER_REGISTER, {
		"characterId": character_id,
		"displayName": display_name if not display_name.is_empty() else character_id,
		"kind": kind,
	})


func _send_character_unregister(character_id: String) -> void:
	if character_id.is_empty() or not is_runtime_connected():
		return
	_send_message(RUNTIME_CHARACTER_UNREGISTER, {
		"characterId": character_id,
	})


# 玩家在 client 输入的自然语言指令 → server 收到 RPC 后调这个 → 走 player.command
# WS 消息发到 backend，由 agent 那边解析出 action。本端不解析，也不等回复。
func submit_player_command(player_id: String, text: String) -> void:
	if player_id.is_empty() or text.is_empty():
		return
	if not is_runtime_connected():
		push_warning("[BackendRuntimeClient] submit_player_command: websocket not connected")
		return
	_send_message(RUNTIME_PLAYER_COMMAND, {
		"commandId": "player_command_%d" % Time.get_ticks_usec(),
		"playerId": player_id,
		"characterId": player_id,
		"text": text,
		"issuedAt": Time.get_datetime_string_from_system(true),
		"gameTime": _game_time_snapshot(),
	})


# spoken_text: 只对 say_to / broadcast_speech / player_command 这类「实际说出/输入
# 的文字」才传。其它 event 的人类描述完全由 backend per-viewer 渲染层负责，
# Godot/Lua 这边只发结构化 data，不再拼中文/英文模板。
# Wire contract: backend/src/godot-link/protocol.ts WorldEventPayload.spokenText。
func send_world_event(event_type: String, data: Dictionary = {}, spoken_text: String = "") -> void:
	var event_data := data.duplicate(true)
	if not event_data.has("gameTime"):
		event_data["gameTime"] = _game_time_snapshot()
	var payload := {
		"type": event_type,
		"spokenText": spoken_text,
		"data": event_data,
		"gameTime": event_data.get("gameTime", {}),
		# 因果同步：事件自带 actor + affected 各自事件时刻的完整 perception，随同一条
		# world event 消息下发。backend worker 在触发 turn 前先写入这些 manifest，彻底
		# 消除"manifest 与 event 走两条 Redis channel 互相 race"导致的感知 stale。
		# 详见 docs/architecture/godot-agent-protocol.md §3.1。
		"perception": _build_event_perception(event_data),
	}
	if event_data.has("actorId"):
		payload["actorId"] = event_data.get("actorId")
	_send_message(RUNTIME_WORLD_EVENT, payload, true, true)


# 为事件的目标集合（actorId + affectedCharacterIds，恰好等于 backend 会触发 turn 的
# characterIdsForEvent）逐个构建当前 perception manifest，组成 { cid: manifest } dict。
func _build_event_perception(event_data: Dictionary) -> Dictionary:
	var ids: Dictionary = {}
	var actor_id: String = str(event_data.get("actorId", ""))
	if not actor_id.is_empty():
		ids[actor_id] = true
	var affected: Variant = event_data.get("affectedCharacterIds", [])
	if affected is Array:
		for entry in affected:
			var id := str(entry)
			if not id.is_empty():
				ids[id] = true
	var out: Dictionary = {}
	for char_id in ids.keys():
		var character: Node = _characters_by_id.get(char_id)
		if character != null and character.has_method("build_perception_manifest"):
			out[char_id] = character.call("build_perception_manifest")
	return out


func send_perception_manifest(manifest: Dictionary) -> void:
	if not is_runtime_connected():
		return
	var payload := manifest.duplicate(true)
	if not payload.has("gameTime"):
		payload["gameTime"] = _game_time_snapshot()
	if not payload.has("occurredAt"):
		payload["occurredAt"] = Time.get_datetime_string_from_system(true)
	_send_message(RUNTIME_PERCEPTION_MANIFEST, payload, false, true)


# AI 托管：向 backend 请求可用模型列表（连接时 + 弹窗打开时）。
func request_available_models() -> void:
	if not is_runtime_connected():
		return
	_send_message(RUNTIME_REQUEST_AVAILABLE_MODELS, {})


func _handle_available_models(msg: Dictionary) -> void:
	var payload: Dictionary = msg.get("payload", {}) as Dictionary
	var models_v: Variant = payload.get("models", [])
	var models: Array = []
	if models_v is Array:
		for m in (models_v as Array):
			var s := str(m)
			if not s.is_empty():
				models.append(s)
	_available_models = models


# server 进程上的 Player.request_available_models RPC 读这个，回给 owner client。
func get_available_models() -> Array:
	return _available_models.duplicate()


func _game_time_snapshot() -> Dictionary:
	var clock := get_node_or_null("/root/GameClock")
	if clock == null or not clock.has_method("game_time_snapshot"):
		return {}
	return clock.call("game_time_snapshot") as Dictionary


func is_runtime_connected() -> bool:
	return _accepted and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func request_action(character_id: String, action: String, target: Variant, reason: String = "", preempt: bool = false) -> void:
	if character_id.is_empty():
		push_warning("[BackendRuntimeClient] request_action: character_id is empty")
		return
	if not is_runtime_connected():
		push_warning("[BackendRuntimeClient] request_action: websocket not connected")
		return
	var payload := {
		"characterId": character_id,
		"action": action,
		"target": target,
		"gameTime": _game_time_snapshot(),
	}
	if not reason.is_empty():
		payload["reason"] = reason
	if preempt:
		payload["preempt"] = true
	_send_message(RUNTIME_ACTION_REQUEST, payload)


func report_action_progress(action_id: String, result: Dictionary) -> void:
	if action_id.is_empty() or result.is_empty():
		return
	if not _active_actions.has(action_id):
		return
	var active: Dictionary = _active_actions[action_id] as Dictionary
	_ack_action(
		int(active.get("seq", 0)),
		str(active.get("messageId", "")),
		action_id,
		"accepted",
		"",
		result
	)


func _start_server() -> void:
	var err := _server.listen(agent_host_port, agent_host_bind_address)
	if err != OK:
		push_warning("[BackendRuntimeClient] agent host websocket listen failed: %d" % err)
		return


func _accept_agent_host_if_available() -> void:
	if not _server.is_listening() or not _server.is_connection_available():
		return
	var stream := _server.take_connection()
	if stream == null:
		return
	var peer := WebSocketPeer.new()
	var err := peer.accept_stream(stream)
	if err != OK:
		push_warning("[BackendRuntimeClient] websocket accept failed: %d" % err)
		return
	if _has_socket and _socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_socket.close(4000, "replaced by newer agent host")
	_socket = peer
	_has_socket = true
	_was_open = false
	_accepted = false
	_heartbeat_timer = heartbeat_interval


func _reset_socket() -> void:
	_was_open = false
	if _accepted:
		_accepted = false
		runtime_disconnected.emit()
	_has_socket = false
	_socket = WebSocketPeer.new()


func _drain_messages() -> void:
	while _socket.get_available_packet_count() > 0:
		var raw := _socket.get_packet().get_string_from_utf8()
		_handle_message(raw)


func _handle_message(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[BackendRuntimeClient] invalid websocket message: %s" % raw)
		return

	var msg: Dictionary = parsed as Dictionary
	var msg_type: String = str(msg.get("type", ""))
	if msg_type == AGENT_HOST_HELLO:
		_handle_agent_host_hello(msg)
		return
	if not _accepted:
		push_warning("[BackendRuntimeClient] message before agent host hello: %s" % msg_type)
		_socket.close(1008, "agent host not registered")
		return
	match msg_type:
		MSG_RUNTIME_ACCEPTED:
			_handle_runtime_accepted(msg)
		MSG_ACTION_SUBMIT:
			action_received.emit(msg.get("payload", {}))
			_run_action.call_deferred(msg)
		MSG_ACTION_CANCEL:
			_cancel_action.call_deferred(msg)
		MSG_AGENT_THINKING:
			_ack_protocol(int(msg.get("seq", 0)))
			_apply_agent_thinking.call_deferred(msg)
		MSG_CHARACTER_GROUPS_REFRESH:
			_ack_protocol(int(msg.get("seq", 0)))
			_refresh_character_groups.call_deferred(msg)
		MSG_AVAILABLE_MODELS:
			_handle_available_models(msg)
		MSG_PONG:
			pass
		RUNTIME_PROTOCOL_ACK:
			_handle_agent_protocol_ack(msg)
		MSG_ERROR:
			push_warning("[BackendRuntimeClient] backend error: %s" % str(msg.get("payload", {})))
		_:
			push_warning("[BackendRuntimeClient] unsupported message type: %s" % msg_type)


func _handle_agent_host_hello(msg: Dictionary) -> void:
	var payload: Dictionary = msg.get("payload", {}) as Dictionary
	if str(msg.get("townId", "")) != town_id:
		_socket.close(1008, "townId mismatch")
		return
	if str(payload.get("token", "")) != runtime_token:
		_socket.close(1008, "invalid agent host token")
		return
	_last_agent_ack_seq = max(_last_agent_ack_seq, int(payload.get("lastAckSeq", 0)))
	_prune_replay_buffer()
	_accepted = true
	_send_message(MSG_RUNTIME_ACCEPTED, {
		"instanceId": instance_id,
		"serverTime": Time.get_datetime_string_from_system(true),
	}, false, false)
	# 静态 catalog dump：lua reaction 元数据。每次 backend 重连都重发，因为 backend
	# 可能是新进程没缓存。MechanicHost 启动期已就绪（autoload 排序 MechanicHost 在前）。
	_send_reaction_catalog()
	_replay_messages_after(_last_agent_ack_seq)
	runtime_connected.emit()


func _send_reaction_catalog() -> void:
	var host := get_node_or_null("/root/MechanicHost")
	if host == null or not host.has_method("get_reaction_catalog"):
		push_warning("[BackendRuntimeClient] MechanicHost autoload missing; cannot sync reaction catalog")
		return
	var rows: Array = host.call("get_reaction_catalog")
	_send_message(RUNTIME_REACTION_CATALOG, {
		"reactions": rows,
	}, false, false)


func _run_action(msg: Dictionary) -> void:
	var payload: Dictionary = msg.get("payload", {}) as Dictionary
	var seq: int = int(msg.get("seq", 0))
	var message_id: String = str(msg.get("id", ""))
	var action_id: String = str(payload.get("id", ""))
	var character_id: String = str(payload.get("characterId", ""))

	if not action_id.is_empty() and _recent_action_lookup.has(action_id):
		_ack_action(seq, message_id, action_id, "accepted")
		if _finished_actions.has(action_id):
			_ack_finished_action(seq, message_id, action_id, _finished_actions[action_id] as Dictionary)
		return

	if character_id.is_empty():
		_ack_action(seq, message_id, action_id, "failed", "action missing characterId")
		return

	var character: Node = _characters_by_id.get(character_id)
	if character == null:
		push_warning("[BackendRuntimeClient] action rejected: character_id='%s' action='%s' action_id='%s' (registry has %d keys=%s)" % [
			character_id, str(payload.get("action", "")), action_id, _characters_by_id.size(), str(_characters_by_id.keys()),
		])
		_ack_action(seq, message_id, action_id, "failed", "character not registered: %s" % character_id)
		return
	if not character.has_method("start_backend_action"):
		_ack_action(seq, message_id, action_id, "failed", "character cannot execute backend actions: %s" % character_id)
		return

	if not action_id.is_empty():
		_remember_action(action_id)
		_active_actions[action_id] = {
			"seq": seq,
			"messageId": message_id,
			"characterId": character_id,
		}
	_ack_action(seq, message_id, action_id, "accepted")
	character.start_backend_action(
		payload,
		Callable(self, "_on_action_finished").bind(seq, message_id, action_id)
	)


func _handle_runtime_accepted(msg: Dictionary) -> void:
	if _accepted:
		return
	_accepted = true
	runtime_connected.emit()


func _on_action_finished(ok: bool, error: String, result: Dictionary, seq: int, message_id: String, action_id: String) -> void:
	if not action_id.is_empty():
		_active_actions.erase(action_id)
		_finished_actions[action_id] = {
			"ok": ok,
			"error": error,
			"status": "completed" if ok else "failed",
			"result": result,
		}
		_remember_action(action_id)
	_ack_action(seq, message_id, action_id, "completed" if ok else "failed", error, result)


func _ack_finished_action(seq: int, message_id: String, action_id: String, finished: Dictionary) -> void:
	var result: Dictionary = {}
	var result_v: Variant = finished.get("result", {})
	if typeof(result_v) == TYPE_DICTIONARY:
		result = result_v as Dictionary
	_ack_action(
		seq,
		message_id,
		action_id,
		str(finished.get("status", "completed" if bool(finished.get("ok", false)) else "failed")),
		str(finished.get("error", "")),
		result
	)


# Backend 通知某角色 group 成员资格已变（dev /god 命令、未来的拜师/收徒 tool）。
# 找到该 character 节点，调 reload_groups_from_db 重读 SQLite。
# 不需要 ack——丢一条无所谓，下次 backend 改写或下次客户端 _ready 时还会重对齐。
func _refresh_character_groups(msg: Dictionary) -> void:
	var payload: Dictionary = msg.get("payload", {}) as Dictionary
	var character_id: String = str(payload.get("characterId", ""))
	if character_id.is_empty():
		return
	var character: Node = _characters_by_id.get(character_id)
	if character == null:
		# 还没注册（spawn 顺序问题）：reload 等 character _ready 自己跑
		return
	if character.has_method("reload_groups_from_db"):
		character.reload_groups_from_db()


func _apply_agent_thinking(msg: Dictionary) -> void:
	var payload: Dictionary = msg.get("payload", {}) as Dictionary
	var character_id: String = str(payload.get("characterId", ""))
	if character_id.is_empty():
		return
	var character: Node = _characters_by_id.get(character_id)
	if character == null:
		return
	var status: String = str(payload.get("status", ""))
	if status == "thinking" and character.has_method("set_backend_thinking"):
		character.call("set_backend_thinking", bool(payload.get("active", false)), str(payload.get("reason", "")))


func _cancel_action(msg: Dictionary) -> void:
	var payload: Dictionary = msg.get("payload", {}) as Dictionary
	var seq: int = int(msg.get("seq", 0))
	var message_id: String = str(msg.get("id", ""))
	var action_id: String = str(payload.get("actionId", ""))
	var character_id: String = str(payload.get("characterId", ""))
	var reason: String = str(payload.get("reason", "interrupted"))

	if action_id.is_empty():
		_ack_action(seq, message_id, action_id, "failed", "cancel missing actionId")
		return
	if _finished_actions.has(action_id):
		_ack_finished_action(seq, message_id, action_id, _finished_actions[action_id] as Dictionary)
		return
	if not _active_actions.has(action_id):
		_finished_actions[action_id] = {
			"ok": false,
			"error": reason,
			"status": "cancelled",
		}
		_remember_action(action_id)
		_ack_action(seq, message_id, action_id, "cancelled", reason)
		return

	var active: Dictionary = _active_actions[action_id] as Dictionary
	if character_id.is_empty():
		character_id = str(active.get("characterId", ""))
	var character: Node = _characters_by_id.get(character_id)
	if character == null:
		_ack_action(seq, message_id, action_id, "failed", "cancel character not registered: %s" % character_id)
		return
	if not character.has_method("cancel_backend_action"):
		_ack_action(seq, message_id, action_id, "failed", "character cannot cancel backend actions: %s" % character_id)
		return

	var cancel_error := str(character.call("cancel_backend_action", action_id, reason))
	if not cancel_error.is_empty():
		_ack_action(seq, message_id, action_id, "failed", cancel_error)
		return
	if _finished_actions.has(action_id):
		_ack_finished_action(seq, message_id, action_id, _finished_actions[action_id] as Dictionary)
		return
	_active_actions.erase(action_id)
	_finished_actions[action_id] = {
		"ok": false,
		"error": reason,
		"status": "cancelled",
	}
	_remember_action(action_id)
	_ack_action(seq, message_id, action_id, "cancelled", reason)


func _ack_action(seq: int, message_id: String, action_id: String, status: String, error: String = "", result: Dictionary = {}) -> void:
	_last_backend_seq = max(_last_backend_seq, seq)
	var payload := {
		"ackSeq": _last_backend_seq,
		"messageId": message_id,
		"actionId": action_id,
		"status": status,
		"gameTime": _game_time_snapshot(),
	}
	if not error.is_empty():
		payload["error"] = error
	if not result.is_empty():
		payload["result"] = result
	_send_message(RUNTIME_ACTION_ACK, payload, false, false)


func _ack_protocol(seq: int) -> void:
	if seq <= 0:
		return
	_last_backend_seq = max(_last_backend_seq, seq)
	_send_message(RUNTIME_PROTOCOL_ACK, {
		"ackSeq": _last_backend_seq,
	}, false, false)


func _handle_agent_protocol_ack(msg: Dictionary) -> void:
	var payload: Dictionary = msg.get("payload", {}) as Dictionary
	var ack_seq := int(payload.get("ackSeq", 0))
	if ack_seq <= 0:
		return
	_last_agent_ack_seq = max(_last_agent_ack_seq, ack_seq)
	_prune_replay_buffer()


func _send_message(message_type: String, payload: Dictionary, replayable: bool = false, sequenced: bool = false) -> void:
	var msg := {
		"id": "%s_%d" % [message_type.replace(".", "_"), Time.get_ticks_usec()],
		"type": message_type,
		"townId": town_id,
		"createdAt": Time.get_datetime_string_from_system(true),
		"version": PROTOCOL_VERSION,
		"payload": payload,
	}
	if sequenced:
		msg["seq"] = _next_seq
		_next_seq += 1
	if replayable:
		_remember_replay_message(msg)
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN or not _accepted:
		return
	_socket.send_text(JSON.stringify(msg))


func _remember_replay_message(msg: Dictionary) -> void:
	if not msg.has("seq"):
		return
	_replay_buffer.append(msg.duplicate(true))
	_prune_replay_buffer()
	while _replay_buffer.size() > replay_buffer_limit:
		_replay_buffer.pop_front()


func _prune_replay_buffer() -> void:
	while not _replay_buffer.is_empty():
		var oldest: Dictionary = _replay_buffer.front() as Dictionary
		if int(oldest.get("seq", 0)) > _last_agent_ack_seq:
			break
		_replay_buffer.pop_front()


func _replay_messages_after(seq: int) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN or not _accepted:
		return
	for msg_v in _replay_buffer:
		var msg: Dictionary = msg_v as Dictionary
		if int(msg.get("seq", 0)) > seq:
			_socket.send_text(JSON.stringify(msg))


func _remember_action(action_id: String) -> void:
	if action_id.is_empty():
		return
	if _recent_action_lookup.has(action_id):
		_recent_action_ids.erase(action_id)
	_recent_action_ids.append(action_id)
	_recent_action_lookup[action_id] = true

	while _recent_action_ids.size() > action_dedup_cache_limit:
		var evicted: String = str(_recent_action_ids.pop_front())
		if _active_actions.has(evicted):
			_recent_action_ids.append(evicted)
			break
		_recent_action_lookup.erase(evicted)
		_finished_actions.erase(evicted)


func _tick_heartbeat(delta: float) -> void:
	_heartbeat_timer -= delta
	if _heartbeat_timer > 0.0:
		return
	_heartbeat_timer = heartbeat_interval
	_send_message(RUNTIME_HEARTBEAT, {
		"instanceId": instance_id,
		"characterCount": _characters_by_id.size(),
		"onlinePlayers": _player_character_ids.size(),
		"gameTime": _game_time_snapshot(),
	})
	for action_id_v in _active_actions.keys():
		var action_id := str(action_id_v)
		var active: Dictionary = _active_actions.get(action_id, {}) as Dictionary
		_ack_action(
			int(active.get("seq", 0)),
			str(active.get("messageId", "")),
			action_id,
			"accepted"
		)


func _register_character(character_id: String, character: Node, label: String) -> void:
	if _characters_by_id.has(character_id) and _characters_by_id[character_id] != character:
		push_warning("[BackendRuntimeClient] replacing registered %s character id '%s'" % [label, character_id])
	_characters_by_id[character_id] = character


func _unregister_character(character_id: String, character: Node) -> void:
	if _characters_by_id.get(character_id) == character:
		_characters_by_id.erase(character_id)


func _player_backend_id(player: Node) -> String:
	if player == null or not player.has_method("backend_character_id"):
		return ""
	return str(player.call("backend_character_id"))
