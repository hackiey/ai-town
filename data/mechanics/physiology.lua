-- Physiology mechanic: 角色生理 tick。
--
-- Hooks (server only):
--   on_slow_tick(ctx)       每 10 game-minutes 一次：hunger/rest/stamina 结算 / hungry 阈值进出 / 饿死扣血 / 死亡
--   on_hunger_changed(ctx)  hunger 主动变化后（吃 / 喝 / heal item）只复检 hungry 阈值
--
-- ctx.character 是 Character node，作为 affect.* 的 target token；lua 不读它的字段，
-- 所有数值都通过 ctx 顶层字段传入（hp / stamina / hunger / has_hungry...）保证 lua 不反查 GDScript。

-- ============== 常量（可被 GDScript MechanicHost.query 读）==============

rest_decay_per_game_hour    = 2.0   -- 100 → 0 约 50 小时清醒
stamina_regen_per_tick      = 5.0   -- 标准恢复速度：每 10 游戏分钟 +5
hungry_threshold            = 50    -- hunger ≤ 50 → 加 hungry status
clear_threshold             = 70    -- hunger ≥ 70 → 清 hungry status（hysteresis 防抖）
starving_hp_loss_per_hour   = 2.0   -- hunger == 0 时每小时扣血

-- 线性 hunger 衰减：醒着 5/h，睡觉 1.25/h（睡眠 = 清醒 25%，慢但不为零防止"睡觉省饭"）
-- 24h 总耗 = 16×5 + 8×1.25 = 90 ≈ 三餐 × 30；起床 ~65 → 早饭前 55 → 晚饭后 95 闭环。
-- 额外的"体力活惩罚"在 StaminaWallet.try_spend 里走（每消耗 1 stamina → -0.1 hunger）。
hunger_decay_awake_per_hour = 5.0
hunger_decay_sleep_per_hour = 1.25

-- ============== 内部 helper ==============

local function _check_hungry_threshold(target, hunger, has_hungry)
    if hunger <= hungry_threshold and not has_hungry then
        -- expires_total_hours = 0 → 永久（由阈值清理，不靠过期 tick）
        affect.add_status(target, "hungry", 0, "hunger_decay")
    elseif hunger >= clear_threshold and has_hungry then
        affect.remove_status(target, "hungry")
    end
end

local function _clamp(value, lo, hi)
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

local function _hunger_percent(hunger, max_hunger)
    if (max_hunger or 0) <= 0 then return 0 end
    return _clamp((hunger or 0) / max_hunger * 100.0, 0.0, 100.0)
end

local function _hunger_stamina_cap_ratio(hunger_percent)
    if hunger_percent >= 70.0 then return 1.00 end
    if hunger_percent >= 50.0 then return 0.70 end
    if hunger_percent >= 30.0 then return 0.55 end
    if hunger_percent >= 15.0 then return 0.35 end
    if hunger_percent >= 5.0 then return 0.20 end
    if hunger_percent > 0.0 then return 0.10 end
    return 0.05
end

local function _stamina_move_speed_ratio(stamina_percent)
    if stamina_percent >= 30.0 then return 1.00 end
    if stamina_percent >  0.0  then return 0.50 + 0.50 * (stamina_percent / 30.0) end
    return 0.50
end

local function _hunger_stamina_regen_ratio(hunger_percent)
    if hunger_percent >= 70.0 then return 1.00 end
    if hunger_percent >= 50.0 then return 0.70 end
    if hunger_percent >= 30.0 then return 0.40 end
    if hunger_percent >= 15.0 then return 0.20 end
    if hunger_percent >= 5.0 then return 0.05 end
    return 0.00
end

local function _rest_ratio(rest, max_rest)
    if (max_rest or 0) <= 0 then return 0 end
    return _clamp((rest or 0) / max_rest, 0.0, 1.0)
end

local function _stamina_cap(max_stamina, hunger_percent, rest, max_rest)
    local rest_cap = max_stamina * _rest_ratio(rest, max_rest)
    local hunger_cap = max_stamina * _hunger_stamina_cap_ratio(hunger_percent)
    return math.min(max_stamina, hunger_cap, rest_cap)
