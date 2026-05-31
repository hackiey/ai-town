-- Minting mechanic: 每 game-hour 把国库里一半矿石铸成对应币。
-- 系统级（无 actor）；GDScript Mints autoload 在 slow_tick 触发 on_slow_tick。
--
-- ctx (由 mints.gd 准备):
--   vault : ContainerNode (treasury_vault)

mint_fraction = 0.5      -- 每次 tick 铸库存矿石的一半
ore_minting = {
    gold_ore   = {coin = "gold_coin", qty = 1},
    silver_ore = {coin = "silver_coin", qty = 5},
}


function on_slow_tick(ctx)
    for ore_id, spec in pairs(ore_minting) do
        local found = world.find_items(ctx.vault, { item_id = ore_id })
        local total = 0
        for _, m in ipairs(found) do total = total + m.qty end
        if total > 0 then
            local to_mint = math.floor(total * mint_fraction)
            if to_mint > 0 then
                local taken = affect.take_item(ctx.vault, { item_id = ore_id }, to_mint)
                if taken > 0 then
                    local coin_qty = taken * spec.qty
                    local placed = affect.spawn_item(ctx.vault, spec.coin, coin_qty, 100)
                    if placed < coin_qty then
                        -- 装不下 → 退回 ore，下个 tick 再试
                        affect.spawn_item(ctx.vault, ore_id, taken, 100)
                    end
                end
            end
        end
    end
end
