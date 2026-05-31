class_name Workstation
extends Resource

# 工作站类型定义。每个工作站类型一个 .tres，由 Workstations autoload 索引。
# 区别于 WorkstationNode（src/sim/workstations/workstation_node.gd）——后者是
# 场景里放置的 Node3D 实例，本 Resource 是数据定义。
#
# 设计：docs/architecture/reaction-schema.md §2.2 / §10
# - 每个 workstation 配一组 verbs（简单工作站 1 个，复杂工作站多个）
# - tags 给 passive 反应识别用（aging_vessel 等容器型）

@export var id: String = ""

# display_name 走 i18n catalog: data/i18n/<locale>/workstations.json -> workstation.<id>.name
var display_name: String:
	get: return tr("workstation.%s.name" % id) if not id.is_empty() else ""
	set(_value): pass

# 此工作站支持的 verb id 列表。例：anvil = ["shape", "hammer"]，stove = ["bake", "fry", "stew", "boil"]
@export var verbs: PackedStringArray = []

# 标签。容器型工作站（aging_barrel）打 ["aging_vessel"] 给 passive 反应匹配
@export var tags: PackedStringArray = []

# 交互模式：决定玩家按 E 时怎么处理。
# - "action_panel"（默认）：开 ActionPanel，复杂多输入反应（炉/砧/桌/磨/灶用这个）
# - "direct"：跳过 panel，直接调 player.request_workstation_direct(ws_id) RPC，
#   server 路由到具体处理（水井 → 耗时装满桶）。适合"按 E 即用"的简单交互。
@export var interaction_mode: String = "action_panel"

# ActionPanel 显示的 staging 槽数。默认 5；单料加工台（mill）设 1；
# 等所有物品做完再按反应最大 input 数精调每个工作台。
@export var slot_count: int = 5

# 跨角色并发上限。默认 1 = 严格单占（forge/anvil/mill/stove 这类"一台机器"）。
# 设大（如 100）表示场地型工作台允许多人同时作业——iron/gold/silver_mine 和
# lumberyard_workstation 是"一片矿区/一片林子"，节点抽象掉了内部多个采集点，让多人并发。
# 第 N+1 个想用的角色会被 WorkstationNode.try_acquire 拒掉，吃 workstation_busy reason。
@export var max_concurrent_users: int = 1
