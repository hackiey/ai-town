-- Shelf verb: update / buy_from. 走 MechanicVerb wrapper。
--
-- Listings 形状（含 price + DB 行）跟普通 slot inventory 不同 —— 写路径暂时由
-- GDScript Shelves.update_shelf / buy_from_shelf 处理，lua 通过 affect.shelf_op
-- 同步调用并接收 result。lua 在这里仅负责：
--   - access 检查（GDScript 已预校验，传 access_ok/access_reason）
--   - 决定 world_event 内容
--   - 错误消息格式化
-- 后续若要让 LLM 改 shelf 规则（动态定价 / 折扣 / 税）再深入 lua 化。
--
-- ctx (on_update):
--   actor, actor_id, shelf, shelf_id, location_id
--   ops          : Array of { type="add|update|remove", item, price_centi?, quantity? }
--   access_ok / access_reason
--
-- ctx (on_buy):
--   actor (buyer), actor_id, shelf, shelf_id, location_id
--   listing_id, quantity, total_price_centi
--   access_ok / access_reason
--
-- 价格单位是 centi：1 silver = 100 centi（cut coinage，可剪开找零）。


function on_update(ctx)
    if not ctx.access_ok then
        return { ok = false, message = ctx.access_reason }
    end
    if #ctx.ops == 0 then
        return { ok = false, message = "update_shelf 至少需要一个操作" }
    end
    local r = affect.shelf_op(ctx.actor, ctx.shelf, "update", { ops = ctx.ops })
    if not r.ok then
        return { ok = false, message = r.message }
    end
    return {
        ok = true,
        message = r.message,
        result = r,
    }
end


function on_buy(ctx)
    if not ctx.access_ok then
        return { ok = false, message = ctx.access_reason }
    end
    if not ctx.listing_id or ctx.listing_id == "" then
        return { ok = false, message = "buy_from_shelf 缺少 listing" }
    end
    local r = affect.shelf_op(ctx.actor, ctx.shelf, "buy", {
        listing_id = ctx.listing_id,
        quantity = ctx.quantity,
        total_price_centi = ctx.total_price_centi,
    })
    if not r.ok then
        return { ok = false, message = r.message }
    end
    -- buy_from_shelf 内部已 emit_sale_event；这里不重发 world_event，避免重复
    return {
        ok = true,
        message = r.message,
        result = r,
    }
end
