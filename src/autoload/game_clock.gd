extends Node

# 游戏时钟。把 real-time 折算成 game-time 并发 slow_tick 信号。
#
# Default: time_scale = 10.0（1 real-sec = 10 game-sec）。game-time 走得比真实时间快 10×，
# 短登录里能看到作物 / NPC 状态推进，又不至于 Stardew 那样几秒一天破坏沉浸。
# 测试时用 /timewarp 临时改 time_scale 加速验证（debug only），不动 default。
#
# 信号契约：tick 只携带"自开服累计"真值（单调递增 int），不携带派生量。
# 需要 hour-of-day / day / minute-of-hour 的消费者用本 autoload 的纯函数派生
# （hour_of_day_for_hour / day_for_hour / minute_of_hour_for_minute / ...）。
# 历史上 signal 传 (hour_of_day, day) 派生值，导致消费者把 hour-of-day 错当
# total 拿去做时间差，引发跨日 stage 回退一类的单位混用 bug。新契约里"时间"
# 在 mechanic ctx 里只允许出现 *_total_hour / *_total_minute 命名。
#
# 信号：
#   slow_tick(total_game_hour: int)
#     每跨过一个 game-hour 边界 emit 一次。订阅方处理 hunger 衰减、Crop 生长、
#     buff 倒计时等。一次跨多 hour（time_scale 很大或卡顿）会按 hour 顺序逐次 emit。
#   ten_minute_tick(total_game_minute: int)
#     每跨过 10 game-minutes emit 一次。用于角色生理等需要比 slow_tick 更细的结算。
#
# 设计：[docs/architecture/simulation-layer.md §2.1](docs/architecture/simulation-layer.md)
# 三种 tick 节奏，本节点是 slow tick (1/game-hour) 的发源地。
#
# 持久化边界：headless Godot runtime 是游戏时间权威。它把每个 town 的 clock
# checkpoint 写到 SQLite `town_clock` 表（schema 在 src/autoload/db.gd 的
# `_GAME_WORLD_SCHEMA`），不从 backend 恢复、不让 backend 维护时间。
#
# Multiplayer 复制：本 autoload 是 server-authoritative 的全局时钟。不用
# MultiplayerSynchronizer——autoload 在 peer 之前就存在，过了 spawn 阶段，
# Godot 不会给后连入的 client 重发初始 state，sync 包的触发也不可靠。
# 改用显式 RPC：
# - runtime: peer_connected 即刻 rpc_id 推一份真值；之后每次 persist tick 用
#   `rpc()` 广播给所有 client。`_process` 推进 game_seconds 并写 DB。
# - client:  收到 push_clock RPC 才把 game_seconds / time_scale 当真值，set
#   外推 baseline + 标 _clock_synced=true。`_process` 在 synced 之前不动钟，
#   synced 后以最近一次真值 + 实时差 × time_scale 外推（永不累加误差）。
#   UI 用 `is_clock_synced()` 守门：首次 push 到达前显示占位。

signal slow_tick(total_game_hour: int)
signal ten_minute_tick(total_game_minute: int)
# client 首次拿到 server push 后 emit 一次，给 UI（HUD 等）立刻 refresh
# 用，不用等下一个 10-min tick 才解占位。runtime 永远不 emit。
signal clock_synced

const SECONDS_PER_GAME_HOUR := 3600.0
const SECONDS_PER_GAME_MINUTE := 60.0
const TEN_MINUTE_GAME_SECONDS := 10.0 * SECONDS_PER_GAME_MINUTE
const HOURS_PER_GAME_DAY := 24
const SECONDS_PER_GAME_DAY := float(HOURS_PER_GAME_DAY) * SECONDS_PER_GAME_HOUR
const DAYS_PER_REIGN_YEAR := 360
const INITIAL_GAME_HOUR := 6
const INITIAL_GAME_SECONDS := float(INITIAL_GAME_HOUR) * SECONDS_PER_GAME_HOUR

@export var time_scale: float = 10.0  # 1 real-sec = 10 game-sec
@export var persist_interval_sec: float = 5.0

var game_seconds: float = INITIAL_GAME_SECONDS  # 累计 game-time, 单位秒；默认从 06:00 开服
var _last_emitted_hour: int = -1
var _last_emitted_ten_minute: int = -1
var _persist_timer: float = 0.0

# client 外推基准：上次 push 收到的真值 + 当时本地实时戳。永远以最近真值重算，
# 不在外推结果上再累加 delta，避免长会话漂移。
var _client_baseline_seconds: float = -1.0
var _client_baseline_local_ts: float = 0.0
var _clock_synced: bool = false


