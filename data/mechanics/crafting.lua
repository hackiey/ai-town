-- Crafting mechanic: active reaction 数据 + dispatcher 逻辑。
--
-- Hooks:
--   on_resolve(ctx) → return result dict ({ok, outcome, outputs, consumed_input_indices, ...})
--                     不走 effects；纯函数式返回决策给 GDScript 端 apply。
--
-- Queries:
--   get_reaction(id)
--   all_reaction_ids()
--   find_active(verb, ws, sub)
--
-- 设计原则同 step 2：变换/匹配/失败/quality 全部在 lua；GDScript 只负责 inventory mutation
-- + 持久化 + RPC。
--
-- 与旧 dispatcher 的差异（"不考虑兼容"）：
--   1) parts_map 用 integer (input index) 替代 "@input[i]" 字符串 DSL
--   2) properties 里的算式（仅 anvil_blade 用到）改用 properties_fn 函数
--   3) 操作符 predicate（>=N、a..b）保留同样的 string 语法
--   4) 取消 ExpressionEvaluator——lua 函数原生支持
--
-- 熟练度（proficiency）：每个 reaction 标 skill_id + difficulty (0-100)。NPC 的
-- proficiency 通过 ctx.proficiency = {skill_id: value} 传入，影响失败率与品质。
-- 公式见 docs/proficiency_system.md。

-- ============================================================
-- 常量
-- ============================================================

local DEFAULT_QUALITY_CURVE = {1.0, 0.7, 0.4, 0.15, 0.0}
local META_INPUT_KEYS = {quality_weight = true, quality_curve = true, tool = true}

-- ============================================================
-- 熟练度公式（见 docs/proficiency_system.md）
-- ============================================================

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

local function roll_skill_quality(p)
    local mean = 20 + 0.75 * p
    local half = 15 - 0.167 * p
    if half < 1 then half = 1 end
    local q = mean + (math.random() * 2 - 1) * half
    if q < 0 then return 0 end
    if q > 100 then return 100 end
    return q
end

local function compute_proficiency_gain(p, d, q, succeeded)
    if not succeeded then
        return -math.max(0, p - 70) / 60
    end
    local perf = math.max(0, q - p) / 10
    local chal = math.max(0, d - p) / 20
    local slow_base = (100 - p) / 80
    if slow_base < 0 then slow_base = 0 end
    local slow = slow_base ^ 1.5
    return (perf + chal) * slow
end

-- ============================================================
-- 数据：active reaction
-- ============================================================

