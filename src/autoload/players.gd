extends Node

# peer_id（Godot 传输层，每次连接随机）和 character_id（持久化身份，被十几张表引用）
# 解耦的注册中心。server 维护双向索引，client 只记自己。

# Client：本机玩家的 character_id。auth 完成后由 town.gd 写入。
var local_character_id: String = ""

# Client：login UI → town.gd auth callback 的一次性桥（scene 切换跨不过去）。
var pending_login_name: String = ""

# Client：上次登录被拒原因。town.gd auth callback 在收到 server 错误时写入，
# login.gd _ready 时显示并清空。空 = 没有挂起的错误。
var last_login_error: String = ""

# Server：双向索引。
var _peer_to_character: Dictionary = {}
var _character_to_peer: Dictionary = {}
# Server：peer → 玩家登录名（player_accounts.name）。spawn 时塞进 spawn data 让 player
# 节点把 character_name 设成真实名字，否则 backend 看到的 displayName 退化成 player_xxx。
var _peer_to_display_name: Dictionary = {}


func register(peer_id: int, character_id: String, display_name: String = "") -> void:
	if peer_id <= 0 or character_id.is_empty():
		return
	_peer_to_character[peer_id] = character_id
	_character_to_peer[character_id] = peer_id
	var name := display_name.strip_edges()
	if not name.is_empty():
		_peer_to_display_name[peer_id] = name


func unregister(peer_id: int) -> void:
	if peer_id <= 0:
		return
	var cid: String = str(_peer_to_character.get(peer_id, ""))
	_peer_to_character.erase(peer_id)
	_peer_to_display_name.erase(peer_id)
	if not cid.is_empty():
		_character_to_peer.erase(cid)


func character_id_of_peer(peer_id: int) -> String:
	return str(_peer_to_character.get(peer_id, ""))


func display_name_of_peer(peer_id: int) -> String:
	return str(_peer_to_display_name.get(peer_id, ""))


func peer_of_character(character_id: String) -> int:
	return int(_character_to_peer.get(character_id, 0))


func is_character_online(character_id: String) -> bool:
	return _character_to_peer.has(character_id)
