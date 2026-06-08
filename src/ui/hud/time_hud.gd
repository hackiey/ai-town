class_name TimeHud
extends CanvasLayer

# 屏幕顶部时间栏：年/月/日/周几/时间。
# 数据从 GameClock autoload 拉：360 天/年 → 12 月 × 30 日；7 天周（game_day % 7）。
# 初始为统治五年3月4日 06:00；weekday offset 保证该日显示为周二。
# 刷新：ten_minute_tick（10 game-min 一次）足够细，省得每帧 _process 重渲。

const WEEKDAY_NAMES := ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
const DAYS_PER_MONTH := 30
const MONTHS_PER_YEAR := 12
const GAME_WEEKDAY_OFFSET := 3

@onready var _label: Label = $Root/Panel/Label


func _ready() -> void:
	GameClock.ten_minute_tick.connect(_on_tick)
	GameClock.slow_tick.connect(_on_slow_tick)
	GameClock.clock_synced.connect(_refresh)
	_refresh()


func _on_tick(_total_minute: int) -> void:
	_refresh()


func _on_slow_tick(_total_hour: int) -> void:
	_refresh()


func _refresh() -> void:
	if not GameClock.is_clock_synced():
		# client 首次 sync 到达前显示占位，避免闪一下默认 06:00 再跳到真实时间
		_label.text = "—— · —— · ——:——"
		return
	var snap := GameClock.game_time_snapshot()
	var year := int(snap.get("year", 1))
	var day_of_year := int(snap.get("dayOfYear", 1)) - 1  # 0-indexed
	var month := int(day_of_year / DAYS_PER_MONTH) + 1
	var day_of_month := (day_of_year % DAYS_PER_MONTH) + 1
	var weekday: String = WEEKDAY_NAMES[(int(snap.get("day", 0)) + GAME_WEEKDAY_OFFSET) % WEEKDAY_NAMES.size()]
	var hour := int(snap.get("hour", 0))
	var minute := int(snap.get("minute", 0))
	_label.text = "%d 年 %d 月 %d 日 · %s · %02d:%02d" % [year, month, day_of_month, weekday, hour, minute]