reactions = {

    bake_bread = {
        verb = "bake", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "first",
        inputs = {
            {["materials.body"] = "dough"},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {shape_type = "loaf", qty = 1}}},
        skill_id = "cooking", difficulty = 25,
        stamina_cost = 5.0, duration_seconds = 175.0,
        failure_modes = {
            {weight = 0.6, consume_inputs = {0, 1}, return_inputs = {}, message = ""},
            {weight = 0.4, consume_inputs = {1}, return_inputs = {0}, message = ""},
        },
        primary_input_indices = {0},
    },

    bake_meat = {
        verb = "bake", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "first",
        inputs = {
            {tags = {"meat", "raw"}},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {shape_type = "lump", qty = 1}}},
        skill_id = "cooking", difficulty = 25,
        stamina_cost = 5.0, duration_seconds = 245.0,
        failure_modes = {
            {weight = 0.6, consume_inputs = {0, 1}, return_inputs = {}, message = ""},
            {weight = 0.4, consume_inputs = {1}, return_inputs = {0}, message = ""},
        },
        primary_input_indices = {0},
    },

    bake_meat_salted = {
        verb = "bake", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {tags = {"meat", "raw"}, quality_weight = 0.85},
            {["materials.body"] = "salt", quality_weight = 0.15},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {
            shape_type = "lump",
            materials = {body = "cured_meat"},
            tags = {"food", "cooked", "meat", "cured"},
            qty = 1,
        }}},
        skill_id = "cooking", difficulty = 35,
        stamina_cost = 5.0, duration_seconds = 210.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0, 1, 2}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    bake_omelet = {
        verb = "bake", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "first",
        inputs = {
            {["materials.body"] = "egg"},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {shape_type = "dish", qty = 1}}},
        skill_id = "cooking", difficulty = 20,
        stamina_cost = 4.0, duration_seconds = 140.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0, 1}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    bake_omelet_salted = {
        verb = "bake", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {["materials.body"] = "egg", quality_weight = 0.85},
            {["materials.body"] = "salt", quality_weight = 0.15},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {
            shape_type = "dish",
            materials = {body = "cured_omelet"},
            tags = {"food", "cooked", "egg", "cured"},
            qty = 1,
        }}},
        skill_id = "cooking", difficulty = 30,
        stamina_cost = 4.0, duration_seconds = 154.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0, 1, 2}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    mix_dough = {
        verb = "mix", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {["materials.body"] = "flour"},
            {["materials.body"] = "water"},
        },
        outputs = {{generate = {
            shape_type = "dough_lump",
            materials = {body = "dough"},
            tags = {"food", "intermediate"},
            qty = 1,
        }}},
        skill_id = "cooking", difficulty = 10,
        stamina_cost = 4.0, duration_seconds = 70.0,
        failure_modes = {{weight = 1.0, consume_inputs = {1}, return_inputs = {0}, message = ""}},
    },

    mix_jam = {
        verb = "mix", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {["materials.body"] = "berry", quality_weight = 0.8},
            {["materials.body"] = "water", quality_weight = 0.2},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {
            shape_type = "jar",
            materials = {body = "berry_jam"},
            tags = {"food", "cooked", "sweet"},
            qty = 1,
        }}},
        skill_id = "cooking", difficulty = 30,
        stamina_cost = 5.0, duration_seconds = 420.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0, 1, 2}, return_inputs = {}, message = ""}},
    },

    mix_stew = {
        verb = "mix", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "fruit_whole", tags = {"fruit"}, quality_weight = 0.7},
            {["materials.body"] = "water", quality_weight = 0.3},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {
            shape_type = "bowl",
            materials = {body = "vegetable_stew"},
            tags = {"food", "cooked", "liquid"},
            qty = 1,
        }}},
        skill_id = "cooking", difficulty = 30,
        stamina_cost = 4.0, duration_seconds = 210.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0, 1, 2}, return_inputs = {}, message = ""}},
    },

    mix_stew_salted = {
        verb = "mix", workstation = "stove", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "fruit_whole", tags = {"fruit"}, quality_weight = 0.6},
            {["materials.body"] = "water", quality_weight = 0.2},
            {["materials.body"] = "salt", quality_weight = 0.2},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {
            shape_type = "bowl",
            materials = {body = "cured_stew"},
            tags = {"food", "cooked", "liquid", "cured"},
            qty = 1,
        }}},
        skill_id = "cooking", difficulty = 35,
        stamina_cost = 5.0, duration_seconds = 245.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0, 1, 2, 3}, return_inputs = {}, message = ""}},
    },

    compound_mint_mugwort_tea = {
        verb = "compound", workstation = "alchemy_table", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {["materials.body"] = "mint_leaf", quality_weight = 0.4},
            {["materials.body"] = "mugwort_leaf", quality_weight = 0.4},
            {["materials.body"] = "water", quality_weight = 0.2},
        },
        outputs = {{generate = {
            item_id = "mint_mugwort_tea",
            shape_type = "tankard",
            materials = {body = "mint_mugwort_tea"},
            tags = {"drink", "medicine", "liquid"},
            qty = 1,
        }}},
        skill_id = "alchemy", difficulty = 25,
        stamina_cost = 3.0, duration_seconds = 120.0,
        failure_modes = {{weight = 1.0, consume_inputs = {1, 2}, return_inputs = {0}, message = ""}},
        primary_input_indices = {0, 1},
    },

    compound_ginger_plantain_broth = {
        verb = "compound", workstation = "alchemy_table", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {["materials.body"] = "ginger_root", quality_weight = 0.45},
            {["materials.body"] = "plantain_leaf", quality_weight = 0.35},
            {["materials.body"] = "water", quality_weight = 0.2},
        },
        outputs = {{generate = {
            item_id = "ginger_plantain_broth",
            shape_type = "bowl",
            materials = {body = "ginger_plantain_broth"},
            tags = {"drink", "medicine", "liquid"},
            qty = 1,
        }}},
        skill_id = "alchemy", difficulty = 30,
        stamina_cost = 3.0, duration_seconds = 140.0,
        failure_modes = {{weight = 1.0, consume_inputs = {1, 2}, return_inputs = {0}, message = ""}},
        primary_input_indices = {0, 1},
    },

    compound_calendula_salve = {
        verb = "compound", workstation = "alchemy_table", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {["materials.body"] = "calendula_flower", quality_weight = 0.55},
            {["materials.body"] = "salt", quality_weight = 0.25},
            {["materials.body"] = "water", quality_weight = 0.2},
        },
        outputs = {{generate = {
            item_id = "calendula_salve",
            shape_type = "jar",
            materials = {body = "calendula_salve"},
            tags = {"medicine", "salve"},
            qty = 1,
        }}},
        skill_id = "alchemy", difficulty = 35,
        stamina_cost = 3.0, duration_seconds = 160.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0, 1, 2}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    compound_valerian_tonic = {
        verb = "compound", workstation = "alchemy_table", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "weighted_avg",
        inputs = {
            {["materials.body"] = "valerian_root", quality_weight = 0.5},
            {["materials.body"] = "mint_leaf", quality_weight = 0.3},
            {["materials.body"] = "water", quality_weight = 0.2},
        },
        outputs = {{generate = {
            item_id = "valerian_tonic",
            shape_type = "tankard",
            materials = {body = "valerian_tonic"},
            tags = {"drink", "medicine", "liquid"},
            qty = 1,
        }}},
        skill_id = "alchemy", difficulty = 30,
        stamina_cost = 3.0, duration_seconds = 140.0,
        failure_modes = {{weight = 1.0, consume_inputs = {1, 2}, return_inputs = {0}, message = ""}},
        primary_input_indices = {0, 1},
    },

    boil_salt = {
        verb = "boil", workstation = "saltworks_pan", sub_option = "", trigger = "active",
        material_strategy = "mix", quality_strategy = "first",
        inputs = {{tags = {"fuel"}}},
        outputs = {{generate = {
            item_id = "salt",
            shape_type = "powder",
            materials = {body = "salt"},
            tags = {"seasoning", "salty"},
            qty = 5,
        }}},
        skill_id = "salt_making", difficulty = 25,
        stamina_cost = 6.0, duration_seconds = 420.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    chop_wood = {
        verb = "chop", workstation = "lumberyard_workstation", sub_option = "", trigger = "active",
        material_strategy = "compose", quality_strategy = "first",
        inputs = {{shape_type = "axe_head_on_shaft", tool = true, quality_weight = 1.0}},
        outputs = {{generate = {
            item_id = "wood",
            shape_type = "log",
            materials = {body = "wood_oak"},
            tags = {"wood", "fuel"},
            qty = 1,
        }}},
        skill_id = "woodworking", difficulty = 25,
        stamina_cost = 6.0, duration_seconds = 600.0,
        failure_modes = {{weight = 1.0, consume_inputs = {}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    kiln_burn = {
        verb = "burn", workstation = "charcoal_kiln", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "first",
        inputs = {{shape_type = "log", ["materials.body.category"] = "wood"}},
        outputs = {{generate = {
            item_id = "charcoal",
            shape_type = "lump",
            materials = {body = "charcoal"},
            tags = {"fuel"},
            qty = 4,
        }}},
        skill_id = "charcoal_making", difficulty = 45,
        stamina_cost = 4.0, duration_seconds = 600.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    carve_plank = {
        verb = "carve", workstation = "workbench", sub_option = "plank", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {{shape_type = "log", ["materials.body.category"] = "wood"}},
        outputs = {{generate = {
            shape_type = "plank",
            parts_map = {body = 0},
            tags = {"wood", "building_material"},
            qty = 1,
        }}},
        skill_id = "woodworking", difficulty = 20,
        stamina_cost = 8.0, duration_seconds = 140.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0}, return_inputs = {}, message = ""}},
    },

    carve_shaft = {
        verb = "carve", workstation = "workbench", sub_option = "shaft", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {{shape_type = "log", ["materials.body.category"] = "wood"}},
        outputs = {{generate = {
            shape_type = "shaft",
            parts_map = {body = 0},
            tags = {"wood", "tool_part"},
            properties = {length = 1.2},
            qty = 1,
        }}},
        skill_id = "woodworking", difficulty = 30,
        stamina_cost = 8.0, duration_seconds = 140.0,
        failure_modes = {{weight = 1.0, consume_inputs = {}, return_inputs = {0}, message = ""}},
    },

    combine_axe = {
        verb = "combine", workstation = "workbench", sub_option = "axe", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "axe_head"},
            {shape_type = "shaft"},
            {shape_type = "rope"},
        },
        outputs = {{generate = {
            shape_type = "axe_head_on_shaft",
            parts_map = {head = 0, shaft = 1, binding = 2},
            tags = {"tool", "metal"},
            qty = 1,
        }}},
        skill_id = "assembly", difficulty = 30,
        stamina_cost = 6.0, duration_seconds = 105.0,
        failure_modes = {{weight = 1.0, consume_inputs = {2}, return_inputs = {0, 1}, message = ""}},
    },

    combine_knife = {
        verb = "combine", workstation = "workbench", sub_option = "knife", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "flat_blade"},
            {shape_type = "shaft"},
        },
        outputs = {{generate = {
            shape_type = "knife",
            parts_map = {blade = 0, handle = 1},
            tags = {"tool", "metal", "sharp"},
            qty = 1,
        }}},
        skill_id = "assembly", difficulty = 25,
        stamina_cost = 4.0, duration_seconds = 70.0,
        failure_modes = {{weight = 1.0, consume_inputs = {1}, return_inputs = {0}, message = ""}},
    },

    combine_pick = {
        verb = "combine", workstation = "workbench", sub_option = "pick", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "pick_head"},
            {shape_type = "shaft"},
            {shape_type = "rope"},
        },
        outputs = {{generate = {
            shape_type = "pick_head_on_shaft",
            parts_map = {head = 0, shaft = 1, binding = 2},
            tags = {"tool", "metal"},
            qty = 1,
        }}},
        skill_id = "assembly", difficulty = 30,
        stamina_cost = 6.0, duration_seconds = 105.0,
        failure_modes = {{weight = 1.0, consume_inputs = {2}, return_inputs = {0, 1}, message = ""}},
    },

    combine_rope = {
        verb = "combine", workstation = "workbench", sub_option = "rope", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {
            {item_id = "flax_bundle"},
            {item_id = "flax_bundle"},
        },
        outputs = {{generate = {
            shape_type = "rope",
            parts_map = {body = 0},
            tags = {"binding"},
            qty = 1,
        }}},
        skill_id = "assembly", difficulty = 15,
        stamina_cost = 5.0, duration_seconds = 90.0,
        failure_modes = {{weight = 1.0, consume_inputs = {}, return_inputs = {0, 1}, message = ""}},
    },

    combine_shovel = {
        verb = "combine", workstation = "workbench", sub_option = "shovel", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "flat_blade"},
            {shape_type = "shaft"},
            {shape_type = "rope"},
        },
        outputs = {{generate = {
            shape_type = "flat_blade_on_shaft",
            parts_map = {head = 0, shaft = 1, binding = 2},
            tags = {"tool", "metal"},
            qty = 1,
        }}},
        skill_id = "assembly", difficulty = 30,
        stamina_cost = 6.0, duration_seconds = 105.0,
        failure_modes = {{weight = 1.0, consume_inputs = {2}, return_inputs = {0, 1}, message = ""}},
    },

    combine_sickle = {
        verb = "combine", workstation = "workbench", sub_option = "sickle", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "flat_blade"},
            {shape_type = "shaft"},
        },
        outputs = {{generate = {
            shape_type = "sickle",
            parts_map = {blade = 0, handle = 1},
            tags = {"tool", "metal", "sharp", "harvest_tool"},
            qty = 1,
        }}},
        skill_id = "assembly", difficulty = 25,
        stamina_cost = 5.0, duration_seconds = 84.0,
        failure_modes = {{weight = 1.0, consume_inputs = {}, return_inputs = {0, 1}, message = ""}},
    },

    anvil_axe_head = {
        verb = "shape", workstation = "anvil", sub_option = "axe_head", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {{shape_type = "ingot", ["materials.body.category"] = "metal"}},
        outputs = {{generate = {
            shape_type = "axe_head",
            parts_map = {body = 0},
            tags = {"metal", "tool_part"},
            qty = 1,
        }}},
        skill_id = "smithing", difficulty = 55,
        stamina_cost = 12.0, duration_seconds = 210.0,
        failure_modes = {
            {weight = 0.7, consume_inputs = {}, return_inputs = {0}, message = ""},
            {weight = 0.3, consume_inputs = {0}, return_inputs = {}, message = ""},
        },
    },

    anvil_blade = {
        verb = "shape", workstation = "anvil", sub_option = "blade", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {{shape_type = "ingot", ["materials.body.category"] = "metal"}},
        outputs = {{generate = {
            shape_type = "flat_blade",
            parts_map = {body = 0},
            tags = {"metal", "tool_part"},
            -- 唯一一个用算式的：edge_sharpness = input[0].quality * 0.7
            properties_fn = function(matched_inputs)
                return {
                    blade_area = 0.1,
                    edge_sharpness = matched_inputs[1].quality * 0.7,
                }
            end,
            qty = 1,
        }}},
        skill_id = "smithing", difficulty = 50,
        stamina_cost = 12.0, duration_seconds = 210.0,
        failure_modes = {
            {weight = 0.7, consume_inputs = {}, return_inputs = {0}, message = ""},
            {weight = 0.3, consume_inputs = {0}, return_inputs = {}, message = ""},
        },
    },

    anvil_pick_head = {
        verb = "shape", workstation = "anvil", sub_option = "pick_head", trigger = "active",
        material_strategy = "compose", quality_strategy = "weighted_avg",
        inputs = {{shape_type = "ingot", ["materials.body.category"] = "metal"}},
        outputs = {{generate = {
            shape_type = "pick_head",
            parts_map = {body = 0},
            tags = {"metal", "tool_part"},
            qty = 1,
        }}},
        skill_id = "smithing", difficulty = 55,
        stamina_cost = 12.0, duration_seconds = 210.0,
        failure_modes = {
            {weight = 0.7, consume_inputs = {}, return_inputs = {0}, message = ""},
            {weight = 0.3, consume_inputs = {0}, return_inputs = {}, message = ""},
        },
    },

    forge_smelt = {
        verb = "fire", workstation = "forge", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "ore_chunk", quality_weight = 0.8},
            {tags = {"fuel"}, quality_weight = 0.2},
        },
        outputs = {{generate = {shape_type = "ingot", qty = 1}}},
        skill_id = "smelting", difficulty = 40,
        stamina_cost = 5.0, duration_seconds = 210.0,
        failure_modes = {
            {weight = 0.7, consume_inputs = {1}, return_inputs = {0}, message = ""},
            {weight = 0.3, consume_inputs = {0, 1}, return_inputs = {}, message = ""},
        },
        primary_input_indices = {0},
    },

    forge_alloy = {
        verb = "fire", workstation = "forge", sub_option = "", trigger = "active",
        material_strategy = "alloy", quality_strategy = "weighted_avg",
        inputs = {
            {shape_type = "ingot", ["materials.body"] = "copper"},
            {shape_type = "ingot", ["materials.body"] = "tin"},
            {tags = {"fuel"}},
        },
        outputs = {{generate = {shape_type = "ingot", qty = 1}}},
        skill_id = "smelting", difficulty = 65,
        stamina_cost = 6.0, duration_seconds = 280.0,
        failure_modes = {{weight = 1.0, consume_inputs = {2}, return_inputs = {0, 1}, message = ""}},
        primary_input_indices = {0, 1},
    },

    mill_grind = {
        verb = "grind", workstation = "mill", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "first",
        inputs = {{["materials.body.category"] = "grain"}},
        outputs = {{generate = {shape_type = "powder", qty = 1}}},
        skill_id = "milling", difficulty = 10,
        stamina_cost = 6.0, duration_seconds = 140.0,
        failure_modes = {{weight = 1.0, consume_inputs = {}, return_inputs = {0}, message = ""}},
        primary_input_indices = {0},
    },

    mint_gold_coin = {
        verb = "mint", workstation = "mint", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "first",
        inputs = {{shape_type = "ore_chunk", ["materials.body"] = "gold_ore"}},
        outputs = {{generate = {item_id = "gold_coin", shape_type = "coin", qty = 1}}},
        skill_id = "smelting", difficulty = 50,
        stamina_cost = 6.0, duration_seconds = 60.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    mint_silver_coin = {
        verb = "mint", workstation = "mint", sub_option = "", trigger = "active",
        material_strategy = "transform", quality_strategy = "first",
        inputs = {{shape_type = "ore_chunk", ["materials.body"] = "silver_ore"}},
        outputs = {{generate = {item_id = "silver_coin", shape_type = "coin", qty = 5}}},
        skill_id = "smelting", difficulty = 50,
        stamina_cost = 6.0, duration_seconds = 60.0,
        failure_modes = {{weight = 1.0, consume_inputs = {0}, return_inputs = {}, message = ""}},
        primary_input_indices = {0},
    },

    dig_gold = {
        verb = "dig", workstation = "gold_mine_workstation", sub_option = "", trigger = "active",
        material_strategy = "compose", quality_strategy = "first",
        inputs = {{shape_type = "pick_head_on_shaft", tool = true, quality_weight = 1.0}},
        outputs = {{generate = {
            item_id = "gold_ore",
            shape_type = "ore_chunk",
            materials = {body = "gold_ore"},
            qty = 1,
        }}},
        skill_id = "mining", difficulty = 30,
        stamina_cost = 6.0, duration_seconds = 600.0,
        failure_modes = {},
    },

    dig_silver = {
        verb = "dig", workstation = "silver_mine_workstation", sub_option = "", trigger = "active",
        material_strategy = "compose", quality_strategy = "first",
        inputs = {{shape_type = "pick_head_on_shaft", tool = true, quality_weight = 1.0}},
        outputs = {{generate = {
            item_id = "silver_ore",
            shape_type = "ore_chunk",
            materials = {body = "silver_ore"},
            qty = 1,
        }}},
        skill_id = "mining", difficulty = 20,
        stamina_cost = 6.0, duration_seconds = 600.0,
        failure_modes = {},
    },

    dig_iron = {
        verb = "dig", workstation = "iron_mine_workstation", sub_option = "", trigger = "active",
        material_strategy = "compose", quality_strategy = "first",
        inputs = {{shape_type = "pick_head_on_shaft", tool = true, quality_weight = 1.0}},
        outputs = {{generate = {
            item_id = "iron_ore",
            shape_type = "ore_chunk",
            materials = {body = "iron_ore"},
            qty = 1,
        }}},
        skill_id = "mining", difficulty = 15,
        stamina_cost = 6.0, duration_seconds = 600.0,
        failure_modes = {},
    },

    -- ── 被动反应（trigger=passive，计时转化）────────────────────────
    -- 由 PassiveSimulator 全局定时器推进（单一写者）；每条自带 tick_seconds。
    -- strategy="ramp_transform"：开始即变身成 output，品质从 0 线性爬到 ceiling，
    -- 到 hours 定格。on_tick(ctx={ceiling,start_hour,now_hour,hours}) → {quality,done}。
    -- 晾晒：放进 drying 容器自动开始（auto_start），ceiling = 输入品质。
    dry_tomato_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "tomato_fruit" },
        auto_start = true,
        output = "tomato_seed", yield = 2,
        hours = 24.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    dry_flax_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "flax_bundle" },
        auto_start = true,
        output = "flax_seed", yield = 2,
        hours = 24.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    dry_mint_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "mint_leaf" },
        auto_start = true,
        output = "mint_seed", yield = 2,
        hours = 24.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    dry_mugwort_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "mugwort_leaf" },
        auto_start = true,
        output = "mugwort_seed", yield = 2,
        hours = 24.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    dry_plantain_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "plantain_leaf" },
        auto_start = true,
        output = "plantain_seed", yield = 2,
        hours = 24.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    dry_calendula_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "calendula_flower" },
        auto_start = true,
        output = "calendula_seed", yield = 2,
        hours = 24.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    dry_ginger_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "ginger_root" },
        auto_start = true,
        output = "ginger_seed", yield = 1,
        hours = 36.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    dry_valerian_seed = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "valerian_root" },
        auto_start = true,
        output = "valerian_seed", yield = 1,
        hours = 36.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    -- 晾晒：小麦放进 drying 容器自动开酿（auto_start），ceiling = 小麦品质。
    dry_malt = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "drying", input = "wheat" },
        auto_start = true,
        output = "malt", yield = 1,
        hours = 24.0, tick_seconds = 1800,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
    -- 发酵：装水的 brewing_vessel + 麦芽 → 啤酒，由 brew 动作起头（auto_start=false）。
    -- ceiling = ferment_ceiling(熟练度, difficulty, 麦芽品质)。
    ferment_beer = {
        trigger = "passive", strategy = "ramp_transform",
        match = { vessel_tag = "brewing_vessel", base_liquid = "water" },
        auto_start = false,
        ingredient = "malt", ingredient_per_liter = 1,
        output = "beer", hours = 48.0, tick_seconds = 3600,
        skill_id = "brewing", difficulty = 30,
        on_tick = function(ctx) return ramp_quality(ctx.ceiling, ctx.age, ctx.hours) end,
    },
}

