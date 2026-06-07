class_name InventorySlotData
extends RefCounted

# 一个 inventory slot dict 的视图。封装所有字段读 + display_name + stack 比较 +
# 子视图（容器 / 鲜度 / 耐久）+ backend snapshot。
#
# Schema（Phase 1 平铺）：{
#   item_id, quantity, quality,
#   shape_type, tags, materials, physics_props,        # reaction 涌现身份（generate 冻结）
#   container_amount, container_content,                # null = 非容器
#   freshness_tier, freshness_age_hours,                # null = 不腐
#   durability,                                         # null = 无耐久概念
#   base_effects, displayed_effects,                    # null = 无 use 效果
#   listing_price_centi,                                # null = 无标价（货架陈列时才有，仅展示）
# }
#
# 原 `properties` sub-dict **完全消失**——aspect 字段平铺到 slot 顶层。
# 这是为了消除"customProperties JSON bag + 字段路径漂移"那类 bug（见 project_item_state_architecture）。
#
# 设计原则：
# - 构造不复制；mutate slot 会写回 caller 的 dict（Godot Dictionary 引用语义）
# - 不变配置（如容器 capacity）从 template 读，不从 slot 读
# - 子视图 as_container() / as_perishable() / as_durability() 是 lazy 创建；不适用就返回 null

const DEFAULT_QUALITY := 100

var slot: Dictionary


# Static constructors ─────────────────────────────────────

# 包一个已有 slot dict。永远返回非 null（empty slot 也有合法视图）。
static func of(slot_: Dictionary) -> InventorySlotData:
	var view := InventorySlotData.new()
	view.slot = slot_
	return view


# 空 slot 工厂：所有字段默认值。aspect 字段一律 null，等 from_template 按模板判定是否初始化。
static func empty() -> Dictionary:
	return {
		"item_id": "",
		"quantity": 0,
		"quality": 0,
		"shape_type": "",
		"tags": PackedStringArray(),
		"materials": {},
		"physics_props": null,
		"container_amount": null,
		"container_content": null,
		"transform_age": null,
		"transform_settle_hour": null,
		"ferment_ceiling": null,
		"freshness_tier": null,
		"freshness_age_hours": null,
		"durability": null,
		"base_effects": null,
		"displayed_effects": null,
		"listing_price_centi": null,
	}


# 由 item_id + quality 派生 instance dict。
# 按 template 是否适用，初始化各 aspect 字段：
#   container（item.kind == "container"）→ container_amount=0.0, container_content=""
#   perishable（body material 有 shelf_life）→ freshness_tier=5, freshness_age_hours=0.0
#   工具（item.properties.max_durability > 0）→ durability=max
#   base_effects 非空 → 复制到 instance.base_effects（Phase 2 才真正填）
static func from_template(item_id: String, quality: int = DEFAULT_QUALITY) -> Dictionary:
	var inst := empty()
	inst["item_id"] = item_id
	inst["quality"] = quality
	var tmpl: Item = Items.by_id(item_id)
	if tmpl == null:
		return inst
	inst["shape_type"] = tmpl.shape_type
	inst["materials"] = tmpl.materials.duplicate()
	inst["tags"] = tmpl.tags.duplicate()
	# 容器：amount/content 初值 0/""（is_full()/is_empty() 直接判得通）
	if tmpl.kind == "container":
		inst["container_amount"] = 0.0
		inst["container_content"] = ""
	# perishable：body material 有 shelf_life 才适用（rotten 模板 category=spoiled 也算）
	var body_id := String(tmpl.materials.get("body", ""))
	if not body_id.is_empty():
		var mat: Substance = Materials.by_id(body_id)
		if mat != null and (mat.shelf_life_hours > 0.0 or mat.category == "spoiled"):
			inst["freshness_tier"] = 5
			inst["freshness_age_hours"] = 0.0
	# 工具：max_durability > 0 → 初始化为 max（全新工具）
	var max_dur := int(tmpl.properties.get("max_durability", 0))
	if max_dur > 0:
		inst["durability"] = max_dur
	# base_effects：复制 template 上的 export 字段。reaction generate 路径在 add_instance
	# 里若 inst 已带 base_effects 不会被覆盖（lua 端将来若想动态决定 effects 可以塞）。
	if not tmpl.base_effects.is_empty():
		inst["base_effects"] = tmpl.base_effects.duplicate()
	# displayed_effects 一次性算好，省去 caller 的 recompute 心智负担。
	# 任何后续 mutator（set_slot_state / decrement_tool_durability / generate）都会
	# 自己 recompute，保持物理上不可能漂移于 base * quality * freshness。
	ItemEffects.recompute_slot(inst)
	return inst


