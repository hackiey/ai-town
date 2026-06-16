-- data/mechanics/magic.lua
-- 魔法战斗反应 —— 声明式数据，复用 crafting 同款引擎语义（约束多的赢 + compute_fail_chance）。
-- reaction = 纯数据，无 per-spell effect_script：命中后果 = modify.hp 公式（@power 经 world.eval）
-- + modify.add_tags（status，可带数值 fields，如 block_power）。
-- 四因子里的 caster_power（mastery × wand.power × wand.affinity）由 GDScript SpellPower 算好塞进
-- ctx；这里只乘自己的 base_power 得 spell_power。难度沿用 crafting 的 0..100 体系。
-- 设计：docs/architecture/combat-system.md §3–§5、reaction-schema.md §4.4 / §4.5b。

-- 熟练度失败率（与 crafting.lua compute_fail_chance 同公式，docs/proficiency_system.md）
local function compute_fail_chance(p, d)
    local norm = (100 - p) / 100
    if norm < 0 then norm = 0 end
    local matched = norm * norm * 0.5
    local factor = 2 ^ (-(p - d) / 10)
    local f = matched * factor
    if f < 0 then return 0 end
    if f > 1 then return 1 end
    return f
end

reactions = {
    stupefy = {
        verb = "stupefy", school = "combat", skill_id = "stupefy",
        difficulty = 20, base_power = 1.0,
        inputs = { { tags = {"creature"} } },              -- 约束多的赢（浮人比浮物难同机制）
        modify = {
            hp = "-8 - 12 * @power",                        -- §4.5b 公式，world.eval(@power=spell_power)
            add_tags = { { tag = "stunned", fields = { duration_real_sec = 3.0 } } },
        },
    },
    protego = {
        verb = "protego", school = "combat", skill_id = "protego",
        difficulty = 15, base_power = 1.0,
        inputs = { { tags = {"creature"} } },
        -- block_power 用 power 单位（与命中方 attack_power = base_power × caster_power 同尺度，
        -- HitResolver 做减法拦截）。≈0.8..1.7，约挡一发同档 stupefy。
        modify = {
            add_tags = { { tag = "shielded", fields = { block_power = "0.8 + 0.6 * @power" } } },
        },
    },
}

local KNOWN_SPELLS = { stupefy = true, protego = true }
for id, r in pairs(reactions) do
    assert(r.verb, id .. ": missing verb")
    assert(KNOWN_SPELLS[r.skill_id], id .. ": unknown skill_id " .. tostring(r.skill_id))
    assert(type(r.difficulty) == "number", id .. ": difficulty must be number")
end

local function tags_has(target_tags, tag)
    for _, t in ipairs(target_tags or {}) do
        if t == tag then return true end
    end
    return false
end

-- 反应的所有 input tags 都在 target_tags 里才算匹配
local function reaction_matches(r, target_tags)
    for _, inp in ipairs(r.inputs or {}) do
        for _, tag in ipairs(inp.tags or {}) do
            if not tags_has(target_tags, tag) then return false end
        end
    end
    return true
end

local function predicate_count(r)
    local n = 0
    for _, inp in ipairs(r.inputs or {}) do
        for _ in ipairs(inp.tags or {}) do n = n + 1 end
    end
    return n
end

-- 按 verb + target_tags 选反应：匹配者里约束最多的赢
local function pick_reaction(verb, target_tags)
    local best, best_n = nil, -1
    for _, r in pairs(reactions) do
        if r.verb == verb and reaction_matches(r, target_tags) then
            local n = predicate_count(r)
            if n > best_n then best, best_n = r, n end
        end
    end
    return best
end

-- string 字段当公式跑 world.eval（@power 等）；非 string 原样返回
local function eval_field(v, power)
    if type(v) == "string" then
        return world.eval(v, { power = power })
    end
    return v
end

-- 命中结算入口（CombatReactions.resolve 调）。
-- ctx = {verb, school, caster, caster_id, target, target_tags[], caster_power, proficiency{}}
function on_hit_reaction(ctx)
    local r = pick_reaction(ctx.verb, ctx.target_tags)
    if not r then
        return { ok = false, fail_reason = "no_reaction", power = 0, hp_delta = 0, statuses = {} }
    end
    local prof = (ctx.proficiency or {})[r.skill_id] or 0
    if math.random() < compute_fail_chance(prof, r.difficulty) then
        return { ok = false, fail_reason = "failed_cast", power = 0, hp_delta = 0, statuses = {} }
    end
    local power = (r.base_power or 1.0) * (ctx.caster_power or 1.0)
    local hp_delta = 0
    local statuses = {}
    local m = r.modify or {}
    if m.hp then
        hp_delta = world.eval(m.hp, { power = power })
        affect.hp(ctx.target, hp_delta)
    end
    for _, t in ipairs(m.add_tags or {}) do
        local fields = {}
        if t.fields then
            for k, v in pairs(t.fields) do fields[k] = eval_field(v, power) end
        end
        affect.add_status(ctx.target, t.tag, t.expires_hours or 0, "spell:" .. ctx.verb, fields)
        table.insert(statuses, t.tag)
    end
    return { ok = true, power = power, fail_reason = "", hp_delta = hp_delta, statuses = statuses }
end

-- GDScript 只读查询：base_power / school（护盾 attack_power 用，Phase D）
function get_reaction(verb)
    for _, r in pairs(reactions) do
        if r.verb == verb then
            return { verb = r.verb, school = r.school, base_power = r.base_power, difficulty = r.difficulty }
        end
    end
    return nil
end
