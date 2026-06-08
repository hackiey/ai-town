@tool
class_name WorldObjectDef
extends Resource

# Definition/template for a world object. This is not an instance id.
# Examples: stove, bakery_bread_shelf, bread, fire_element.

@export var id: String = ""
@export_enum("location", "workstation", "container", "shelf", "farm", "character", "item", "magic_element")
var kind: String = "location"
@export var display_name_key: String = ""
@export var description_key: String = ""
@export var default_capabilities: PackedStringArray = PackedStringArray()
@export var default_group_gated_capabilities: PackedStringArray = PackedStringArray()
