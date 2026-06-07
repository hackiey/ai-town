-- Crops mechanic: 作物 variety 数据 + 种植规则。
--
-- Hooks (server only):
--   on_crop_tick(ctx)          每 game-hour 一次，每株作物：累 care 分、推 stage、算 maturity
--   on_farm_moisture_tick(ctx) 每 game-hour 一次，每片田：moisture decay
--   on_pest_tick(ctx)          每 game-hour 一次，每片田：日上限 + 概率 + 选作物
--   on_harvest(ctx)            玩家/NPC 触发：算产量、给物、销毁/重置
--
-- Queries (GDScript 端读 variety 数据用):
--   get_variety(id)            完整 variety dict
--   variety_ids()              所有 id 数组
--   pest_eligible_stage(id, stage_name)
--   is_ripe_stage(id, stage_name)
--
-- 设计：lua 不持有 mutable 状态。crop / farm 节点字段更新通过 affect.crop_state /
-- affect.farm_state 声明，由 GDScript Effects.apply 端写入并 persist。

-- ============== 内容数据 ==============

varieties = {
    tomato = {
        id = "tomato",
        display_name = "番茄",
        stages = {"seed", "sprout", "vegetative", "flowering", "ripe"},
        maturation_hours = 80,
        harvest_returns_to_stage = "",
        max_harvests = 1,
        yield_decay_per_harvest = 1.0,
        harvest_yield_id = "tomato_fruit",
        harvest_yield_quantity = 3,
        harvest_extra_yields = {},
        moisture_decay_per_hour = 0.5 / 24, -- 满水→0 需 48 game-hour；一天浇一次足够
        optimal_moisture_min = 0.2,
        optimal_moisture_max = 0.8,
        stage_colors = {
            {0.4, 0.3, 0.2, 1},
            {0.6, 0.8, 0.3, 1},
            {0.3, 0.7, 0.2, 1},
            {0.5, 0.7, 0.3, 1},
            {0.9, 0.2, 0.1, 1},
        },
        stage_scales = {0.35, 0.55, 0.8, 1.0, 1.15},
    },
    wheat = {
        id = "wheat",
        display_name = "小麦",
        stages = {"seed", "sprout", "vegetative", "flowering", "ripe"},
        maturation_hours = 72,
        harvest_returns_to_stage = "",
        max_harvests = 1,
        yield_decay_per_harvest = 1.0,
        harvest_yield_id = "wheat",
        harvest_yield_quantity = 4,
        harvest_extra_yields = {},
        moisture_decay_per_hour = 0.5 / 24, -- 满水→0 需 48 game-hour；一天浇一次足够
        optimal_moisture_min = 0.2,
        optimal_moisture_max = 0.8,
        stage_colors = {
            {0.42, 0.32, 0.18, 1},
            {0.55, 0.78, 0.28, 1},
            {0.36, 0.68, 0.22, 1},
            {0.74, 0.70, 0.28, 1},
            {0.88, 0.74, 0.33, 1},
        },
        stage_scales = {0.3, 0.5, 0.78, 1.0, 1.08},
    },
    flax = {
        id = "flax",
        display_name = "亚麻",
        stages = {"seed", "sprout", "vegetative", "flowering", "ripe"},
        maturation_hours = 72,
        harvest_returns_to_stage = "",
        max_harvests = 1,
        yield_decay_per_harvest = 1.0,
        harvest_yield_id = "flax_bundle",
        harvest_yield_quantity = 3,
        harvest_extra_yields = {},
        moisture_decay_per_hour = 0.5 / 24, -- 满水→0 需 48 game-hour；一天浇一次足够
        optimal_moisture_min = 0.2,
        optimal_moisture_max = 0.8,
        stage_colors = {
            {0.34, 0.25, 0.16, 1},
            {0.50, 0.72, 0.30, 1},
            {0.34, 0.63, 0.38, 1},
            {0.42, 0.58, 0.82, 1},
            {0.72, 0.67, 0.42, 1},
        },
        stage_scales = {0.3, 0.5, 0.76, 0.95, 1.05},
    },
}

-- ============== 常量（规则）==============

local WATER_CARE_SCORE = 0.5
local PEST_CARE_SCORE  = 0.5

