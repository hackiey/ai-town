-- Drying mechanic: 容器槽位被动晾干 → 自动 swap 成种子/晒品。
-- 由 Containers.tick_drying 每 game-hour 对每个 passive_tags 含 "drying" 的容器
-- 的槽位调一次。
--
-- ctx (per slot, per call):
--   holder        : ContainerNode (任何 InventoryAdapter 支持的 holder)
--   slot_index    : int
--   slot          : 当前 slot 数据快照 (含 drying_age_hours / quantity)
--   hours         : float (推进多少小时，目前固定 1.0)
--   drying_hours  : float (从 item.drying_hours 来；阈值)
--   swap_to       : { item_id, materials, shape_type, tags } (GDScript 端预查的"晾干后变什么")
--   yield_qty     : int (每份原料产出几份产品；默认 1)
--
-- 不返回值；通过 affect.set_slot_state 写回。
-- displayed_effects 不需要 lua 端显式 recompute —— set_slot_state 在 GDScript 侧
-- 会自动 ItemEffects.recompute_slot（见 inventory_adapter）。

function on_dry(ctx)
    local age = (ctx.slot.drying_age_hours or 0) + (ctx.hours or 0)
    if age < ctx.drying_hours then
        affect.set_slot_state(ctx.holder, ctx.slot_index, {
            drying_age_hours = age,
        })
        return
    end
    -- 到点，swap 成产物。原料 quantity * yield_qty 决定产物数量。
    local input_qty = ctx.slot.quantity or 1
    local out_qty = input_qty * (ctx.yield_qty or 1)
    affect.set_slot_state(ctx.holder, ctx.slot_index, {
        item_id          = ctx.swap_to.item_id,
        materials        = ctx.swap_to.materials,
        shape_type       = ctx.swap_to.shape_type,
        tags             = ctx.swap_to.tags,
        quality          = 100,
        quantity         = out_qty,
        drying_age_hours = 0.0,
    })
end
