-- Speech mechanic: 说话规则。
--
-- ctx (由 GDScript Character.emit_say 准备):
--   speaker      : Character node 引用（不读字段，只作为 broadcast effect 的句柄）
--   speaker_id   : string
--   text         : string
--   volume       : "near" | "far"
--   target_id    : string ("" 表示无定向目标)
--   candidates   : array of { id = string, distance = float, is_sleeping = bool }
--                  —— 其他在场角色 + 与 speaker 距离 + 是否睡着
--
-- return:
--   nil / ""        : OK
--   non-empty string: reject 原因（effects 不 apply）

-- 说话半径（按 volume）。改这里 = 改"声音传多远"。
volume_radius = {
    near = 6.0,
    far  = 12.0,
}

-- 能穿透睡眠的音量。near 太轻、睡着的人听不到也不会被吵醒；far 才足以惊醒。
-- 与 backend semantics/events.ts 的 LOUD_SAY_TO_VOLUMES 保持一致。
waking_volumes = {
    far   = true,
    shout = true,
}

local function radius_for(volume)
    return volume_radius[volume] or volume_radius.far
end

local function reaches_sleeper(volume)
    return waking_volumes[volume] == true
end

function on_speak(ctx)
    local radius = radius_for(ctx.volume)
    local target_id = ctx.target_id or ""
    local wakes_sleepers = reaches_sleeper(ctx.volume)

    -- 定向喊话：先验证目标在场 + 在 volume 半径内
    if target_id ~= "" then
        local target_dist = nil
        for _, c in ipairs(ctx.candidates) do
            if c.id == target_id then
                target_dist = c.distance
                break
            end
        end
        if target_dist == nil then
            return "say_to target not found: " .. target_id
        end
        if target_dist > radius then
            return "say_to target out of " .. ctx.volume .. " range: " .. target_id
        end
    end

    -- 听众 = 半径内所有其他角色（包含 target 自己）；睡着的人只在足够响时才能听见
    local affected = {}
    local target_in_affected = false
    for _, c in ipairs(ctx.candidates) do
        if c.distance <= radius and (wakes_sleepers or not c.is_sleeping) then
            table.insert(affected, c.id)
            if c.id == target_id then
                target_in_affected = true
            end
        end
    end

    -- 如果定向目标因睡眠等原因没进听众，event 的 target 字段也清空 ——
    -- 否则 backend 会按 targetCharacterId 把事件塞进对方记忆，绕过感知过滤。
    local effective_target = target_id
    if target_id ~= "" and not target_in_affected then
        effective_target = ""
    end

    affect.broadcast_speech({
        speaker      = ctx.speaker,
        text         = ctx.text,
        volume       = ctx.volume,
        target_id    = effective_target,
        affected_ids = affected,
    })
end
