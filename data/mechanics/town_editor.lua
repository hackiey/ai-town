local function clamp_int(value, minimum, maximum, fallback)
    value = tonumber(value) or fallback
    value = math.floor(value)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function create_map(ctx)
    local width = clamp_int(ctx.width, 8, 256, 48)
    local height = clamp_int(ctx.height, 8, 256, 32)
    return {
        format = "ai_town",
        version = 7,
        name = ctx.name or "",
        tile_size = 32,
        size = { width, height },
        player_spawn = { math.floor(width / 2), math.floor(height / 2) },
        tiles = {
            meadow = 37,
            path = 0,
            field = 10,
            water = 18,
        },
        terrain = {
            base_ground = "ground_meadow",
        },
        layers = {
            ground = {},
            roads = {},
            fields = {},
            water = {},
        },
        fences = {},
        buildings = {},
        decorations = {},
        characters = {},
        character_profiles = {},
        player_character_id = "",
        locations = {},
    }
end

function palette()
    return {
        { id = "ground_meadow", name = "青绿草地", kind = "ground", tile = 37 },
        { id = "ground_deep", name = "深绿草地", kind = "ground", tile = 37 },
        { id = "ground_dry", name = "枯黄草地", kind = "ground", tile = 37 },
        { id = "road_warm_cobble", name = "暖色石板路", kind = "road", tile = 0 },
        { id = "road_gray_cobble", name = "灰石道路", kind = "road", tile = 0 },
        { id = "road_forest_cobble", name = "林地褐石路", kind = "road", tile = 0 },
        { id = "field_tilled", name = "翻耕土地", kind = "field", tile = 10 },
        { id = "field_golden", name = "金黄田地", kind = "field", tile = 37 },
        { id = "water_clear", name = "浅水", kind = "water", tile = 37 },
        { id = "water_deep", name = "深水", kind = "water", tile = 37 },
    }
end
