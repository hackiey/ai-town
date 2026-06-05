-- Sleep verb: start (走 MechanicVerb.resolve = on_resolve hook)
--            + commit (走 MechanicVerb.resolve(..., "on_commit") = on_commit hook)
--
-- BackendActionRunner._start_sleep 调 on_resolve 入睡；timer 到点 / 被 preempt
-- 时调 on_commit 醒来。中间的 deadline 推进还在 GDScript（属于 durative，Step 7 范围）。
--
-- ctx (on_resolve / 入睡):
--   actor                : Character node
--   actor_id             : string
--   action_id            : string
--   duration_minutes     : int
--   expires_total_hours  : int (GameClock.total_game_hours + ceil(minutes/60))
--
-- ctx (on_commit / 醒来):
--   actor            : Character node
--   actor_id         : string
--   duration_minutes : int
--   reason           : "natural" | "preempted by ..." | string


function on_resolve(ctx)
    if ctx.duration_minutes <= 0 then
        return { ok = false, message = "sleep duration_game_minutes must be > 0" }
    end
    affect.add_status(ctx.actor, "sleeping", ctx.expires_total_hours, ctx.action_id)
    return {
        ok = true,
        message = "",
        world_event = {
            event_type = "went_to_sleep",
            data = {
                actorId = ctx.actor_id,
                durationGameMinutes = ctx.duration_minutes,
            },
        },
    }
end


function on_commit(ctx)
    affect.remove_status(ctx.actor, "sleeping")
    return {
        ok = true,
        message = "",
        world_event = {
            event_type = "woke_up",
            data = {
                actorId = ctx.actor_id,
                durationGameMinutes = ctx.duration_minutes,
                reason = ctx.reason,
            },
        },
    }
end