# Slot schema 单点归一。所有 slot dict 在写入 character.inventory / containers._contents /
# shelves listing 之前必须过这里一次。下游 getter 因此可以无脑相信类型。
#
# 为什么必须有：lua 的 `{}` 既可能是空 dict 也可能是空 array，LuaConv 没 schema
# 信息只能默认 array → dict 字段走 lua 回来会变 Array → getter 直接崩。每个 boundary
# coerce 一次，比让每个 reader 自己防御干净，也是"物理上不可能"再因为同类问题出 bug 的
# 唯一办法。
#
# null 字段保持 null（语义=本物没该 aspect）；不要把 null 强转成 0/""，否则会变成
# "我的剑 durability=0 是无敌还是即将报废"那种二义。
#
# 原地 mutate + 返回自身，方便 `inv[i] = InventorySlotData.normalize(slot)` 链式写法。
static func normalize(slot: Dictionary) -> Dictionary:
	slot["item_id"] = str(slot.get("item_id", ""))
	slot["quantity"] = int(slot.get("quantity", 0))
	slot["quality"] = int(slot.get("quality", 0))
	slot["shape_type"] = str(slot.get("shape_type", ""))
	slot["materials"] = _coerce_dict(slot.get("materials", null))
	slot["tags"] = _coerce_tags(slot.get("tags", null))
	slot["physics_props"] = _coerce_dict_or_null(slot.get("physics_props", null))
	slot["container_amount"] = _coerce_float_or_null(slot.get("container_amount", null))
	slot["container_content"] = _coerce_string_or_null(slot.get("container_content", null))
	slot["transform_age"] = _coerce_float_or_null(slot.get("transform_age", null))
	slot["transform_settle_hour"] = _coerce_float_or_null(slot.get("transform_settle_hour", null))
	slot["ferment_ceiling"] = _coerce_int_or_null(slot.get("ferment_ceiling", null))
	slot["freshness_tier"] = _coerce_int_or_null(slot.get("freshness_tier", null))
	slot["freshness_age_hours"] = _coerce_float_or_null(slot.get("freshness_age_hours", null))
	slot["durability"] = _coerce_int_or_null(slot.get("durability", null))
	slot["base_effects"] = _coerce_dict_or_null(slot.get("base_effects", null))
	slot["displayed_effects"] = _coerce_dict_or_null(slot.get("displayed_effects", null))
	slot["listing_price_centi"] = _coerce_int_or_null(slot.get("listing_price_centi", null))
	return slot


static func _coerce_dict(v: Variant) -> Dictionary:
	if v is Dictionary:
		return v
	return {}


static func _coerce_tags(v: Variant) -> PackedStringArray:
	if v is PackedStringArray:
		return v
	if v is Array:
		var out := PackedStringArray()
		for s in v as Array:
			out.append(str(s))
		return out
	return PackedStringArray()


static func _coerce_dict_or_null(v: Variant) -> Variant:
	if v == null:
		return null
	if v is Dictionary:
		return v
	# lua 空 dict 可能漂成空 Array；当 null 处理（更安全；caller 看到 null 直接走 default）
	return null


static func _coerce_int_or_null(v: Variant) -> Variant:
	if v == null:
		return null
	if v is int or v is float:
		return int(v)
	return null


static func _coerce_float_or_null(v: Variant) -> Variant:
	if v == null:
		return null
	if v is int or v is float:
		return float(v)
	return null


static func _coerce_string_or_null(v: Variant) -> Variant:
	if v == null:
		return null
	return str(v)


# Reads ───────────────────────────────────────────────────

func id() -> String:
	return String(slot.get("item_id", ""))

func quantity() -> int:
	return int(slot.get("quantity", 0))

func quality() -> int:
	return int(slot.get("quality", 0))

func shape_type() -> String:
	return String(slot.get("shape_type", ""))

func materials() -> Dictionary:
	return slot.get("materials", {})

func body_material_id() -> String:
	return String(materials().get("body", ""))

func tags() -> PackedStringArray:
	# slot 入库前必经 normalize()，这里直接信类型。
	return slot.get("tags", PackedStringArray())

func has_tag(tag: String) -> bool:
	return tag in tags()

# Aspect 平铺 getter（null = 该物无此 aspect）。
func container_amount() -> Variant:
	return slot.get("container_amount", null)

func container_content() -> Variant:
	return slot.get("container_content", null)

# 被动转换状态（drying / fermenting）。null = 未在转换。
func transform_age() -> Variant:
	return slot.get("transform_age", null)

func transform_settle_hour() -> Variant:
	return slot.get("transform_settle_hour", null)

func ferment_ceiling() -> Variant:
	return slot.get("ferment_ceiling", null)

func freshness_tier() -> int:
	var v: Variant = slot.get("freshness_tier", null)
	return 5 if v == null else int(v)

func durability() -> Variant:
	return slot.get("durability", null)

func base_effects() -> Variant:
	return slot.get("base_effects", null)

