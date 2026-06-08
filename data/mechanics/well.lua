-- Well mechanic: draw-water cost.
--
-- GDScript asks on_draw_cost(ctx) with ctx.amount_liters = attempted liters.
-- Costs scale linearly from the design baseline: 20L = 3 game minutes + 3 stamina.

local BASE_LITERS = 20.0
local BASE_DURATION_SECONDS = 180.0
local BASE_STAMINA_COST = 3.0


function on_draw_cost(ctx)
    local amount = tonumber(ctx.amount_liters) or BASE_LITERS
    if amount < 0.0 then amount = 0.0 end
    local scale = amount / BASE_LITERS
    return {
        duration_seconds = BASE_DURATION_SECONDS * scale,
        stamina_cost = BASE_STAMINA_COST * scale,
    }
end
