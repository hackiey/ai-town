extends Node3D

# 昼夜循环。读 GameClock.game_seconds 算出 time_of_day [0,1)，按曲线/渐变写
# Key/Fill DirectionalLight 和 WorldEnvironment.environment（含 sky）。
#
# 模型：单一 Key light 同时扮演太阳和月亮——白天太阳东升西落，夜晚月亮西升
# 东落（视觉反向更有变化），都做 sin 仰角抛物线，永远在地平线以上。Synty 卡通
# 取向：Fill 用冷色补阴影面，ambient 夜里压到 0.08 让月光定调，曲线默认值已
# 调好黄昏/黎明加密 key。
#
# 装配：town.tscn 的 Demo 下加一个 Node3D，附本脚本，inspector 把 key_light /
# fill_light / world_environment 三个 NodePath 拖进去即可；曲线/渐变留空时
# 用 _ensure_defaults() 兜底。WorldEnvironment 的 Environment 资源会在
# _ready 时 duplicate，避免污染 third-party .tres。

@export var key_light_path: NodePath
@export var fill_light_path: NodePath
@export var world_environment_path: NodePath

# 仰角峰值（度）。低于 90° 让 looking_at 不退化，也更像中纬度真实仰角。
@export_range(30.0, 89.0) var max_sun_altitude_deg: float = 70.0
@export_range(20.0, 89.0) var max_moon_altitude_deg: float = 55.0
# 太阳东升西落；月亮反向（视觉差异 + 让构图轮换）。
# 世界约定：城墙大门朝 +X = 南，所以 +X=南 / -X=北 / +Z=东 / -Z=西。
# azimuth 0° 指向 +Z（东），顺时针；东=0°，西=180°，正午 lerp 中点=90°=+X(南)，
# 北半球正午太阳过头顶南侧，恰好经过大门上空。
@export var east_azimuth_deg: float = 0.0
@export var west_azimuth_deg: float = 180.0

# 颜色/能量曲线（null 时用 _ensure_defaults 兜底）。
# 横轴都是 time_of_day [0,1)，0 = 子夜，0.25 = 日出，0.5 = 正午，0.75 = 日落。
@export var sun_color_over_day: Gradient
@export var sun_energy_over_day: Curve
@export var fill_color_over_day: Gradient
@export var fill_energy_over_day: Curve
@export var ambient_color_over_day: Gradient
@export var ambient_energy_over_day: Curve
@export var sky_top_over_day: Gradient
@export var sky_horizon_over_day: Gradient
@export var fog_color_over_day: Gradient
@export var fog_density_over_day: Curve

# 60fps 全速写没必要——0.25s 已经平滑（7× time_scale 下游戏内 ~1.75 game-sec）。
@export var update_interval_sec: float = 0.25

var _key_light: DirectionalLight3D
var _fill_light: DirectionalLight3D
var _world_env: WorldEnvironment
var _env: Environment
var _sky_material: ProceduralSkyMaterial
var _accumulator: float = 0.0


func _ready() -> void:
	_key_light = get_node_or_null(key_light_path) as DirectionalLight3D
	_fill_light = get_node_or_null(fill_light_path) as DirectionalLight3D
	_world_env = get_node_or_null(world_environment_path) as WorldEnvironment
	if _key_light == null or _world_env == null:
		push_warning("[DayNightCycle] missing key_light or world_environment — disabled")
		set_process(false)
		return
	_localize_environment()
	_ensure_defaults()
	_apply(_time_of_day())  # 启动立刻刷一次，避免第一帧用 .tres 残留


func _process(delta: float) -> void:
	_accumulator += delta
	if _accumulator < update_interval_sec:
		return
	_accumulator = 0.0
	_apply(_time_of_day())


func _time_of_day() -> float:
	var day_sec := fmod(GameClock.game_seconds, GameClock.SECONDS_PER_GAME_DAY)
	return day_sec / GameClock.SECONDS_PER_GAME_DAY


# Environment / Sky / SkyMaterial 从 third-party .tres 加载是共享资源——直接写会
# 污染磁盘上的 .tres。duplicate(true) 深拷贝出本场景独享的副本。
func _localize_environment() -> void:
	if _world_env.environment == null:
		return
	_env = _world_env.environment.duplicate(true) as Environment
	_world_env.environment = _env
	if _env.sky != null and _env.sky.sky_material != null:
		_sky_material = _env.sky.sky_material as ProceduralSkyMaterial


