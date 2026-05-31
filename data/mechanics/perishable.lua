-- Perishable mechanic: 物品鲜度衰减 + tier=0 时 swap 成腐烂物。
-- 由 CharacterInventory.tick_spoilage 每 game-hour 对每个 perishable slot 调一次。
--
-- ctx (per slot, per call):
--   holder           : Character / ContainerNode (任何 InventoryAdapter 支持的 holder)
--   slot_index       : int
--   slot             : 当前 slot 数据快照 (含 freshness_tier / freshness_age_hours)
--   shelf_life_hours : float (从 substance.shelf_life_hours 来)
--   hours            : float (推进多少小时，目前固定 1.0)
--   rotten_swap      : { item_id, materials, shape_type, tags } | nil
--                      GDScript 端预查的"腐烂后变成什么"；nil = 没目标，tier 锁 0
--
-- 不返回值；通过 affect.set_slot_state 写回。
-- displayed_effects 不需要 lua 端显式 recompute —— set_slot_state 在 GDScript 侧
-- 会自动 ItemEffects.recompute_slot（见 inventory_adapter）。
--
-- 设计：tier 步长 = shelf_life / 5 small ticks；累 age 跨阈值 → tier-1，age 减阈值。
-- tier=0 → 整槽 swap 成 rotten material。

function on_age(ctx)
    local t = ctx.slot.freshness_tier
    if t <= 0 then return end
    local age = (ctx.slot.freshness_age_hours or 0) + ctx.hours
    local per_tier = ctx.shelf_life_hours / 5.0
    while age >= per_tier and t > 0 do
        t = t - 1
        age = age - per_tier
    end
    if t <= 0 and ctx.rotten_swap then
        affect.set_slot_state(ctx.holder, ctx.slot_index, {
            item_id             = ctx.rotten_swap.item_id,
            materials           = ctx.rotten_swap.materials,
            shape_type          = ctx.rotten_swap.shape_type,
            tags                = ctx.rotten_swap.tags,
            quality             = 0,
            freshness_tier      = 5,
            freshness_age_hours = 0.0,
        })
    else
        affect.set_slot_state(ctx.holder, ctx.slot_index, {
            freshness_tier      = t,
            freshness_age_hours = age,
        })
    end
end