func _ready() -> void:
	if RunMode.is_runtime():
		_load_persisted_clock()
		if _last_emitted_hour < 0:
			_seed_emission_baseline()
		_persist_timer = persist_interval_sec
		# peer 接入即推一份真值；不依赖 MultiplayerSynchronizer 的 spawn 复制
		multiplayer.peer_connected.connect(_on_peer_connected_runtime)


func _process(delta: float) -> void:
	if RunMode.is_runtime():
		game_seconds += delta * time_scale
		_emit_ticks_up_to(game_seconds)
		_tick_persistence(delta)
		return
	# client：首次 push 之前不动 game_seconds，UI 用 is_clock_synced() 守门
	if not _clock_synced:
		return
	var now := Time.get_ticks_msec() / 1000.0
	game_seconds = _client_baseline_seconds + (now - _client_baseline_local_ts) * time_scale
	_emit_ticks_up_to(game_seconds)


func is_clock_synced() -> bool:
	# runtime 永远 synced（自己就是真值）；client 等首次 push RPC 到达
	return RunMode.is_runtime() or _clock_synced


func _on_peer_connected_runtime(peer_id: int) -> void:
	# runtime-only：新 client 接入立刻定向推一份真值（reliable，必送达）
	push_clock.rpc_id(peer_id, game_seconds, time_scale)


# server → 所有 client 推时钟。reliable 保送达；周期由 _tick_persistence 控
# （persist_interval_sec=5s），同一节奏既写盘又广播，省一个 timer。
@rpc("authority", "reliable", "call_remote")
func push_clock(server_seconds: float, server_scale: float) -> void:
	# 只有 client 真正执行（authority/call_remote 已经过滤掉 server 自己）
	game_seconds = server_seconds
	time_scale = server_scale
	_client_baseline_seconds = server_seconds
	_client_baseline_local_ts = Time.get_ticks_msec() / 1000.0
	if not _clock_synced:
		_seed_emission_baseline()
		_clock_synced = true
		clock_synced.emit()


func _seed_emission_baseline() -> void:
	_last_emitted_hour = int(game_seconds / SECONDS_PER_GAME_HOUR)
	_last_emitted_ten_minute = int(game_seconds / TEN_MINUTE_GAME_SECONDS)


func _emit_ticks_up_to(seconds: float) -> void:
	var current_hour := int(seconds / SECONDS_PER_GAME_HOUR)
	var current_ten_minute := int(seconds / TEN_MINUTE_GAME_SECONDS)
	while _last_emitted_ten_minute < current_ten_minute:
		_last_emitted_ten_minute += 1
		ten_minute_tick.emit(_last_emitted_ten_minute * 10)
	while _last_emitted_hour < current_hour:
		_last_emitted_hour += 1
		slow_tick.emit(_last_emitted_hour)


func _exit_tree() -> void:
	_save_clock_state()


# 当前 game time accessor。回调侧用 slow_tick 信号；要查询绝对 game time 用这些。
func game_hour() -> int:
	return int(game_seconds / SECONDS_PER_GAME_HOUR) % HOURS_PER_GAME_DAY


func game_minute() -> int:
	return int(game_seconds / SECONDS_PER_GAME_MINUTE) % 60


func game_day() -> int:
	return int(game_seconds / SECONDS_PER_GAME_HOUR) / HOURS_PER_GAME_DAY


func total_game_hours() -> int:
	return int(game_seconds / SECONDS_PER_GAME_HOUR)


func total_game_minutes() -> int:
	return int(game_seconds / SECONDS_PER_GAME_MINUTE)


# ── 派生量纯函数 ──────────────────────────────────────────────
# tick handler / mechanic ctx 拿到的是 total_game_hour / total_game_minute；
# 需要 hour-of-day / day / minute-of-hour 时调下面这些，不要自己 % 24。
# 集中在这里方便以后改一年/一周长度。
static func hour_of_day_for_hour(total_hour: int) -> int:
	return total_hour % HOURS_PER_GAME_DAY


static func day_for_hour(total_hour: int) -> int:
	return total_hour / HOURS_PER_GAME_DAY


static func minute_of_hour_for_minute(total_minute: int) -> int:
	return total_minute % 60


static func hour_of_day_for_minute(total_minute: int) -> int:
	return (total_minute / 60) % HOURS_PER_GAME_DAY


static func day_for_minute(total_minute: int) -> int:
	return (total_minute / 60) / HOURS_PER_GAME_DAY


func total_game_seconds() -> int:
	return int(game_seconds)


