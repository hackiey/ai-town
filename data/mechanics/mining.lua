-- Mining mechanic: 固定成功率 + 挖矿开销。
--
--   on_attempt(ctx)      WorkstationActionRunner 每次挖矿调；返回是否产出 (bool)
--   on_attempt_cost(ctx) 返回挖矿开销 { stamina_cost, interval_game_seconds, duration_seconds }
--
-- ctx (on_attempt):
--   current_p (float)  由 Mines.try_yield 从 mine_state.currentP 取并传入
--   返回 true / false
--
-- 成功率每矿固定，真值在 src/autoload/mines.gd 的 _FIXED_P；运行时不自调节。

-- 挖矿开销唯一真值。stamina_cost 每次 attempt 扣；interval 是两次 attempt 间隔；
-- duration 是一次 dig action 总时长。GDScript 通过 Mines.attempt_cost() 读取。
local ATTEMPT_STAMINA_COST     = 6.0
local ATTEMPT_INTERVAL_SECONDS = 600.0
local ACTION_DURATION_SECONDS  = 3600.0


function on_attempt(ctx)
    return math.random() < ctx.current_p
end


function on_attempt_cost(_ctx)
    return {
        stamina_cost = ATTEMPT_STAMINA_COST,
        interval_game_seconds = ATTEMPT_INTERVAL_SECONDS,
        duration_seconds = ACTION_DURATION_SECONDS,
    }
end