-- 农事动作开销：唯一真值。GDScript 通过 Farming.resolve_action_cost(kind) 读取，
-- 由 StaminaWallet 在 commit 时扣体力，由 farm 队列读 duration_seconds 设 working 时长。
local ACTION_COSTS = {
    plant   = { stamina_cost = 3.0,  duration_seconds = 60.0  },
    harvest = { stamina_cost = 3.0,  duration_seconds = 60.0  },
    uproot  = { stamina_cost = 3.0,  duration_seconds = 120.0 },
    pest    = { stamina_cost = 3.0,  duration_seconds = 120.0 },
    water   = { stamina_cost = 10.0, duration_seconds = 900.0 },
}

-- ============== utilities ==============

local function index_of(arr, target)
    for i, v in ipairs(arr) do
        if v == target then return i end
    end
    return -1
end

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function harvest_quantity(base_qty, harvests_done, decay, maturity_int)
    local qty_f = base_qty
    qty_f = qty_f * (decay ^ harvests_done)
    qty_f = qty_f * (maturity_int / 100.0)
    local qty = math.floor(qty_f + 0.5)
    if qty < 1 then qty = 1 end
    return qty
end

local function grant_harvest_item(ctx, item_id, base_qty, v)
    if not item_id or item_id == "" or not base_qty or base_qty <= 0 then return end
    local qty = harvest_quantity(base_qty, ctx.harvests_done, v.yield_decay_per_harvest, ctx.maturity_int)
    -- 醉酒/生病：收获量按 GDScript 算好的乘子缩水（清醒时为 1.0）。至少保 1。
    local mult = ctx.harvest_yield_mult or 1.0
    if mult < 1.0 then
        qty = math.floor(qty * mult + 0.5)
        if qty < 1 then qty = 1 end
    end
    affect.give_item(ctx.harvester, item_id, qty, ctx.maturity_int)
end

-- ============== queries (GDScript 端用) ==============

function get_variety(id)
    return varieties[id]
end

function variety_ids()
    local out = {}
    for k, _ in pairs(varieties) do table.insert(out, k) end
    return out
end

function is_ripe_stage(variety_id, stage)
    local v = varieties[variety_id]
    if not v or #v.stages == 0 then return false end
    return stage == v.stages[#v.stages]
end

-- 由 spawn 时间 + variety 推 stage（hydrate / fresh spawn 走这里，不走 tick）
-- 两个参数都是自开服累计 game-hour，调用方保证 current_total_hour >= spawned_at_total_hour。
function compute_stage(variety_id, spawned_at_total_hour, current_total_hour)
    local v = varieties[variety_id]
    if not v or #v.stages == 0 then return "" end
    local elapsed = current_total_hour - spawned_at_total_hour
    local n = #v.stages
    local progress = elapsed / math.max(1, v.maturation_hours)
    local idx = math.floor(progress * n) + 1
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    return v.stages[idx]
end

function compute_maturity(care_sum, care_count)
    if care_count <= 0 then return 100 end
    local ratio = care_sum / care_count
    local m = math.floor(ratio * 100 + 0.5)
    if m < 1 then m = 1 end
    if m > 100 then m = 100 end
    return m
end

-- 易感期：从 vegetative 起算（找不到 vegetative 时退化为 idx>=2）
function pest_eligible_stage(variety_id, stage)
    local v = varieties[variety_id]
    if not v then return false end
    local idx = index_of(v.stages, stage)
    if idx < 0 then return false end
    local veg = index_of(v.stages, "vegetative")
    if veg < 0 then return idx >= 2 end
    return idx >= veg
end

-- ============== hooks ==============

-- 农事动作 cost 查询：ctx = {kind}，返回 {stamina_cost, duration_seconds}。
-- 未知 kind 返回 0/0，由 runner 决定怎么处理（一般直接拒）。
function on_action_cost(ctx)
    local entry = ACTION_COSTS[ctx.kind]
    if not entry then return { stamina_cost = 0.0, duration_seconds = 0.0 } end
    return { stamina_cost = entry.stamina_cost, duration_seconds = entry.duration_seconds }
end


-- 每 game-hour 一次，每株作物。
-- ctx: { crop, variety_id, spawned_at_total_hour, care_sum, care_count, moisture, has_pest, current_total_hour }
-- 时间字段命名约定：*_total_hour 是自开服累计 hour 真值；调用方保证
-- current_total_hour >= spawned_at_total_hour（GD 侧 assert 把关）。
function on_crop_tick(ctx)
    local v = varieties[ctx.variety_id]
    if not v then return end

    -- 1) 累加这一小时的照料分
    local hour_score = 0
    if ctx.moisture >= v.optimal_moisture_min and ctx.moisture <= v.optimal_moisture_max then
        hour_score = hour_score + WATER_CARE_SCORE
    end
    if not ctx.has_pest then
        hour_score = hour_score + PEST_CARE_SCORE
    end
    local new_sum = ctx.care_sum + hour_score
    local new_count = ctx.care_count + 1

    -- 2) maturity int (1..100)
    local maturity = 100
    if new_count > 0 then
        local ratio = new_sum / new_count
        maturity = math.floor(ratio * 100 + 0.5)
        maturity = clamp(maturity, 1, 100)
    end

    -- 3) stage 由时间进度推
    local stage = compute_stage(ctx.variety_id, ctx.spawned_at_total_hour, ctx.current_total_hour)

    affect.crop_state(ctx.crop, {
        care_score_sum = new_sum,
        care_score_count = new_count,
        maturity_int = maturity,
        stage = stage,
    })
