-- Trade verb: offer (买家发起报价) + respond (卖家 accept/reject)。
--
-- 撮合 / DB 写在 BackendActionRunner.trade_create / trade_respond（保留 transactional
-- 转账 + 货架消费 + rollback 路径）；lua 通过 affect.trade_op 同步调用。
-- lua 这里负责：args 校验、决定是否进入实际撮合、构造 world_event payload。
-- 数据全程结构化：offer / request 是 Lua 表数组，每项 { item = slug, count = int }。
-- world_event.data 把这些字段原样透传给 backend，由 backend 渲染器组装文案 / 解析人名。
--
-- ctx (on_offer):
--   actor (Character buyer), buyer_id, seller_id,
--   offer (Array of { item = slug, count = int }), request (同)
--
-- ctx (on_respond):
--   actor (Character seller), actor_id, trade_id, response ("accept" | "reject")
--   trade_id 在 GDScript 侧用买家名解析后注入，lua 不再做名字→id 转换。


function on_offer(ctx)
    if ctx.seller_id == "" then
        return { ok = false, message = "offer 缺少交易对象" }
    end
    if ctx.seller_id == ctx.buyer_id then
        return { ok = false, message = "不能和自己交易" }
    end
    local r = affect.trade_op(ctx.actor, "create", {
        seller_id = ctx.seller_id,
        offer = ctx.offer,
        request = ctx.request,
    })
    if not r.ok then
        return { ok = false, message = r.message or "创建交易报价失败" }
    end
    return {
        ok = true,
        result = r.trade,
        world_event = {
            event_type = "offer_trade",
            data = {
                actorId = ctx.buyer_id,
                affectedCharacterIds = { ctx.buyer_id, ctx.seller_id },
                buyerCharacterId = ctx.buyer_id,
                sellerCharacterId = ctx.seller_id,
                tradeId = r.trade_id,
                offer = ctx.offer,
                request = ctx.request,
            },
        },
    }
end


function on_respond(ctx)
    if ctx.response ~= "accept" and ctx.response ~= "reject" then
        return { ok = false, message = "respond(kind=trade) response must be accept/reject" }
    end
    local r = affect.trade_op(ctx.actor, "respond", {
        trade_id = ctx.trade_id,
        response = ctx.response,
    })
    if not r.ok then
        return { ok = false, message = r.message }
    end
    return {
        ok = true,
        result = r.trade,
        world_event = {
            event_type = "respond_to_trade",
            data = {
                actorId = r.seller_id,
                affectedCharacterIds = { r.buyer_id, r.seller_id },
                buyerCharacterId = r.buyer_id,
                sellerCharacterId = r.seller_id,
                tradeId = ctx.trade_id,
                response = r.response,
                offer = r.trade and r.trade.offer or nil,
                request = r.trade and r.trade.request or nil,
            },
        },
    }
end
