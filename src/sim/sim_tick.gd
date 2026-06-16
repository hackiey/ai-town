extends Node

# Autoload: SimTick —— 战斗/短时物理的快节奏 tick（simulation-layer.md §2.1 的 fast tick 落地）。
#
# 为什么按 real-time 而非游戏时间：战斗是实时、帧驱动的（弹道按 real-second 飞，LLM 战斗中暂停）。
# 命中结算节奏必须跟弹道一致，所以这个 tick 走 real delta，**不**跟 GameClock.time_scale——
# 否则 /timewarp 1000 会把命中结算拉到每帧上千次。游戏时间的慢节奏（hunger 衰减 / 作物 / buff
# 倒计时）由 GameClock.slow_tick / ten_minute_tick 负责，与本 tick 互不相干。
#
# 目前唯一消费者是 HitResolver（命中事件边界结算）。将来热传导 / 燃烧等也挂这里。
# 只在 server（RunMode.is_runtime）跑；client 是 puppet，命中结算是 server 权威。

signal fast_tick

const INTERVAL_SEC := 0.25  # 4 Hz

var _accum: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint() or not RunMode.is_runtime():
		set_process(false)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < INTERVAL_SEC:
		return
	# 一帧卡顿跨多个边界也只 emit 一次：消费方是幂等队列结算，不需要补帧。
	_accum = fmod(_accum, INTERVAL_SEC)
	fast_tick.emit()
