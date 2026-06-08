@tool
class_name WorldObjectIdentity
extends Node

const NODE_NAME := "WorldObjectIdentity"

# World object instance identity. This is the single source for object_id.
# Spatial anchors live in SiteMarker; definitions live in WorldObjectDef/def_id.

@export var object_id: String = ""
@export var object_def: WorldObjectDef
@export var def_id: String = ""
@export_enum("location", "workstation", "container", "shelf", "farm", "character", "item", "magic_element")
var kind: String = "location"

@export var parent_object_id: String = ""
@export var owner_group: String = ""
@export_enum("global", "local") var map_registration: String = "local"
@export var zone: String = ""
@export var category: String = ""
@export var sort_order: int = 0
@export var capabilities: PackedStringArray = PackedStringArray()
@export var lock_item_id: String = ""
@export var group_gated_capabilities: PackedStringArray = PackedStringArray()


static func for_node(node: Node) -> WorldObjectIdentity:
	var current := node
	while current != null:
		var direct := current as WorldObjectIdentity
		if direct != null:
			return direct
		var child := current.get_node_or_null(NODE_NAME) as WorldObjectIdentity
		if child != null:
			return child
		current = current.get_parent()
	return null


static func ensure_for_node(node: Node, id: String, def: String, object_kind: String) -> WorldObjectIdentity:
	var identity := for_node(node)
	if identity == null:
		identity = WorldObjectIdentity.new()
		identity.name = NODE_NAME
		node.add_child(identity)
	identity.object_id = id
	identity.def_id = def
	identity.kind = object_kind
	return identity


func effective_object_id() -> String:
	return object_id.strip_edges()


func effective_def_id() -> String:
	if object_def != null and not object_def.id.strip_edges().is_empty():
		return object_def.id.strip_edges()
	var id := def_id.strip_edges()
	return id if not id.is_empty() else effective_object_id()


func effective_kind() -> String:
	if object_def != null and not object_def.kind.strip_edges().is_empty():
		return object_def.kind.strip_edges()
	return kind.strip_edges()


func effective_capabilities() -> PackedStringArray:
	if not capabilities.is_empty():
		return PackedStringArray(capabilities)
	if object_def != null:
		return PackedStringArray(object_def.default_capabilities)
	return PackedStringArray()


func effective_group_gated_capabilities() -> PackedStringArray:
	if not group_gated_capabilities.is_empty():
		return PackedStringArray(group_gated_capabilities)
	if object_def != null:
		return PackedStringArray(object_def.default_group_gated_capabilities)
	return PackedStringArray()


func validate_identity(context: String = "") -> bool:
	var id := effective_object_id()
	if id.is_empty():
		push_error("[WorldObjectIdentity] object_id 未填: %s" % context)
		return false
	if map_registration == "global" and zone.strip_edges().is_empty():
		push_error("[WorldObjectIdentity %s] map_registration=global 必须填 zone" % id)
		return false
	return true
