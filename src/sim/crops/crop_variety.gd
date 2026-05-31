class_name CropVariety
extends Resource

# 一种作物的静态参数 carrier。真值在 data/mechanics/crops.lua 的 varieties 表，
# Varieties.by_id 启动时拉一份填充本对象。GDScript 端通过 `crop.variety.X` 读字段。

var id: String = ""
var display_name: String = ""

# Stage 名按顺序排列；最后一个 = ripe（可收获）。
var stages: Array[String] = []

# 从 spawn 到 ripe 阶段的总 game-hour。time_progress = elapsed / maturation_hours。
var maturation_hours: int = 80

# Multi-harvest：harvest 后回到这个 stage。空 = 单收作物。
var harvest_returns_to_stage: String = ""

# Multi-harvest 寿命；-1 = 无限。
var max_harvests: int = -1

# 每次 multi-harvest 后产量额外乘的系数。1.0 = 不衰减。
var yield_decay_per_harvest: float = 1.0

# Harvest 基础产物
var harvest_yield_id: String = ""
var harvest_yield_quantity: int = 1

# Moisture 规则
var moisture_decay_per_hour: float = 0.05
var optimal_moisture_min: float = 0.2
var optimal_moisture_max: float = 0.8

# 视觉 placeholder：每 stage 一个颜色 + 缩放。长度对齐 stages.size()。
var stage_colors: Array[Color] = []
var stage_scales: Array[float] = []