-- 给每条 reaction 注入 reaction_id（i18n 用）
for id, r in pairs(reactions) do
    r.reaction_id = id
end

-- skill_id 强校验。必须显式标注、必须在 KNOWN_SKILLS 集合里。
-- 真值表镜像 data/skills/skills.json —— 如果加新 skill，两边一起改。
-- 漏写 skill_id 的 reaction 早期就崩，不会"涨错轴 / 静默不涨" 后才被发现。
local KNOWN_SKILLS = {
    milling=true, cooking=true, alchemy=true, mining=true, salt_making=true,
    assembly=true, smithing=true, smelting=true, charcoal_making=true, woodworking=true,
    brewing=true,
}
for id, r in pairs(reactions) do
    if r.trigger ~= "passive" then
        if r.skill_id == nil or r.skill_id == "" then
            error("crafting.lua: reaction '" .. id .. "' missing required skill_id field")
        end
        if not KNOWN_SKILLS[r.skill_id] then
            error("crafting.lua: reaction '" .. id .. "' has unknown skill_id '" .. tostring(r.skill_id) .. "' (not in data/skills/skills.json)")
        end
        if type(r.difficulty) ~= "number" then
            error("crafting.lua: reaction '" .. id .. "' missing required numeric difficulty field")
        end
    end
