-- Container verb: deposit / withdraw / inspect 三合一。
-- 走 MechanicVerb wrapper：backend_action_runner._run_<verb> 准备 ctx → resolve()
-- → 本 hook 决定能不能转 / 要不要 world_event。
--
-- ctx (由 backend_action_runner 准备):
--   actor          : Character node
--   actor_id       : string  (backend character id)
--   container      : ContainerNode
--   container_id   : string
--   container_name : string  (i18n 显示名，message / event 用)
--   op             : "deposit" | "withdraw" | "inspect"
--   item_id        : string  (deposit/withdraw 必填；inspect 忽略)
--   item_name      : string  (i18n 显示名，message 用；inspect 忽略)
--   quantity       : int     (deposit/withdraw 必填；inspect 忽略)
--   access_ok      : bool    (GDScript 预校验：距离 + 钥匙)
--   access_reason  : string  (access_ok=false 时的拒绝消息)
--
-- return (MechanicVerb 约定):
--   { ok=true, message=..., result=..., world_event={event_type, text, data}? }
--   { ok=false, message=... }


local function _world_event_data(ctx, extra)
    local d = {
        actorId = ctx.actor_id,
        containerId = ctx.container_id,
    }
    for k, v in pairs(extra) do d[k] = v end
    return d
end


local function _on_inspect(ctx)
    local items = world.find_items(ctx.container, {})
    if #items == 0 then
        return {
            ok = true,
            message = "「" .. ctx.container_name .. "」是空的",
            result = { items = {} },
            world_event = {
                event_type = "container_inspected",
                data = _world_event_data(ctx, { itemCount = 0 }),
            },
        }
    end
    local lines = { "「" .. ctx.container_name .. "」里：" }
    for _, e in ipairs(items) do
        table.insert(lines, "  " .. e.item_id .. " ×" .. e.qty .. " (q=" .. e.quality .. ")")
    end
    return {
        ok = true,
        message = table.concat(lines, "\n"),
        result = { items = items },
        world_event = {
            event_type = "container_inspected",
            data = _world_event_data(ctx, { itemCount = #items }),
        },
    }
end


local function _on_deposit(ctx)
    local moved = affect.transfer_item(
        ctx.actor, ctx.container,
        { item_id = ctx.item_id }, ctx.quantity
    )
    if moved == 0 then
        return { ok = false, message = "你身上没有「" .. ctx.item_name .. "」" }
    end
    local msg = "存入了 " .. moved .. " 份「" .. ctx.item_name .. "」到「" .. ctx.container_name .. "」"
    if moved < ctx.quantity then
        msg = msg .. "（你只有 " .. moved .. " 份）"
    end
    return {
        ok = true,
        message = msg,
        result = { moved = moved },
        world_event = {
            event_type = "container_deposited",
            data = _world_event_data(ctx, {
                itemId = ctx.item_id, quantity = moved,
            }),
        },
    }
end


local function _on_withdraw(ctx)
    local moved = affect.transfer_item(
        ctx.container, ctx.actor,
        { item_id = ctx.item_id }, ctx.quantity
    )
    if moved == 0 then
        return { ok = false, message = "「" .. ctx.container_name .. "」里没有「" .. ctx.item_name .. "」" }
    end
    local msg = "从「" .. ctx.container_name .. "」取出了 " .. moved .. " 份「" .. ctx.item_name .. "」"
    if moved < ctx.quantity then
        msg = msg .. "（只剩 " .. moved .. " 份）"
    end
    return {
        ok = true,
        message = msg,
        result = { moved = moved },
        world_event = {
            event_type = "container_withdrawn",
            data = _world_event_data(ctx, {
                itemId = ctx.item_id, quantity = moved,
            }),
        },
    }
end


function on_resolve(ctx)
    if not ctx.access_ok then
        return { ok = false, message = ctx.access_reason }
    end
    if ctx.op == "inspect" then
        return _on_inspect(ctx)
    elseif ctx.op == "deposit" then
        return _on_deposit(ctx)
    elseif ctx.op == "withdraw" then
        return _on_withdraw(ctx)
    end
    return { ok = false, message = "未知操作: " .. tostring(ctx.op) }
end