end

function effective_stamina_max(max_stamina, hunger, max_hunger, rest, max_rest)
    local hunger_percent = _hunger_percent(hunger, max_hunger)
    return _stamina_cap(max_stamina or 100, hunger_percent, rest, max_rest)
end

-- 体力 / max_stamina 比值 < 30% 时线性减速到 50%；≥ 30% 满速；为 0 不锁死。
function move_speed_mult(stamina, max_stamina)
    local pct = 0.0
    if (max_stamina or 0) > 0 then
        pct = _clamp((stamina or 0) / max_stamina * 100.0, 0.0, 100.0)
    end
    return _stamina_move_speed_ratio(pct)
end

-- ============== hooks ==============

-- ctx: { character, hp, max_hp, stamina, max_stamina, hunger, max_hunger, rest, max_rest, is_sleeping, has_hungry }
function on_slow_tick(ctx)
    local tick_hours = ctx.tick_hours or (1.0 / 6.0)
    -- 1) 被动 hunger 衰减：醒/睡两档线性
    local max_hunger = ctx.max_hunger or 100
    local rate = ctx.is_sleeping and hunger_decay_sleep_per_hour or hunger_decay_awake_per_hour
    local new_hunger = (ctx.hunger or 0) - rate * tick_hours
    if new_hunger < 0 then new_hunger = 0 end
    if new_hunger > max_hunger then new_hunger = max_hunger end
    local new_hunger_percent = _hunger_percent(new_hunger, max_hunger)
    if new_hunger ~= ctx.hunger then
        affect.hunger(ctx.character, new_hunger - ctx.hunger)
    end

    -- 2) hungry 阈值进出
    _check_hungry_threshold(ctx.character, new_hunger, ctx.has_hungry)

    -- 3) 清醒时消耗精力。睡眠恢复按实际睡眠秒数在 BackendActionRunner 中推进，避免
    --    30 分钟小睡等不到整点 slow_tick 才生效。
    local current_rest = ctx.rest or 0
    local max_rest = ctx.max_rest or 100
    local new_rest = current_rest
    if not ctx.is_sleeping then
        new_rest = current_rest - (rest_decay_per_game_hour * tick_hours)
        if new_rest < 0 then new_rest = 0 end
        if new_rest > max_rest then new_rest = max_rest end
        if new_rest ~= current_rest then
            affect.rest(ctx.character, new_rest - current_rest)
        end
    end

    -- 4) 体力自然恢复 / 上限压制。行动消耗本身不随饥饿变化；饥饿只压上限和恢复速度。
    local current_stamina = ctx.stamina or 0
    local max_stamina = ctx.max_stamina or 100
    local stamina_cap = _stamina_cap(max_stamina, new_hunger_percent, new_rest, max_rest)
    local new_stamina = current_stamina
    if current_stamina > stamina_cap then
        new_stamina = stamina_cap
    else
        local regen = stamina_regen_per_tick * _hunger_stamina_regen_ratio(new_hunger_percent) * _rest_ratio(new_rest, max_rest)
        new_stamina = current_stamina + regen
        if new_stamina > stamina_cap then new_stamina = stamina_cap end
    end
    if new_stamina ~= current_stamina then
        affect.stamina(ctx.character, new_stamina - current_stamina)
    end

    -- 5) 饿死扣血 + 死亡判定
    if new_hunger <= 0 then
        local hp_loss = starving_hp_loss_per_hour * tick_hours
        if hp_loss > ctx.hp then hp_loss = ctx.hp end
        if hp_loss > 0 then
            affect.hp(ctx.character, -hp_loss)
        end
        if ctx.hp - hp_loss <= 0 then
            affect.set_alive(ctx.character, false)
        end
    end
end

-- 吃 / 喝 / heal 后调；只刷阈值，不做衰减/扣血。
-- ctx: { character, hunger, has_hungry }
function on_hunger_changed(ctx)
    _check_hungry_threshold(ctx.character, ctx.hunger, ctx.has_hungry)
end
