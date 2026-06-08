class_name Item
extends Resource

# 一种 item type 的静态定义。所有同 id 实例共享 .tres，runtime 只通过 inventory
# 槽位的 item_id String 引用。Item 自己不变（resource 不可变共享）；持有者状态
# （quantity / 装备槽 / lua source 等）记录在 inventory / equipped / 单独 Resource 上。
#
# 设计：
# - [docs/architecture/simulation-layer.md §2.3](docs/architecture/simulation-layer.md) recipe 退化为 NPC 知识
# - [docs/architecture/crafting-interaction.md §2.4](docs/architecture/crafting-interaction.md) 物理 properties / 视觉字段两层互不读
#
# Item 只承载"被使用 / 被吃"时的 lua 行为，用 ScriptExecutor 跑。

@export var id: String = ""

# display_name 走 i18n catalog: data/i18n/<locale>/items.json -> item.<id>.name
# 不再持久化在 .tres；setter no-op 以兼容旧 .tres 字段
var display_name: String:
	get: return tr("item.%s.name" % id) if not id.is_empty() else ""
	set(_value): pass

# kind 给 UI / NPC perception / 校验用：food 能被 /eat。
# /plant 走 tags 语义：tags 含 "seed" 且 crop_variety_id 非空的物品可种植。
# 后期会扩 weapon / tool / wand 等。
@export var kind: String = "misc"

# 堆叠语义：stackable=false 强制每 stack 1 个（武器、护甲）。
@export var stackable: bool = true
@export var max_stack: int = 99

# 单件重量（kg）。所有物品必填 > 0；缺省 0 会在 boot 校验（town_world._seed_item_defs_to_db）
# 时 push_error。容器是空容器自重，装液体的额外重量由 InventorySlotData.total_weight 另算。
@export var weight: float = 0.0

# 关联：非空时表示该物品可种成什么 crop variety。
# 实际可不可以种，还要看 tags 里是否含 "seed"。
@export var crop_variety_id: String = ""

# Lua 行为源：on_eat / on_use / on_plant 等 entry function。空 = 没行为。
# ScriptExecutor.execute(item.source, "on_eat", ctx) 这样调。
# 沙箱见 src/sim/scripting/script_executor.gd。
@export_multiline var source: String = ""

# 使用物品耗时，单位是 game-second。0 = 立即结算；食物等可在 .tres 上配置为 300。
@export var use_duration_seconds: float = 0.0

# === 形状（反应匹配 + 视觉主体）===
# 由 Shapes.by_type(shape_type) 查 Shape 资源（display_name / parent / primary_part）。
# 见 reaction-schema.md §2.4 / §9.3。
@export var shape_type: String = ""

# === 材质组成（part_name → material_id）===
# 原料 / 中间件用 {"body": "iron"}；多部件物品如铁铲 = {"head": "iron", "shaft": "wood", "binding": "hemp"}。
# 反应表按 materials.<part>.<field> 路径匹配。见 reaction-schema.md §2.4 / §4.1。
@export var materials: Dictionary = {}

# === Tags（附加特征，参与匹配）===
# 例：["metal", "tool_part"] / ["wand", "magic_item"] / ["broken"]
@export var tags: PackedStringArray = []

# === 其它正交属性（与材质/形状无关的标量）===
# 例：weight、edge_sharpness、durability、length、flexibility。
# 反应表按 properties.<key> 匹配；实例属性可覆盖（Phase 3 instance）。
@export var properties: Dictionary = {}

# === 视觉表达层（UI/世界渲染读这个，物理引擎不碰）===
# icon 空时 inventory_slot 退化到哈希色块。
# world_mesh 指 inherited GroundItem scene（res://src/world/ground_item/items/<id>.tscn），
# drop 时由 GroundItemSpawner 实例化；空时 fallback 到 base ground_item.tscn 的默认 sack mesh。
# 装备到角色身上的 attached mesh 是另一回事，将来用单独字段。
# tint 给同 mesh 不同材质用（铁灰 / 铜橙 / 金黄共享 shovel.glb）。
# visual_modifiers 列出叠加 VFX 名（["fire_aura", "frost_glow"]），由 VFX 系统按名挂粒子。
@export var icon: Texture2D
@export var world_mesh: PackedScene
@export var tint: Color = Color(1, 1, 1, 1)
@export var visual_modifiers: PackedStringArray = []


# === 使用效果（reaction generate 时复制到 instance.base_effects）===
# Record<effectName, baseAmount>，如 {"hunger": 30, "stamina": 5}。
# 空 dict = 无 use 效果（非食物/非药水）。
# 后续 instance 的 displayedEffects 由 GDScript Applicator 基于此值 + quality/freshness 算。
# Phase 1 状态：本字段已加上，但所有食物 .tres 暂未填值；Phase 2 会写 .tres 同时把
# data/mechanics/*.lua 切到 compute_effects(ctx) -> dict 范式，并在 inventory_slot_data
# .from_template 把 tmpl.base_effects 复制到 instance.base_effects。
@export var base_effects: Dictionary = {}

# 被动转化（晾晒 wheat→malt、发酵 water→beer 等）不写在 item 模板上——定义全在反应表
# data/mechanics/crafting.lua（trigger=passive），由 PassiveSimulator 全局定时器推进。
# 加新被动转化只改反应表，不动这里。