end

-- 按 (verb|workstation|sub_option) 索引 active reactions
local _active_index = {}
for id, r in pairs(reactions) do
    if r.trigger ~= "passive" then
        local key = r.verb .. "|" .. r.workstation .. "|" .. r.sub_option
        if not _active_index[key] then _active_index[key] = {} end
        table.insert(_active_index[key], r)
    end
end

-- ============================================================
-- queries (GDScript 端用)
-- ============================================================

function get_reaction(id)
    return reactions[id]
end

function all_reaction_ids()
    local out = {}
    for id, _ in pairs(reactions) do table.insert(out, id) end
    return out
end

-- 启动期一次性导出：把所有 active reaction 的元数据 dump 出去给 GDScript / backend。
-- 不导 effects / failure_modes / inputs 列表（那些是 mechanic 运行用，backend 用不到）。
-- 仅 LLM tool 路由相关字段：(workstation, verb, sub_option) → 反查 axis；(skill_id, difficulty) → 注入提示。
-- backend 通过 backend_runtime_client 在握手时一次性接收，per-town 缓存。
function list_reaction_metadata()
    local out = {}
    for id, r in pairs(reactions) do
        if r.trigger ~= "passive" then
            table.insert(out, {
                id = id,
                skill_id = r.skill_id,
                difficulty = r.difficulty,
                workstation = r.workstation,
                verb = r.verb,
                sub_option = r.sub_option or "",
            })
        end
    end
    return out
