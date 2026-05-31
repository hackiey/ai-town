extends Node

# 系统级铸币的 GDScript orchestrator —— 规则全在 data/mechanics/minting.lua。
# 每 game-hour 触发 lua hook，传入国库 ContainerNode 作 ctx。

const _VAULT_ID := "treasury_vault"


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	if not RunMode.is_runtime():
		set_process(false)
		return
	GameClock.slow_tick.connect(_on_slow_tick)


func _on_slow_tick(_total_hour: int) -> void:
	var vault := Containers.find_container_node(_VAULT_ID)
	if vault == null:
		return
	MechanicHost.invoke("minting", "on_slow_tick", { "vault": vault })
