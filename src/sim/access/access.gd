class_name Access
extends RefCounted

# 农田等仍需 owner_group 硬权限的资源统一访问校验。
# - owner_group 留空 = 公用通过
# - server (runtime)：走 SQLite 真值 (Db.can_access)
# - client：用 character.groups（owner-private MultiplayerSynchronizer 同步过来的快照），
#   非本地玩家无法判断也不该判断
#
# Group 语义见 project_groups_access_model；farm 接入点 src/sim/crops/farm_group.gd。
static func can_be_used_by(character: Node, owner_group: String) -> bool:
	if owner_group.is_empty():
		return true
	if character == null:
		return false
	if RunMode.is_runtime():
		var character_id := str(character.backend_character_id()) if character.has_method("backend_character_id") else ""
		return Db.can_access(character_id, owner_group)
	var groups: PackedStringArray = character.groups if character.get("groups") != null else PackedStringArray()
	if groups.has("god"):
		return true
	return groups.has(owner_group)