end

-- ============================================================
-- 工具：path lookup / 操作符匹配
-- ============================================================

local function path_get(slot, path)
    -- 多层路径取值。"materials.body.category" → slot.materials.body 是 material_id String，
    -- 走 world.material() 自动 deref 取 .category。
    local cur = slot
    for part in string.gmatch(path, "[^%.]+") do
        if cur == nil then return nil end
        if type(cur) == "string" then
            -- 当 material_id auto-deref
            local mat = world.material(cur)
            if mat == nil then return nil end
            cur = mat
        end
        if type(cur) == "table" then
            cur = cur[part]
        else
            return nil
        end
    end
    return cur
end

local function to_num(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) or 0 end
    return 0
end

-- value_match: expected 可能是 ">=N" / "<=N" / "a..b" / 字面量
local function value_match(actual, expected)
    if type(expected) == "string" then
        local op, rhs = string.match(expected, "^(>=)(.*)$")
        if op then return to_num(actual) >= tonumber(rhs:match("^%s*(.-)%s*$")) end
        op, rhs = string.match(expected, "^(<=)(.*)$")
        if op then return to_num(actual) <= tonumber(rhs:match("^%s*(.-)%s*$")) end
        op, rhs = string.match(expected, "^(>)(.*)$")
        if op then return to_num(actual) > tonumber(rhs:match("^%s*(.-)%s*$")) end
        op, rhs = string.match(expected, "^(<)(.*)$")
        if op then return to_num(actual) < tonumber(rhs:match("^%s*(.-)%s*$")) end
        op, rhs = string.match(expected, "^(==?)(.*)$")
        if op then
            rhs = rhs:match("^%s*(.-)%s*$")
            if type(actual) == "number" then return actual == tonumber(rhs) end
            return tostring(actual) == rhs
        end
        local lo, hi = string.match(expected, "^([%d%.]+)%.%.([%d%.]+)$")
        if lo then
            local a = to_num(actual)
            return a >= tonumber(lo) and a <= tonumber(hi)
        end
        -- 字面量字符串
        return tostring(actual) == expected
    end
    if type(actual) == "number" or type(expected) == "number" then
        return to_num(actual) == to_num(expected)
    end
    return actual == expected
end

local function tags_of(slot)
    local t = slot.tags
    if t == nil then return {} end
    return t  -- 假定 array of strings
end

local function has_all_tags(slot, want)
    local tags = tags_of(slot)
    local set = {}
    for _, x in ipairs(tags) do set[x] = true end
    if type(want) == "table" then
        for _, w in ipairs(want) do
            if not set[w] then return false end
        end
        return true
    end
    return set[tostring(want)] == true
end

local function has_any_tag(slot, want)
    local tags = tags_of(slot)
    local set = {}
    for _, x in ipairs(tags) do set[x] = true end
    if type(want) == "table" then
        for _, w in ipairs(want) do
            if set[w] then return true end
        end
        return false
    end
    return set[tostring(want)] == true
end

local function eval_single(slot, key, expected)
    if key == "tags"      then return has_all_tags(slot, expected) end
    if key == "tags_any"  then return has_any_tag(slot, expected) end
    if key == "tags_none" then return not has_any_tag(slot, expected) end
    local actual = path_get(slot, key)
    if type(expected) == "table" then
        -- array → 任一匹配
        for _, e in ipairs(expected) do
            if value_match(actual, e) then return true end
        end
        return false
    end
    return value_match(actual, expected)
end

local function eval_predicate(slot, pred)
    for k, v in pairs(pred) do
        if not META_INPUT_KEYS[k] then
            if not eval_single(slot, k, v) then return false end
        end
    end
    return true
end

local function predicate_count(r)
    local n = 0
    for _, d in ipairs(r.inputs) do
        for k, _ in pairs(d) do
            if not META_INPUT_KEYS[k] then n = n + 1 end
        end
    end
    return n
end

-- ============================================================
-- Match: reaction.inputs[i] 对 player_inputs 的索引列表
-- 返回 matches (1-indexed array of arrays of 0-indexed slot ids) 或 nil
-- ============================================================

local function match_inputs(r, player_inputs)
    local n_req = #r.inputs
    if #player_inputs < n_req then return nil end
    local used = {}
    for j = 1, #player_inputs do used[j] = false end
    local matches = {}
    -- Pass 1: 每个 input 至少 1 个
    for i = 1, n_req do
        local pred = r.inputs[i]
        local slots = {}
        for j = 1, #player_inputs do
            if not used[j] and eval_predicate(player_inputs[j], pred) then
                table.insert(slots, j - 1)  -- 0-indexed for caller
                used[j] = true
                break
            end
        end
        if #slots == 0 then return nil end
        matches[i] = slots
    end
    -- Pass 2: 多余 slot 给任意 input
    for j = 1, #player_inputs do
        if not used[j] then
            local assigned = false
            for i = 1, n_req do
                if eval_predicate(player_inputs[j], r.inputs[i]) then
                    table.insert(matches[i], j - 1)
                    used[j] = true
                    assigned = true
                    break
                end
            end
            if not assigned then return nil end
        end
    end
    return matches
