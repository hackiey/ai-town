class_name CharacterVisualSetup

# NPC + Player 共享的 visible-mesh / 动画补丁工具。23 个角色 mesh 共用 1 个
# FantasyKingdom skeleton；script 负责挑出唯一可见的 mesh + 套上共用材质，再修
# Mixamo 动画的 loop / Hips 位移问题。两边代码原本逐字相同，这里收口。

# Apply only one named mesh under skeleton (hide the rest), then set the shared
# material on it. Returns true if mesh_name 实际存在；caller 自行决定要不要 push_warning。
static func apply_visible_mesh(skel: Skeleton3D, mesh_name: String, material: Material) -> bool:
	if skel == null:
		return false
	var found := false
	for c in skel.get_children():
		if c is MeshInstance3D:
			var on := c.name == mesh_name
			c.visible = on
			if on:
				found = true
				var mi := c as MeshInstance3D
				for i in mi.get_surface_override_material_count():
					mi.set_surface_override_material(i, material)
	return found


# 强制 LOOP_LINEAR + 剥 Hips position track。Mixamo 默认 loop=NONE 播完会停；
# Walking Hips 自带 +Z 位移与 CharacterBody3D.velocity 叠加 → cycle 末端动画 reset
# 时角色视觉啪一下倒退。共享 Animation resource，第一次跑改完所有人受益；后续是 no-op。
# 编辑器里调用会让 .res 处于"已修改"状态 —— 调用方应在 Engine.is_editor_hint() 时跳过。
static func patch_animation_tracks(anim: AnimationPlayer) -> void:
	if anim == null:
		return
	for lib_name in anim.get_animation_library_list():
		var lib := anim.get_animation_library(lib_name)
		for a_name in lib.get_animation_list():
			var a := lib.get_animation(a_name)
			a.loop_mode = Animation.LOOP_LINEAR
			for ti in range(a.get_track_count() - 1, -1, -1):
				if a.track_get_type(ti) != Animation.TYPE_POSITION_3D:
					continue
				var p := a.track_get_path(ti)
				if p.get_subname_count() > 0 and String(p.get_subname(0)) == "Hips":
					a.remove_track(ti)


static func speech_animation_name(mesh_name: String) -> String:
	var female := mesh_name.to_lower().find("female") >= 0
	var names: Array[String] = ["SpeakMale1", "SpeakMale2"]
	if female:
		names = ["SpeakFemale1", "SpeakFemale2"]
	return names[randi() % names.size()]


static func setup_wand_attachment(skel: Skeleton3D, wand_scene: PackedScene) -> Node3D:
	if skel == null or wand_scene == null:
		return null
	var existing := skel.get_node_or_null("WandAttachment")
	if existing != null:
		var nested_tip := existing.get_node_or_null("Wand/WandTip")
		if nested_tip != null:
			return nested_tip
		return existing.get_node_or_null("WandTip")

	var bone_name := "RightHand"
	if skel.find_bone(bone_name) < 0:
		bone_name = "Hand_R"
	if skel.find_bone(bone_name) < 0:
		push_error("[CharacterVisualSetup] No RightHand bone found")
		return null

	var attachment := BoneAttachment3D.new()
	attachment.name = "WandAttachment"
	attachment.bone_name = bone_name
	skel.add_child(attachment)

	var wand := wand_scene.instantiate()
	wand.name = "Wand"
	# Stirring_Stick's local Y axis is its length; rotate it into the hand's forward direction.
	wand.position = Vector3(0.0, 0.0, 0.0)
	wand.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	wand.scale = Vector3(0.55, 0.55, 0.55)
	attachment.add_child(wand)
	# Remove static body collision from the wand (it's just visual now)
	for child in wand.get_children():
		if child is StaticBody3D:
			child.queue_free()

	var wand_tip := Marker3D.new()
	wand_tip.name = "WandTip"
	wand_tip.position = Vector3(0.0, 0.53, 0.0)
	wand.add_child(wand_tip)

	return wand_tip


static func set_combat_anims_no_loop(anim: AnimationPlayer) -> void:
	if anim == null:
		return
	var no_loop_anims := ["CastWand", "KnockedOut", "GettingUp"]
	for lib_name in anim.get_animation_library_list():
		var lib := anim.get_animation_library(lib_name)
		for a_name in no_loop_anims:
			if lib.has_animation(a_name):
				lib.get_animation(a_name).loop_mode = Animation.LOOP_NONE
