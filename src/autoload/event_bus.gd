extends Node

signal dialogue_started(timeline_id: StringName)
signal dialogue_ended(timeline_id: StringName)
signal dialogue_choice_made(choice_id: StringName)

signal flag_changed(key: StringName, value: Variant)

signal scene_change_requested(scene_path: String, spawn_point: StringName)
signal scene_changed(scene_path: String)

signal item_picked_up(item_id: StringName, count: int)
signal item_used(item_id: StringName)

signal quest_started(quest_id: StringName)
signal quest_updated(quest_id: StringName, step: int)
signal quest_completed(quest_id: StringName)

signal game_paused(paused: bool)
signal save_requested
signal load_requested

# 角色喊话广播：server 通过 Character.show_speech() RPC 把说话事件推到所有 client，
# 收到时本端的 Character 把这条信号转出来，HUD（聊天 log）订阅。
# affected_character_ids 是 speech.lua 算出的听众列表（不含 speaker）；HUD 用它过滤
# 出"本地玩家能听到的对话"。
signal character_spoke(character_id: String, text: String, volume: String, target_character_id: String, affected_character_ids: PackedStringArray)

# 系统通知：本地校验失败 / server 通过 Player._notify_owner_rpc 推回的成功/失败消息，
# 都转成这条信号 → 聊天 log 渲染成系统行。level: "info" | "success" | "warn" | "error"。
signal notification_posted(text: String, level: String)

# 工作站交互（client only）：本地玩家进/出 workstation 的 Area3D 时由 workstation.gd 触发。
# 由 ActionPanel 监听决定"E 键当前能开哪个工作站"。
# 设计：docs/architecture/crafting-interaction.md §2.2
signal workstation_proximity_changed(workstation: Node, entered: bool)

# 农场 proximity（client only）：town.gd 客户端定时算 local player 与 FarmGroup 距离，
# 进入半径 entered=true，退出 entered=false。FarmPanel 监听决定"E 键能否开农场面板"。
signal farm_proximity_changed(farm: Node, entered: bool)


# Craft 进度生命周期（client only）：server 通过 Player RPC → EventBus 中转，ActionPanel 渲染进度条。
# - started：制作开始，duration_sec 是预计耗时
# - completed：制作完成（成功或失败都是 completed），message 是结果文案
# - cancelled：中途中止（材料消失 / 死亡），reason 是原因
signal craft_started(reaction_name: String, duration_sec: float)
signal craft_completed(message: String)
signal craft_cancelled(reason: String)

# 通用玩家动作进度（client only）：吃东西等不属于工作台制造的动作复用同一条进度条。
signal player_action_started(action_name: String, duration_sec: float)
signal player_action_completed(message: String)
signal player_action_cancelled(reason: String)

# 制造锁住玩家位置：玩家在 craft 期间点 walk 目标 → server 拒绝并通过此信号通知 ActionPanel
# 弹确认对话框（"正在制造，是否取消？"）。Yes 触发 player.confirm_cancel_craft_and_move RPC。
signal craft_walk_block_requested(target_pos: Vector3)

# 玩家右键 NPC 时由 CameraRig 发出，NpcContextMenu 监听弹出操作菜单。
# screen_position 是鼠标屏幕坐标（用来定位菜单面板）。
signal npc_context_menu_requested(npc: Node, screen_position: Vector2)

# AI 托管（client only）：
# - available_models_received：server 经 Player._receive_available_models_rpc 把 backend 推来的
#   可用模型列表（raw "provider:model[/level]"）转给本地，AiTakeoverPanel 用来填模型下拉。
# - ai_takeover_state_changed：server 经 Player._set_ai_controlled_rpc 通知本地玩家当前是否被
#   AI 接管，AiTakeoverPanel 据此切按钮文案、本地禁用输入。
signal available_models_received(models: PackedStringArray)
signal ai_takeover_state_changed(active: bool)