func game_time_snapshot() -> Dictionary:
	var day := game_day()
	return {
		"totalGameSeconds": total_game_seconds(),
		"totalGameMinutes": total_game_minutes(),
		"totalGameHours": total_game_hours(),
		"day": day,
		"hour": game_hour(),
		"minute": game_minute(),
		"second": total_game_seconds() % int(SECONDS_PER_GAME_MINUTE),
		"year": int(day / DAYS_PER_REIGN_YEAR) + 1,
		"dayOfYear": int(day % DAYS_PER_REIGN_YEAR) + 1,
		"eraName": "统治",
	}


func restore_game_time_snapshot(snapshot: Dictionary) -> bool:
	var restored_seconds := _snapshot_total_seconds(snapshot)
	if restored_seconds < 0.0:
		push_warning("[GameClock] restore ignored: invalid snapshot %s" % str(snapshot))
		return false
	game_seconds = max(restored_seconds, INITIAL_GAME_SECONDS)
	_last_emitted_hour = int(game_seconds / SECONDS_PER_GAME_HOUR)
	_last_emitted_ten_minute = int(game_seconds / TEN_MINUTE_GAME_SECONDS)
	return true


# Debug 入口，给 /timewarp slash 命令调
func set_time_scale(value: float) -> void:
	time_scale = max(0.0, value)


func _snapshot_total_seconds(snapshot: Dictionary) -> float:
	if snapshot.has("totalGameSeconds"):
		return max(0.0, float(snapshot.get("totalGameSeconds")))
	if snapshot.has("total_game_seconds"):
		return max(0.0, float(snapshot.get("total_game_seconds")))
	if snapshot.has("totalGameMinutes"):
		return max(0.0, float(snapshot.get("totalGameMinutes")) * SECONDS_PER_GAME_MINUTE)
	if snapshot.has("total_game_minutes"):
		return max(0.0, float(snapshot.get("total_game_minutes")) * SECONDS_PER_GAME_MINUTE)
	if snapshot.has("totalGameHours"):
		return max(0.0, float(snapshot.get("totalGameHours")) * SECONDS_PER_GAME_HOUR + _snapshot_minute(snapshot) * SECONDS_PER_GAME_MINUTE + _snapshot_second(snapshot))
	if snapshot.has("total_game_hours"):
		return max(0.0, float(snapshot.get("total_game_hours")) * SECONDS_PER_GAME_HOUR + _snapshot_minute(snapshot) * SECONDS_PER_GAME_MINUTE + _snapshot_second(snapshot))
	if snapshot.has("day") and snapshot.has("hour") and snapshot.has("minute"):
		return max(0.0, (float(snapshot.get("day")) * SECONDS_PER_GAME_DAY) + (float(snapshot.get("hour")) * SECONDS_PER_GAME_HOUR) + (_snapshot_minute(snapshot) * SECONDS_PER_GAME_MINUTE) + _snapshot_second(snapshot))
	return -1.0


func _snapshot_minute(snapshot: Dictionary) -> float:
	if snapshot.has("minute"):
		return float(snapshot.get("minute"))
	if snapshot.has("gameMinute"):
		return float(snapshot.get("gameMinute"))
	if snapshot.has("game_minute"):
		return float(snapshot.get("game_minute"))
	return 0.0


func _snapshot_second(snapshot: Dictionary) -> float:
	if snapshot.has("second"):
		return float(snapshot.get("second"))
	if snapshot.has("gameSecond"):
		return float(snapshot.get("gameSecond"))
	if snapshot.has("game_second"):
		return float(snapshot.get("game_second"))
	return 0.0


func _tick_persistence(delta: float) -> void:
	if not RunMode.is_runtime():
		return
	_persist_timer -= delta
	if _persist_timer > 0.0:
		return
	_persist_timer = max(0.1, persist_interval_sec)
	_save_clock_state()
	# 同节奏广播给所有 client。multiplayer 还没建好（启动早期）就跳过——
	# peer_connected 那条路会兜底为后续每个新 peer 单独推。
	if multiplayer.has_multiplayer_peer():
		push_clock.rpc(game_seconds, time_scale)


func _load_persisted_clock() -> void:
	var saved := Db.get_town_clock_seconds()
	if saved < 0.0:
		# 无记录：保持默认 06:00 开服
		return
	if not restore_game_time_snapshot({"totalGameSeconds": saved}):
		push_warning("[GameClock] failed to restore from db: total=%f" % saved)


func _save_clock_state() -> void:
	if not RunMode.is_runtime():
		return
	Db.save_town_clock_seconds(game_seconds)