func _apply(t: float) -> void:
	# Sun 弧覆盖 t∈[0.22, 0.78]——把"sunrise 时刻"提前到 05:17，让 06:00
	# (t=0.25) 太阳已经在 11° 仰角，避免玩家 spawn 撞上地平线零光的瞬间。
	const DAWN_T := 0.22
	const DUSK_T := 0.78
	const DAY_SPAN := DUSK_T - DAWN_T  # 0.56
	var is_day := t >= DAWN_T and t < DUSK_T
	var body_progress: float
	if is_day:
		body_progress = (t - DAWN_T) / DAY_SPAN
	else:
		var night_t := t if t >= DUSK_T else t + 1.0
		body_progress = (night_t - DUSK_T) / (1.0 - DAY_SPAN)

	var altitude_deg: float
	var azimuth_deg: float
	if is_day:
		altitude_deg = sin(body_progress * PI) * max_sun_altitude_deg
		azimuth_deg = lerp(east_azimuth_deg, west_azimuth_deg, body_progress)
	else:
		altitude_deg = sin(body_progress * PI) * max_moon_altitude_deg
		azimuth_deg = lerp(west_azimuth_deg, east_azimuth_deg, body_progress)

	_aim_light(_key_light, altitude_deg, azimuth_deg)
	# Fill 跟 Key 大致同侧但拉开，让冷暖对比有方向感（不投影）。
	_aim_light(_fill_light, clamp(altitude_deg * 0.6 + 25.0, 20.0, 80.0), azimuth_deg + 70.0)

	if sun_color_over_day:
		_key_light.light_color = sun_color_over_day.sample(t)
	if sun_energy_over_day:
		_key_light.light_energy = sun_energy_over_day.sample(t)
	if _fill_light:
		if fill_color_over_day:
			_fill_light.light_color = fill_color_over_day.sample(t)
		if fill_energy_over_day:
			_fill_light.light_energy = fill_energy_over_day.sample(t)

	if _env:
		if ambient_color_over_day:
			_env.ambient_light_color = ambient_color_over_day.sample(t)
		if ambient_energy_over_day:
			_env.ambient_light_energy = ambient_energy_over_day.sample(t)
		if fog_color_over_day:
			_env.fog_light_color = fog_color_over_day.sample(t)
		if fog_density_over_day:
			_env.fog_density = fog_density_over_day.sample(t)

	if _sky_material:
		if sky_top_over_day:
			_sky_material.sky_top_color = sky_top_over_day.sample(t)
		if sky_horizon_over_day:
			var horizon := sky_horizon_over_day.sample(t)
			_sky_material.sky_horizon_color = horizon
			_sky_material.ground_horizon_color = horizon


func _aim_light(light: DirectionalLight3D, altitude_deg: float, azimuth_deg: float) -> void:
	if light == null:
		return
	var alt_rad := deg_to_rad(altitude_deg)
	var azi_rad := deg_to_rad(azimuth_deg)
	# 天空中的单位方向（指向太阳/月亮）。light 实际传播方向 = -sky_dir。
	var sky_dir := Vector3(
		cos(alt_rad) * sin(azi_rad),
		sin(alt_rad),
		cos(alt_rad) * cos(azi_rad),
	)
	# DirectionalLight3D 沿 local -Z 照射，looking_at(target) 让 -Z 指向 target。
	# 我们要 -Z = -sky_dir，所以 target = -sky_dir。
	var target := -sky_dir
	var up := Vector3.UP if absf(target.y) < 0.999 else Vector3.FORWARD
	light.transform.basis = Basis.looking_at(target, up)