# 货架标价（centi 银）。null = 无标价（普通容器或未定价）。仅展示，付钱靠 trade/give。
func listing_price_centi() -> Variant:
	return slot.get("listing_price_centi", null)

func displayed_effects() -> Variant:
	return slot.get("displayed_effects", null)

func is_empty() -> bool:
	return id().is_empty() or quantity() <= 0


# Template / sub-views ───────────────────────────────────

func template() -> Item:
	return Items.by_id(id())


# kind != container → null
func as_container() -> ContainerAspect:
	return ContainerAspect.of(template(), slot)


# 不会腐烂 → null
func as_perishable() -> PerishableAspect:
	return PerishableAspect.of(slot)


# 不计耐久 → null
func as_durability() -> DurabilityAspect:
	return DurabilityAspect.of(template(), slot)


# Display ────────────────────────────────────────────────

# Template display_name 优先；为空时合成 body 材质 + shape；都没就 item_id 兜底。
func display_name() -> String:
	var tmpl := template()
	if tmpl != null and not tmpl.display_name.is_empty():
		return tmpl.display_name
	var body_id := body_material_id()
	var mat: Substance = Materials.by_id(body_id) if not body_id.is_empty() else null
	var shape_id := shape_type()
	var shape_def: Shape = Shapes.by_type(shape_id) if not shape_id.is_empty() else null
	var mat_name: String = mat.display_name if mat != null else body_id
	var shape_name: String = shape_def.display_name if shape_def != null else shape_id
	if mat_name.is_empty() and shape_name.is_empty():
		return id()
	return "%s%s" % [mat_name, shape_name]


# UI 色块用：body material 的 tint 优先，否则 caller 给 fallback（一般是 hash item_id 出来的色）。
func display_color(fallback: Color) -> Color:
	var body_id := body_material_id()
	if not body_id.is_empty():
		var mat: Substance = Materials.by_id(body_id)
		if mat != null:
			return mat.tint
	return fallback


# Stack 比较 ──────────────────────────────────────────────

# 两个 slot 能否合并：item_id + quality + shape + materials + tags + aspect 平铺字段全等。
# freshness_age_hours 不比较（同 tier 内的剩余时间对玩家透明）。
# base_effects / displayed_effects 也不比较（同 shape_type+materials+quality 决定，重复）。
func equals_stackable_with(other: InventorySlotData) -> bool:
	if id() != other.id():
		return false
	if quality() != other.quality():
		return false
	if shape_type() != other.shape_type():
		return false
	if materials() != other.materials():
		return false
	if freshness_tier() != other.freshness_tier():
		return false
	if container_amount() != other.container_amount():
		return false
	if container_content() != other.container_content():
		return false
	# 转换中的物（晾晒/发酵）各自计时，不同进度不合并（避免年龄被目标槽吞掉）。
	if transform_age() != other.transform_age():
		return false
	if ferment_ceiling() != other.ferment_ceiling():
		return false
	if durability() != other.durability():
		return false
	var ta := tags()
	var tb := other.tags()
	if ta.size() != tb.size():
		return false
	for i in ta.size():
		if ta[i] != tb[i]:
			return false
	return true


# Snapshot ───────────────────────────────────────────────

# Backend agent context 用：character.backpack_items 走这里产出每个槽的 dict。
# Phase 1：吐 typed 字段（containerAmount/containerContent/freshnessTier/durability/
# baseEffects/displayedEffects/physicsProps 等）。backend 在 Phase 3 会建
# agent-shared/item-display/ 模块统一渲染人类描述，不再依赖 Godot 端 descriptionParts。
func to_backend_dict() -> Dictionary:
	var tmpl := template()
	return {
		"itemId": id(),
		"displayName": tmpl.display_name if tmpl != null else id(),
		"kind": tmpl.kind if tmpl != null else "",
		"quantity": quantity(),
		"quality": quality(),
		"qualityTier": QualityTier.id(quality()),
		"shapeType": shape_type(),
		"materials": materials().duplicate(true),
		"tags": tags().duplicate(),
		"physicsProps": _nullable_dict_dup(slot.get("physics_props", null)),
		"containerAmount": container_amount(),
		"containerContent": container_content(),
		"transformAge": slot.get("transform_age", null),
		"fermentCeiling": slot.get("ferment_ceiling", null),
		"freshnessTier": slot.get("freshness_tier", null),
		"freshnessAgeHours": slot.get("freshness_age_hours", null),
		"durability": durability(),
		"baseEffects": _nullable_dict_dup(slot.get("base_effects", null)),
		"displayedEffects": _nullable_dict_dup(slot.get("displayed_effects", null)),
		"listingPriceCenti": slot.get("listing_price_centi", null),
	}


static func _nullable_dict_dup(v: Variant) -> Variant:
	if v == null:
		return null
	if v is Dictionary:
		return (v as Dictionary).duplicate(true)
	return null