end

-- ============================================================
-- Derive consumption / quality_modifier / output_qty
-- ============================================================

local function primary_indices(r, default_arr)
    if r.primary_input_indices and #r.primary_input_indices > 0 then
        return r.primary_input_indices  -- 0-indexed
    end
    return default_arr  -- 0-indexed
end

local function derive_consumption(r, matches)
    local consumed, returned = {}, {}
    local quality_modifier = 1.0
    for i = 1, #r.inputs do
        local pred = r.inputs[i]
        local slots = matches[i]
        local qty = #slots
        local curve = pred.quality_curve or DEFAULT_QUALITY_CURVE
        local idx = qty
        if idx > #curve then idx = #curve end
        if idx < 1 then idx = 1 end
        quality_modifier = quality_modifier * curve[idx]
        local is_tool = pred.tool == true
        for _, s in ipairs(slots) do
            if is_tool then
                table.insert(returned, s)
            else
                table.insert(consumed, s)
            end
        end
    end
    -- output_qty = min over primary inputs（短板）。primary 默认 = 所有 input
    local default_p = {}
    for i = 0, #r.inputs - 1 do table.insert(default_p, i) end
    local primary = primary_indices(r, default_p)
    local output_qty = 1
    if #primary > 0 then
        output_qty = #matches[primary[1] + 1]
        for _, p in ipairs(primary) do
            local n = #matches[p + 1]
            if n < output_qty then output_qty = n end
        end
    end
    return {
        consumed = consumed,
        returned = returned,
        extras_returned = 0,
        output_qty = output_qty,
        quality_modifier = quality_modifier,
    }
end

-- ============================================================
-- Quality (per-input avg → strategy → skill cap)
-- ============================================================

local function apply_quality_strategy(r, matches, inputs, proficiency)
    if #matches == 0 then return 0 end
    local per_input_q = {}
    for i = 1, #matches do
        local sum = 0
        for _, s in ipairs(matches[i]) do
            sum = sum + (inputs[s + 1].quality or 0)
        end
        per_input_q[i] = sum / #matches[i]
    end
    local base = 0
    if r.quality_strategy == "min" then
        base = 100
        for _, q in ipairs(per_input_q) do if q < base then base = q end end
    elseif r.quality_strategy == "max" then
        for _, q in ipairs(per_input_q) do if q > base then base = q end end
    elseif r.quality_strategy == "first" then
        base = per_input_q[1]
    else  -- weighted_avg
        local sum_w, sum_qw = 0, 0
        for i = 1, #per_input_q do
            local w = (r.inputs[i] and r.inputs[i].quality_weight) or 1.0
            sum_w = sum_w + w
            sum_qw = sum_qw + w * per_input_q[i]
        end
        base = sum_w > 0 and sum_qw / sum_w or 0
    end
    -- 技能 roll：min(原料品质, 技能能达到的品质)。低熟练度永远造不出顶级品，
    -- 但烂原料同样卡死大师——双重 bottleneck。
    local skill_q = roll_skill_quality(proficiency or 0)
    local q = math.min(base, skill_q)
    if q < 0 then q = 0 end
    if q > 100 then q = 100 end
    return math.floor(q + 0.5)
end

-- ============================================================
-- Material 派生
-- ============================================================

local function derive_compose(gen, matched_inputs)
    -- parts_map = {body = 0} (integer) → output.materials[part] = matched_inputs[1+0].materials.body
    local out = {}
    local pm = gen.parts_map or {}
    for part, ref in pairs(pm) do
        if type(ref) == "number" then
            local i = ref + 1  -- to lua 1-index
            if matched_inputs[i] then
                out[part] = (matched_inputs[i].materials or {}).body or ""
            end
        elseif type(ref) == "string" then
            -- 字面量
            out[part] = ref
        end
    end
    return out
end

local function derive_transform(r, matched_inputs)
    local primary = primary_indices(r, {0})
    if #primary == 0 then return {} end
    local mats = matched_inputs[primary[1] + 1].materials or {}
    local src_id = mats.body or ""
    local mat = world.material(src_id)
    if mat == nil then return {} end
    local transforms = mat.transforms or {}
    local out_id = transforms[r.verb]
    if not out_id then return {} end
    return {body = tostring(out_id)}
end

local function derive_alloy(r, matched_inputs)
    local primary = primary_indices(r, {0, 1})
    if #primary < 2 then return {} end
    local a_mats = matched_inputs[primary[1] + 1].materials or {}
    local b_mats = matched_inputs[primary[2] + 1].materials or {}
    local a_id = a_mats.body or ""
    local b_id = b_mats.body or ""
    local a = world.material(a_id)
    if a == nil then return {} end
    local alloys = a.alloys or {}
    local out_id = alloys[b_id]
    if not out_id then return {} end
    return {body = tostring(out_id)}
end

local function derive_materials(r, gen, matched_inputs)
    if r.material_strategy == "compose"   then return derive_compose(gen, matched_inputs) end
    if r.material_strategy == "transform" then return derive_transform(r, matched_inputs) end
    if r.material_strategy == "alloy"     then return derive_alloy(r, matched_inputs) end
    if r.material_strategy == "mix"       then return {} end  -- mix 必须显式 materials
    return {}
end

-- ============================================================
-- Generate output instances
-- ============================================================

