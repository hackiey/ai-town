-- Fermenting mechanic: 容器槽位被动发酵 → 自动 swap 成酒类成品。
-- 由 Containers.tick_fermenting 每 game-hour 对每个 passive_tags 含 "fermenting" 的容器
-- 的槽位调一次。结构与 data/mechanics/drying.lua 完全平行，只是 age 字段独立
-- （fermenting_age_hours），以免与晾晒计时混淆。
--
-- ctx (per slot, per call):
--   holder           : ContainerNode
--   slot_index       : int
--   slot             : 当前 slot 数据快照 (含 fermenting_age_hours / quantity)
--   hours            : float (推进多少小时，目前固定 1.0)
--   fermenting_hours : float (从 item.fermenting_hours 来；阈值)
--   swap_to          : { item_id, materials, shape_type, tags }
--   yield_qty        : int (每份原料产出几份产品；默认 1)
--
-- 不返回值；通过 affect.set_slot_state 写回。

function on_ferment(ctx)
    local age = (ctx.slot.fermenting_age_hours or 0) + (ctx.hours or 0)
    if age < ctx.fermenting_hours then
        affect.set_slot_state(ctx.holder, ctx.slot_index, {
            fermenting_age_hours = age,
        })
        return
    end
    -- 到点，swap 成成品。原料 quantity * yield_qty 决定产物数量。
    local input_qty = ctx.slot.quantity or 1
    local out_qty = input_qty * (ctx.yield_qty or 1)
    affect.set_slot_state(ctx.holder, ctx.slot_index, {
        item_id              = ctx.swap_to.item_id,
        materials            = ctx.swap_to.materials,
        shape_type           = ctx.swap_to.shape_type,
        tags                 = ctx.swap_to.tags,
        quality              = 100,
        quantity             = out_qty,
        fermenting_age_hours = 0.0,
    })
end
