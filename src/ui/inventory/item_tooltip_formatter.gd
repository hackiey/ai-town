class_name ItemTooltipFormatter

# 单一物品 tooltip 文案来源。inventory_slot 右下角 hover、ground_item_hover_status
# 鼠标提示都调 format(view, item, name)，保证两边显示完全一致。
#
# 历史：原住在 inventory_slot._build_tooltip，加 GroundItem hover 时抽出来共享，
# 避免复制粘贴 + 文案漂移。

# Phase 1: 改读 view 的 typed aspect getter + item.base_effects；不再依赖
# Item.instance_description_lines / preview_effects / format_effects_line（这些已删）。
static func format(view: InventorySlotData, item: Item, name_for_tip: String) -> String:
	var lines: Array = []
	var kind := item.kind if item != null else ""
	if not kind.is_empty():
		lines.append("[%s] %s x%d" % [kind, name_for_tip, view.quantity()])
	else:
		lines.append("%s x%d" % [name_for_tip, view.quantity()])
	lines.append(TranslationServer.translate("ui.tooltip.quality_format") % [QualityTier.display_name(view.quality()), view.quality()])
	# Kind-aware instance 描述（容量、鲜度、耐久等）— 各 aspect typed getter 在 UI 端就地渲染。
	# Backend agent context 走另一条路（Phase 3 backend/agent-shared/item-display），跟此处独立。
	_append_aspect_lines(lines, view, item)
	# 形状
	var shape_id := view.shape_type()
	if not shape_id.is_empty():
		var shape_def: Shape = Shapes.by_type(shape_id)
		var shape_name: String = shape_def.display_name if shape_def != null else shape_id
		lines.append(TranslationServer.translate("ui.tooltip.shape_format") % shape_name)
	# 材质
	var mats := view.materials()
	if not mats.is_empty():
		var mat_lines: Array = []
		for part in mats.keys():
			var mat_id: String = String(mats[part])
			var mat: Substance = Materials.by_id(mat_id)
			var mat_name: String = mat.display_name if mat != null else mat_id
			mat_lines.append("  · %s = %s" % [part, mat_name])
		lines.append(TranslationServer.translate("ui.tooltip.materials"))
		lines.append_array(mat_lines)
	# Tags（instance）
	var tags := view.tags()
	if tags.size() > 0:
		lines.append(TranslationServer.translate("ui.tooltip.tags_format") % ", ".join(tags))
	# 功效（Phase 1：读 item.base_effects 平铺字段；Phase 2 切到 view.displayed_effects）
	_append_effects_line(lines, item)
	return "\n".join(lines)


# 容量 / 鲜度 / 耐久三个 aspect 的 tooltip 行。空就跳过。
static func _append_aspect_lines(lines: Array, view: InventorySlotData, item: Item) -> void:
	var container := view.as_container()
	if container != null and container.capacity() > 0.0:
		var cap_text := _format_amount(container.capacity())
		if container.is_empty():
			lines.append("容量：空 0/%s" % cap_text)
		else:
			var content_name := container.content_id()
			var mat: Substance = Materials.by_id(container.content_id())
			if mat != null and not mat.display_name.is_empty():
				content_name = mat.display_name
			lines.append("容量：%s %s/%s" % [content_name, _format_amount(container.amount()), cap_text])
	var perishable := view.as_perishable()
	if perishable != null:
		if perishable.is_rotten():
			lines.append("鲜度：已腐烂")
		else:
			lines.append("鲜度：%s" % PerishableAspect.tier_name(perishable.tier()))
	var dura := view.as_durability()
	if dura != null:
		lines.append("耐久：%d/%d" % [dura.value(), dura.max_value()])


# 把 item.base_effects（template 默认）渲染成 "功效：饱食 +30, 体力 +5"。
# Phase 2 切到 view.displayed_effects（GDScript applicator 算后写在 instance）。
static func _append_effects_line(lines: Array, item: Item) -> void:
	if item == null or item.base_effects.is_empty():
		return
	var parts: Array[String] = []
	for k in item.base_effects.keys():
		var amount := float(item.base_effects[k])
		var label := _localized_effect_label(String(k))
		var sign := "+" if amount >= 0.0 else ""
		var num := ("%.1f" % amount) if absf(amount - roundf(amount)) > 0.05 else str(int(roundf(amount)))
		parts.append("%s %s%s" % [label, sign, num])
	lines.append(TranslationServer.translate("ui.tooltip.effects_format") % ", ".join(parts))


# 本地化常见 effect 名（hunger/stamina/hp 等）。其它 effect 直接显示 raw key。
# 设计：跟 Phase 3 backend item-display 处理后的口径独立 —— Godot UI tooltip 用自己
# 的 helper 不依赖 backend 渲染。
static func _localized_effect_label(name: String) -> String:
	match name:
		"hunger": return TranslationServer.translate("attribute.hunger.name")
		"stamina": return TranslationServer.translate("attribute.stamina.name")
		"health", "hp": return TranslationServer.translate("attribute.hp.name")
		_: return name


static func _format_amount(value: float) -> String:
	if absf(value - roundf(value)) < 0.05:
		return str(int(roundf(value)))
	return "%.1f" % value