local function build_generate(r, gen, matched_inputs, quality)
    -- materials: 显式 > 派生
    local materials = {}
    if gen.materials then
        for k, v in pairs(gen.materials) do materials[k] = v end
    else
        materials = derive_materials(r, gen, matched_inputs)
    end
    local shape_type = gen.shape_type or ""
    -- tags
    local tags = {}
    if gen.tags then
        for _, t in ipairs(gen.tags) do table.insert(tags, t) end
    end
    -- properties: 静态 dict 或 properties_fn(matched_inputs)
    local properties = {}
    if gen.properties_fn then
        local p = gen.properties_fn(matched_inputs)
        if p then for k, v in pairs(p) do properties[k] = v end end
    elseif gen.properties then
        for k, v in pairs(gen.properties) do properties[k] = v end
    end
    -- qty
    local qty = gen.qty or 1
    -- item_id: 显式 > template lookup > auto_<hash>
    local item_id = gen.item_id or ""
    if item_id == "" then
        item_id = world.find_item_template(shape_type, materials.body or "")
        if item_id == "" or item_id == nil then
            item_id = "auto_" .. shape_type .. "_" .. (materials.body or "")
        end
    end
    -- freshness_tier 继承：取所有 perishable input 的 min；没有 perishable → 5
    local tier = 5
    for _, inp in ipairs(matched_inputs) do
        local body = (inp.materials or {}).body
        if body and body ~= "" then
            local mat = world.material(body)
            if mat and mat.shelf_life_hours and mat.shelf_life_hours > 0 then
                local t = inp.freshness_tier or 5
                if t < tier then tier = t end
            end
        end
    end
    -- properties 拆分：durability 走平铺列 (slot.durability)，其余物理属性
    -- (length / blade_area / edge_sharpness 等) 收到 physics_props JSON dict。
    -- 旧的 slot.properties bag 已废，输出 dict 里不能再写 properties=...。
    local durability_val = nil
    local physics = {}
    local physics_has = false
    for k, v in pairs(properties) do
        if k == "durability" or k == "max_durability" then
            durability_val = v
        else
            physics[k] = v
            physics_has = true
        end
    end
    return {
        item_id = item_id,
        quality = quality,
        shape_type = shape_type,
        materials = materials,
        tags = tags,
        physics_props = physics_has and physics or nil,
        durability = durability_val,
        quantity = qty,
        freshness_tier = tier,
        freshness_age_hours = 0.0,
    }
end

local function generate_outputs(r, inputs, matches, derived, proficiency)
    local matched_inputs = {}
    for i = 1, #matches do
        matched_inputs[i] = inputs[matches[i][1] + 1]
    end
    local quality = apply_quality_strategy(r, matches, inputs, proficiency)
    quality = math.floor(quality * derived.quality_modifier + 0.5)
    if quality < 0 then quality = 0 end
    if quality > 100 then quality = 100 end
    local instances = {}
    for _, spec in ipairs(r.outputs) do
        if spec.generate then
            local inst = build_generate(r, spec.generate, matched_inputs, quality)
            inst.quantity = (inst.quantity or 1) * derived.output_qty
            table.insert(instances, inst)
        end
    end
    return instances
end

-- ============================================================
-- 失败模式
-- ============================================================