end

-- 每 game-hour 一次，每片田。
-- ctx: { farm, decay_per_hour }   (decay 由 GDScript 算 _crops_on_field 的 max)
function on_farm_moisture_tick(ctx)
    local cur = ctx.moisture or 0
    local new_moisture = clamp(cur - ctx.decay_per_hour, 0, 1)
    affect.farm_state(ctx.farm, { moisture = new_moisture })
end

-- 每 game-hour 一次，每片田。
-- ctx: { farm, eligible_crops (array of crop nodes), pest_count_today, max_per_day,
--        last_processed_day, game_day, prob }
function on_pest_tick(ctx)
    -- 跨日重置 count
    local count = ctx.pest_count_today
    if ctx.game_day ~= ctx.last_processed_day then
        count = 0
    end
    -- 总是把 last_processed_day 推进，避免每天第一次 tick 重置时丢字段
    local base_state = {
        last_processed_day = ctx.game_day,
        pest_count_today = count,
    }
    if count >= ctx.max_per_day then
        affect.farm_state(ctx.farm, base_state)
        return
    end
    if math.random() >= ctx.prob then
        affect.farm_state(ctx.farm, base_state)
        return
    end
    if #ctx.eligible_crops == 0 then
        affect.farm_state(ctx.farm, base_state)
        return
    end
    local pick = ctx.eligible_crops[math.random(1, #ctx.eligible_crops)]
    affect.crop_state(pick, { has_pest = true })
    affect.farm_state(ctx.farm, {
        last_processed_day = ctx.game_day,
        pest_count_today = count + 1,
    })
end

-- 玩家/NPC 收割。GDScript 端先校验 ripe + 拿 harvester 节点。
-- ctx: { crop, harvester, variety_id, maturity_int, harvests_done, current_total_hour }
-- return non-empty string → reject (不生效)
function on_harvest(ctx)
    local v = varieties[ctx.variety_id]
    if not v then return "unknown variety: " .. tostring(ctx.variety_id) end

    -- 产量 = base × decay^harvests × quality_mult。quality_mult 用 maturity/100 线性。
    -- 一次收获可以同时给主产物和种子等副产物。
    grant_harvest_item(ctx, v.harvest_yield_id, v.harvest_yield_quantity, v)
    for _, y in ipairs(v.harvest_extra_yields or {}) do
        grant_harvest_item(ctx, y.item_id, y.quantity, v)
    end

    local new_done = ctx.harvests_done + 1
    -- max_harvests 上限或单收作物 → 销毁
    if (v.max_harvests > 0 and new_done >= v.max_harvests)
        or v.harvest_returns_to_stage == "" then
        affect.crop_destroy(ctx.crop)
        return
    end

    -- Multi-harvest reset：spawned_at 回退到 harvest_returns_to_stage 对应时间，评分清零
    local rollback_idx = index_of(v.stages, v.harvest_returns_to_stage)
    if rollback_idx < 0 then rollback_idx = 1 end
    local target_progress = (rollback_idx - 1) / #v.stages
    local offset = math.floor(target_progress * v.maturation_hours + 0.5)
    affect.crop_state(ctx.crop, {
        spawned_at_game_hour = ctx.current_total_hour - offset,
        care_score_sum = 0,
        care_score_count = 0,
        maturity_int = 100,
        harvests_done = new_done,
    })
end