func _ensure_defaults() -> void:
	if sun_color_over_day == null:
		sun_color_over_day = _grad([
			[0.00, Color(0.55, 0.70, 1.00)],   # 子夜：冷蓝月光
			[0.22, Color(0.50, 0.55, 0.85)],   # 黎明前
			[0.26, Color(1.00, 0.55, 0.35)],   # 日出：橙红
			[0.35, Color(1.00, 0.85, 0.65)],   # 朝阳
			[0.50, Color(1.00, 0.96, 0.85)],   # 正午：暖白
			[0.65, Color(1.00, 0.85, 0.65)],   # 下午
			[0.74, Color(1.00, 0.65, 0.40)],   # 黄昏前段：依然金黄（magic hour）
			[0.78, Color(1.00, 0.45, 0.25)],   # 日落瞬间：饱和橙红
			[0.82, Color(0.65, 0.40, 0.70)],   # 日落后：紫
			[1.00, Color(0.55, 0.70, 1.00)],
		])
	if sun_energy_over_day == null:
		# 白天保持在阈值（1.05）以下，不无脑 bloom；只在 magic hour 顶上去让金色 bloom
		sun_energy_over_day = _curve([
			[0.00, 0.35],
			[0.20, 0.20],
			[0.25, 0.95],   # 06:00 朝阳：贴近阈值，亮白墙偶尔会 bloom
			[0.35, 0.95],
			[0.50, 0.95],   # 正午：保持白天清爽，不触发 bloom
			[0.65, 1.05],
			[0.72, 1.70],   # magic hour：橙红 luminance 低，要顶高才过阈值
			[0.77, 1.60],   # 日落瞬间
			[0.79, 0.50],   # 日落后开始降
			[0.82, 0.10],
			[0.85, 0.25],
			[1.00, 0.35],
		])
	if fill_color_over_day == null:
		fill_color_over_day = _grad([
			[0.00, Color(0.30, 0.40, 0.70)],   # 夜：冷蓝
			[0.25, Color(0.65, 0.55, 0.80)],   # 日出：粉紫
			[0.50, Color(0.65, 0.78, 1.00)],   # 正午：天空蓝
			[0.75, Color(0.80, 0.55, 0.70)],   # 日落：粉紫
			[1.00, Color(0.30, 0.40, 0.70)],
		])
	if fill_energy_over_day == null:
		fill_energy_over_day = _curve([
			[0.00, 0.10],
			[0.25, 0.22],
			[0.50, 0.45],
			[0.75, 0.22],
			[1.00, 0.10],
		])
	if ambient_color_over_day == null:
		# 关键：晨/夕的 ambient 要走冷色（天空 zenith 是冷蓝，与暖 key 形成对比），
		# 这是"金色 magic hour"成立的根本。中午允许偏暖，是因为太阳直射。
		ambient_color_over_day = _grad([
			[0.00, Color(0.30, 0.40, 0.60)],   # 夜：冷蓝灰，配月光
			[0.25, Color(0.70, 0.78, 0.88)],   # 晨：冷蓝灰
			[0.50, Color(0.92, 0.92, 0.92)],   # 午：中性白
			[0.72, Color(0.55, 0.65, 0.85)],   # 黄昏前段：明显冷蓝
			[0.78, Color(0.45, 0.50, 0.78)],   # 日落：深冷蓝紫
			[1.00, Color(0.30, 0.40, 0.60)],
		])
	if ambient_energy_over_day == null:
		# 夕阳压低 ambient，把对比让给金色 key light；ambient 太亮会糊掉 bloom
		ambient_energy_over_day = _curve([
			[0.00, 0.08],   # 夜：极低，让月光定调
			[0.25, 0.35],
			[0.50, 0.70],
			[0.72, 0.30],   # 黄昏：压低
			[0.78, 0.22],   # 日落：更低
			[0.85, 0.18],
			[1.00, 0.08],
		])
	if sky_top_over_day == null:
		sky_top_over_day = _grad([
			[0.00, Color(0.02, 0.03, 0.10)],
			[0.22, Color(0.10, 0.10, 0.25)],
			[0.27, Color(0.50, 0.45, 0.65)],
			[0.40, Color(0.30, 0.55, 0.85)],
			[0.50, Color(0.15, 0.56, 0.77)],
			[0.60, Color(0.30, 0.55, 0.85)],
			[0.73, Color(0.55, 0.40, 0.55)],
			[0.78, Color(0.20, 0.15, 0.35)],
			[1.00, Color(0.02, 0.03, 0.10)],
		])
	if sky_horizon_over_day == null:
		sky_horizon_over_day = _grad([
			[0.00, Color(0.08, 0.10, 0.20)],
			[0.25, Color(1.00, 0.55, 0.35)],
			[0.50, Color(0.67, 0.72, 0.77)],
			[0.75, Color(1.00, 0.45, 0.30)],
			[1.00, Color(0.08, 0.10, 0.20)],
		])
	if fog_color_over_day == null:
		fog_color_over_day = _grad([
			[0.00, Color(0.20, 0.28, 0.45)],   # 夜：冷蓝
			[0.25, Color(0.78, 0.78, 0.82)],   # 晨：中性浅灰带一点冷（不要粉）
			[0.50, Color(0.80, 0.85, 0.92)],   # 午：浅冷灰
			[0.75, Color(0.85, 0.70, 0.62)],   # 夕：暖灰（不要饱和橙）
			[1.00, Color(0.20, 0.28, 0.45)],
		])
	if fog_density_over_day == null:
		# 整体降 3×；aerial_perspective 让远处自动混入天空色，密度不需要拉高
		fog_density_over_day = _curve([
			[0.00, 0.0050],
			[0.25, 0.0025],
			[0.50, 0.0012],
			[0.75, 0.0030],
			[1.00, 0.0050],
		])


func _grad(points: Array) -> Gradient:
	var g := Gradient.new()
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_LINEAR
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for p in points:
		offsets.append(p[0])
		colors.append(p[1])
	g.offsets = offsets
	g.colors = colors
	return g


func _curve(points: Array) -> Curve:
	var c := Curve.new()
	for p in points:
		c.add_point(Vector2(p[0], p[1]))
	return c