local function select_failure(r)
    if not r.failure_modes or #r.failure_modes == 0 then return nil end
    local total = 0
    for _, m in ipairs(r.failure_modes) do total = total + (m.weight or 1.0) end
    if total <= 0 then return r.failure_modes[1], 0 end
    local roll = math.random() * total
    local acc = 0
    for i = 1, #r.failure_modes do
        acc = acc + (r.failure_modes[i].weight or 1.0)
        if roll <= acc then return r.failure_modes[i], i - 1 end
    end
    return r.failure_modes[#r.failure_modes], #r.failure_modes - 1
end

-- 暴露给 GDScript 的纯函数版本（mining 等场景按真实成败决定时调用）。
-- 入参 / 公式与 compute_proficiency_gain 一致；见 docs/proficiency_system.md。
function proficiency_gain(p, d, q, succeeded)
    return compute_proficiency_gain(p, d, q, succeeded)
end

local function do_failure(r, inputs, matches, derived, proficiency)
    local mode, mode_idx = select_failure(r)
    local consumed_local, returned_local = {}, {}
    if mode == nil then
        for _, s in ipairs(derived.consumed) do table.insert(consumed_local, s) end
        for _, s in ipairs(derived.returned) do table.insert(returned_local, s) end
        mode_idx = -1
    else
        local consume_set, return_set = {}, {}
        for _, i in ipairs(mode.consume_inputs or {}) do
            for _, s in ipairs(matches[i + 1] or {}) do consume_set[s] = true end
        end
        for _, i in ipairs(mode.return_inputs or {}) do
            for _, s in ipairs(matches[i + 1] or {}) do return_set[s] = true end
        end
        for _, s in ipairs(derived.consumed) do
            if consume_set[s] then
                table.insert(consumed_local, s)
            else
                table.insert(returned_local, s)
            end
        end
        for _, s in ipairs(derived.returned) do
            table.insert(returned_local, s)
        end
    end
    local p = proficiency or 0
    local d = r.difficulty or 50
    return {
        ok = true,
        outcome = "failure",
        outputs = {},
        consumed_input_indices = consumed_local,
        returned_input_indices = returned_local,
        extras_returned = derived.extras_returned,
        output_qty = derived.output_qty,
        quality_modifier = derived.quality_modifier,
        fail_mode_idx = mode_idx,
        reaction_id = r.reaction_id,
        duration_seconds = r.duration_seconds,
        stamina_cost = r.stamina_cost,
        proficiency_skill_id = r.skill_id or "",
        proficiency_before = p,
        proficiency_delta = compute_proficiency_gain(p, d, 0, false),
        difficulty = d,
    }
end

local function do_success(r, inputs, matches, derived, proficiency)
    local outputs = generate_outputs(r, inputs, matches, derived, proficiency)
    local result_q = 0
    if outputs[1] and outputs[1].quality then
        result_q = outputs[1].quality
    end
    local p = proficiency or 0
    local d = r.difficulty or 50
    return {
        ok = true,
        outcome = "success",
        outputs = outputs,
        consumed_input_indices = derived.consumed,
        returned_input_indices = derived.returned,
        extras_returned = derived.extras_returned,
        output_qty = derived.output_qty,
        quality_modifier = derived.quality_modifier,
        fail_mode_idx = -1,
        reaction_id = r.reaction_id,
        duration_seconds = r.duration_seconds,
        stamina_cost = r.stamina_cost,
        proficiency_skill_id = r.skill_id or "",
        proficiency_before = p,
        proficiency_delta = compute_proficiency_gain(p, d, result_q, true),
        difficulty = d,
    }
end

local function execute(r, inputs, matches, proficiency)
    local derived = derive_consumption(r, matches)
    local p = proficiency or 0
    local d = r.difficulty or 50
    local fail_chance = compute_fail_chance(p, d)
    if math.random() < fail_chance then
        return do_failure(r, inputs, matches, derived, p)
    end
    return do_success(r, inputs, matches, derived, p)
end

-- ============================================================
-- 主入口
-- ============================================================

-- ctx: { verb, workstation_id, sub_option, inputs (array of slot dicts),
--        proficiency (optional: {skill_id: value}) }
-- return: { ok, outcome, outputs, consumed_input_indices, returned_input_indices,
--           extras_returned, output_qty, quality_modifier, fail_mode_idx, reaction_id,
--           proficiency_skill_id, proficiency_before, proficiency_delta }
function on_resolve(ctx)
    local key = ctx.verb .. "|" .. ctx.workstation_id .. "|" .. (ctx.sub_option or "")
    local candidates = _active_index[key] or {}
    if #candidates == 0 then
        return {
            ok = false,
            outcome = "no_match",
            outputs = {},
            consumed_input_indices = {},
            returned_input_indices = {},
            no_match_reason = "ws_verb",
            reaction_id = "",
        }
    end
    -- 按 predicate 数降序：约束多的赢
    local sorted = {}
    for _, r in ipairs(candidates) do table.insert(sorted, r) end
    table.sort(sorted, function(a, b) return predicate_count(a) > predicate_count(b) end)
    local inputs = ctx.inputs
    local proficiency_table = ctx.proficiency or {}
    -- 醉酒/生病：有效熟练度临时下调（同时拉高失败率、压低成品品质）。只在结算时算，
    -- 不改存储熟练度。0 = 清醒健康。
    local work_impair = ctx.work_impair or 0
    for _, r in ipairs(sorted) do
        local matches = match_inputs(r, inputs)
        if matches then
            local p = proficiency_table[r.skill_id] or 0
            p = p - work_impair
            if p < 0 then p = 0 end
            return execute(r, inputs, matches, p)
        end
    end
    return {
        ok = false,
        outcome = "no_match",
        outputs = {},
        consumed_input_indices = {},
        returned_input_indices = {},
        no_match_reason = "inputs",
        reaction_id = "",
    }
end

-- ============================================================
-- 被动反应（passive）：helper + query + tick 派发
-- 被动转化定义全在本反应表，单一真值。GDScript 端：
--   PassiveSimulator 调 passive_reactions()/run_tick()，brew_handlers 调
--   find_ferment()/ferment_ceiling()，酿酒面板调 ferment_recipes()。
-- ============================================================

local function _clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- 品质从 0 线性爬到 ceiling；累计 transform-hours(age) 到 hours → 定格 + done。
-- 计时转化的共享 on_tick 实现（晾晒/发酵共用）。ctx.age 由 simulator 累计推进。
function ramp_quality(ceiling, age, hours)
    local frac = 1.0
    if hours and hours > 0 then frac = age / hours end
    frac = _clamp(frac, 0.0, 1.0)
    local q = math.floor(ceiling * frac + 0.5)
    return { quality = q, done = (frac >= 1.0) }
end

-- 发酵品质上限：麦芽品质是硬顶，熟练度相对难度决定逼近几成。
-- eff = clamp(0.6 + (p-d)/100, 0, 1)；ceiling = round(clamp(mq*eff, 0, 100))。
function ferment_ceiling(p, d, malt_quality)
    p = p or 0
    d = d or 0
    local eff = _clamp(0.6 + (p - d) / 100.0, 0.0, 1.0)
    return math.floor(_clamp((malt_quality or 0) * eff, 0.0, 100.0) + 0.5)
end

-- 全表被动条目（给 simulator 注册 tick 节奏 + 读 match/output/yield/hours…）。
function passive_reactions()
    local out = {}
    for id, r in pairs(reactions) do
        if r.trigger == "passive" then
            local m = r.match or {}
            table.insert(out, {
                id = id,
                strategy = r.strategy or "ramp_transform",
                auto_start = r.auto_start == true,
                tick_seconds = r.tick_seconds or 3600,
                hours = r.hours or 0,
                output = r.output or "",
                yield = r.yield or 1,
                ingredient = r.ingredient or "",
                ingredient_per_liter = r.ingredient_per_liter or 1,
                skill_id = r.skill_id or "",
                difficulty = r.difficulty or 0,
                vessel_tag = m.vessel_tag or "",
                match_input = m.input or "",
                match_base_liquid = m.base_liquid or "",
            })
        end
    end
    return out
end

local function _has_tag(vessel_tags, tag)
    if tag == nil or tag == "" then return true end
    if type(vessel_tags) ~= "table" then return false end
    for _, t in ipairs(vessel_tags) do
        if t == tag then return true end
    end
    return false
end

-- 晾晒 auto-start 用：这个 item 在这种容器里会不会晾。
function find_dry(item_id, vessel_tags)
    for id, r in pairs(reactions) do
        if r.trigger == "passive" and r.strategy == "ramp_transform" and r.auto_start then
            local m = r.match or {}
            if m.input == item_id and _has_tag(vessel_tags, m.vessel_tag) then
                r.reaction_id = id
                return r
            end
        end
    end
    return nil
end

-- brew 起头用：选定原料 + 桶里是某基底液体 → 命中发酵配方。
function find_ferment(base_liquid, ingredient, vessel_tags)
    for id, r in pairs(reactions) do
        if r.trigger == "passive" and r.ingredient ~= nil and r.ingredient ~= "" then
            local m = r.match or {}
            if m.base_liquid == base_liquid and r.ingredient == ingredient
                and _has_tag(vessel_tags, m.vessel_tag) then
                r.reaction_id = id
                return r
            end
        end
    end
    return nil
end

-- 按 id 取一条被动配方的安全字段(不含 on_tick 函数,可 LuaConv)。brew 起头用。
function passive_recipe(id)
    local r = reactions[id]
    if r == nil or r.trigger ~= "passive" then return nil end
    local m = r.match or {}
    return {
        id = id,
        output = r.output or "",
        ingredient = r.ingredient or "",
        ingredient_per_liter = r.ingredient_per_liter or 1,
        hours = r.hours or 0,
        skill_id = r.skill_id or "",
        difficulty = r.difficulty or 0,
        vessel_tag = m.vessel_tag or "",
        base_liquid = m.base_liquid or "",
    }
end

-- 酿酒面板用：这个桶（vessel_tags）+ 基底液体能酿的全部酒。
function ferment_recipes(vessel_tags, base_liquid)
    local out = {}
    for id, r in pairs(reactions) do
        if r.trigger == "passive" and r.ingredient ~= nil and r.ingredient ~= "" then
            local m = r.match or {}
            if m.base_liquid == base_liquid and _has_tag(vessel_tags, m.vessel_tag) then
                table.insert(out, {
                    id = id,
                    output = r.output or "",
                    ingredient = r.ingredient or "",
                    ingredient_per_liter = r.ingredient_per_liter or 1,
                })
            end
        end
    end
    return out
end

-- simulator 每 tick 调：派发到反应自己的 on_tick（自定义每 tick 逻辑）。
-- ctx 由 GD 组好（ceiling/start_hour/now_hour/hours…）；返回 patch {quality, done}。
function run_tick(reaction_id, ctx)
    local r = reactions[reaction_id]
    if r == nil or r.on_tick == nil then
        return { quality = ctx.ceiling or 0, done = true }
    end
    return r.on_tick(ctx)
end
