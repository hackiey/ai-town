-- Well mechanic: 水井 direct workstation 的体力/耗时数值。
--
-- Hooks:
--   on_draw_cost(ctx) → { stamina_cost, duration_seconds }
--
-- 设计：water = bucket.properties 原地填充，不是 item 变换，所以走不了 crafting.lua reaction
-- 套路；well 单独一个 mechanic 文件。Runner 通过 Wells.draw_cost() 拿数值，StaminaWallet 扣体力。

function on_draw_cost(_ctx)
    return {
        stamina_cost = 3.0,
        duration_seconds = 180.0,
    }
end
