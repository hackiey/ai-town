# 熟练度系统（Proficiency System）

> 角色按 trade 持有 0-100 的数值熟练度，影响工作台 reaction 的失败率、品质、以及熟练度自身的成长。
>
> 这份文档是公式、技能轴、reaction 难度、数据归属的**唯一真值**。所有相关代码改动请引用本文件而不是自己重新算。

---

## 1. 核心变量

| 符号 | 含义 | 范围 |
|---|---|---|
| `p` | NPC 在某 skill_id 上的熟练度 | [0, 100] |
| `d` | 当前 reaction 的难度 | [0, 100] |
| `q` | 单次产出的品质 | [0, 100] |
| `Δ` | `p - d`，正 = 超出 reaction 水平 | [-100, +100] |

---

## 2. 失败率

```
matched_fail(p) = ((100 - p) / 100)^2 * 0.5
delta_factor(Δ) = 2^(-Δ / 10)
fail(p, d) = clamp(matched_fail(p) * delta_factor(p - d), 0, 1)
```

含义：熟练度本身决定"手稳不稳"（matched_fail）；Δ 决定"任务对自己有多顺手"。每 10 点 Δ 翻倍/减半。

| p | d | Δ | fail |
|---|---|---|---|
| 20 | 0 | +20 | 8% |
| 20 | 10 | +10 | 16% |
| 20 | 20 | 0 | 32% |
| 20 | 30 | -10 | 64% |
| 20 | 50 | -30 | 100%（clamp）|
| 60 | 30 | +30 | 1% |
| 60 | 60 | 0 | 8% |
| 60 | 80 | -20 | 32% |
| 80 | 60 | +20 | 0.5% |
| 80 | 80 | 0 | 2% |
| 80 | 100 | -20 | 8% |
| 100 | 100 | 0 | 0% |

---

## 3. 品质

成功时，先 roll 一个"技能上限品质"：

```
mean       = 20 + 0.75 * p
half_width = max(1, 15 - 0.167 * p)
skill_q    = clamp(mean + uniform(-half_width, +half_width), 0, 100)
```

| p | skill_q range |
|---|---|
| 20 | [20, 50] |
| 40 | [38, 62] |
| 60 | [55, 75] |
| 80 | [75, 85] |
| 95 | [93, 96] |

**与原料品质的组合**：原料品质（按 `quality_strategy` 算出的 `base`）作为上限，技能 roll 也作为上限，取两者最小：

```
final_quality = min(base, skill_q) * quality_modifier
```

物理直觉：
- 大师用烂原料 → 被原料卡住（再厉害也救不回烂面粉）
- 学徒用顶级原料 → 被自己手艺卡住
- 大师用好原料 → 顶级产品
- 品质与 reaction 难度**完全无关**（绝世好剑和精品菜刀的品质轴是一样的 0-100）

---

## 4. 熟练度成长

**成功时**：
```
perf_term      = max(0, q - p) / 10           # 超出自己水平
challenge_term = max(0, d - p) / 20           # 攻坚加成
slow_factor    = max(0, (100 - p) / 80) ^ 1.5 # 越高越慢
gain           = (perf_term + challenge_term) * slow_factor
p_new          = clamp(p + gain, 0, 100)
```

**失败时**（仅高熟练度会掉）：
```
gain_on_fail = -max(0, p - 70) / 60
```

`slow_factor` 参考值：

| p | slow_factor |
|---|---|
| 0 | 1.40 |
| 20 | 1.05 |
| 40 | 0.73 |
| 60 | 0.44 |
| 80 | 0.18 |
| 90 | 0.06 |
| 100 | 0.00 |

典型场景：

| 场景 | p | d | q | Δp |
|---|---|---|---|---|
| 学徒做基础活做出好东西 | 20 | 10 | 40 | +2.1 |
| 学徒做基础活只是合格 | 20 | 10 | 25 | +0.5 |
| 学徒挑战长剑（侥幸成功）| 20 | 80 | 30 | +4.2 |
| 老铁匠日常打菜刀 | 60 | 10 | 65 | +0.22 |
| 老铁匠匹配难度 | 60 | 60 | 70 | +0.44 |
| 大师做日常 | 90 | 10 | 88 | 0 |
| **突破：80 高手做出 100 难度绝世剑** | 80 | 100 | 80 | +0.18 |
| 突破并发挥超常 | 80 | 100 | 90 | +0.36 |
| 高手攻顶级失败 | 80 | 100 | — | -0.17 |
| 大师攻匹配失败 | 95 | 95 | — | -0.42 |

设计意图：
- 学徒做出好东西涨得快、做日常没长进
- 老铁匠日常稳但不长，必须攻高难度才进步
- 突破靠攻 `d > p` 的 reaction（即使品质平平也涨）

---

## 5. 技能轴（9 项）

| skill_id | 中文 | 涵盖 reactions |
|---|---|---|
| `mining` | 挖矿 | dig_iron / dig_silver / dig_gold |
| `woodworking` | 木工（含砍伐与锯切）| chop_wood / carve_plank / carve_shaft |
| `charcoal_making` | 烧炭 | kiln_burn |
| `smelting` | 冶炼（含造币）| forge_smelt / forge_alloy / mint_gold_coin / mint_silver_coin |
| `smithing` | 锻造 | anvil_blade / anvil_axe_head / anvil_pick_head |
| `assembly` | 装配 | combine_rope / combine_knife / combine_sickle / combine_axe / combine_pick / combine_shovel |
| `cooking` | 烹饪 | mix_dough / bake_omelet / bake_bread / bake_meat / mix_jam / mix_stew / bake_omelet_salted / bake_meat_salted / mix_stew_salted |
| `milling` | 磨坊 | mill_grind |
| `salt_making` | 制盐 | boil_salt |

**不立技能**：
- `打水`（well）—— 取水没有"做坏"概念，永远成功，固定品质
- `种地`（farm_action_runner / 晾架）—— 真值在 `farming_basics` 知识书 + 晾架的被动 timer；不挂 skill check（设计：种地是常识不是手艺）。晾架机制见 `data/mechanics/drying.lua`
- `treasury_vault` —— 无 reaction

---

## 6. Reaction → skill_id + difficulty

| reaction | workstation | skill_id | difficulty |
|---|---|---|---|
| dig_iron | iron_mine_workstation | mining | 15 |
| dig_silver | silver_mine_workstation | mining | 20 |
| dig_gold | gold_mine_workstation | mining | 30 |
| chop_wood | lumberyard_workstation | woodworking | 25 |
| carve_plank | workbench | woodworking | 20 |
| carve_shaft | workbench | woodworking | 30 |
| kiln_burn | charcoal_kiln | charcoal_making | 45 |
| forge_smelt | forge | smelting | 40 |
| forge_alloy | forge | smelting | 65 |
| mint_gold_coin | mint | smelting | 50 |
| mint_silver_coin | mint | smelting | 50 |
| anvil_blade | anvil | smithing | 50 |
| anvil_axe_head | anvil | smithing | 55 |
| anvil_pick_head | anvil | smithing | 55 |
| combine_rope | workbench | assembly | 15 |
| combine_knife | workbench | assembly | 25 |
| combine_sickle | workbench | assembly | 25 |
| combine_axe | workbench | assembly | 30 |
| combine_pick | workbench | assembly | 30 |
| combine_shovel | workbench | assembly | 30 |
| mix_dough | stove | cooking | 10 |
| bake_omelet | stove | cooking | 20 |
| bake_bread | stove | cooking | 25 |
| bake_meat | stove | cooking | 25 |
| mix_jam | stove | cooking | 30 |
| mix_stew | stove | cooking | 30 |
| bake_omelet_salted | stove | cooking | 30 |
| bake_meat_salted | stove | cooking | 35 |
| mix_stew_salted | stove | cooking | 35 |
| mill_grind | mill | milling | 10 |
| boil_salt | saltworks_pan | salt_making | 25 |

### 难度 rubric（给后续扩展 reaction 时填值用）

| 区间 | 含义 | 例子 |
|---|---|---|
| 0-15 | 几乎纯体力，错不到哪去 | 磨粉、和面 |
| 16-30 | 简单手艺，明显有"做坏"的可能 | 烤面包、削木板、装配两件套 |
| 31-50 | 真正的技术活，火候/配比重要 | 烧炭、冶炼、腌制 |
| 51-70 | 工匠级 | 锻造刀片、合金、复杂部件 |
| 71-90 | 大师级 | 兵器、精密器物、传家宝 |
| 91-100 | 留给未来"绝世"级产物 | 一国一时的代表作 |

---

## 7. 数据归属

### 阶段 1（静态生效）
- **真值**：`backend/data/town/npcs.json` 里每个 NPC 加 `proficiency: {smithing: 75, ...}`
- **读取**：Godot Character autoload 暴露 `get_proficiency_table() -> Dictionary`
- **写入**：无（静态）
- **未列出的 skill_id = 0**

### 阶段 2（持久化 + 成长）
- **表**：Godot `Db` autoload 创建
  ```sql
  CREATE TABLE IF NOT EXISTS npc_proficiency(
      npc_id   TEXT NOT NULL,
      skill_id TEXT NOT NULL,
      value    REAL NOT NULL,
      PRIMARY KEY(npc_id, skill_id)
  );
  ```
- **唯一写者**：`workstation_action_runner.gd`，每次 craft 完成后 UPSERT（符合 [single-writer 原则](../memory/feedback_derived_state_persist_single_writer.md)）
- **Seed**：Godot 启动时遍历 `npcs.json.proficiency`，仅当表中不存在该行时插入（已有的数值是玩家进度，不能被 seed 覆盖）
- **Backend 读取**：从 `npc_proficiency` 表读，不再读 `npcs.json.proficiency`

---

## 8. 代码接口

### Lua（`data/mechanics/crafting.lua`）

**入参** —— `ctx.proficiency` 是 `{skill_id: value}` dict（不是单个数）。Lua 根据匹配到的 reaction 自己挑：

```lua
function on_resolve(ctx)
    -- ctx.proficiency = {smithing = 75, smelting = 60, ...}
    -- 匹配到 reaction 后:
    local p = (ctx.proficiency or {})[r.skill_id] or 0
end
```

**返回** —— `result` 字典额外包含：

```lua
{
    -- ...原有字段...
    proficiency_skill_id = r.skill_id or "",
    proficiency_before   = p,
    proficiency_delta    = gain_or_loss,  -- 由 GD 端在阶段 2 应用
}
```

### GDScript

**`Crafting.resolve()`** 加一个 proficiency 参数：

```gdscript
static func resolve(
    verb: String,
    workstation_id: String,
    sub_option: String,
    inputs: Array,
    proficiency: Dictionary = {}    # 新增，默认空 dict
) -> Dictionary
```

**`workstation_action_runner.gd:_commit_active`** 路径：

```gdscript
# 阶段 1：调用前传 proficiency
var prof_table: Dictionary = character.get_proficiency_table()
var result := Crafting.resolve(verb, ws_def.id, sub_option, instances, prof_table)

# 阶段 2：commit 后写回
if result.has("proficiency_delta") and result.proficiency_delta != 0.0:
    Db.upsert_npc_proficiency(
        character.backend_character_id(),
        result.proficiency_skill_id,
        result.proficiency_before + result.proficiency_delta
    )
```

**`character.gd`** 加方法：

```gdscript
func get_proficiency_table() -> Dictionary:
    # 阶段 1：读 npcs.json 缓存
    # 阶段 2：改成读 Db.get_npc_proficiency_table(backend_character_id())
    var cfg := _get_npc_config()
    return cfg.get("proficiency", {})
```

---

## 9. 阶段路线图

| 阶段 | 目标 | 主要改动 |
|---|---|---|
| 0 | 数据契约定稿 | 本文档 |
| 1 | 静态生效 | `crafting.lua` 接公式 + `npcs.json` 加 proficiency + `Crafting.resolve` 加参 + `character.gd` 加 getter |
| 2 | 持久化 + 成长 | `Db` 建表 + boot seed + runner UPSERT + backend 改读 DB |
| 3 | Prompt context | `prompts.json` 加文案 + 新 section 渲染 NPC 当前手艺 |
| 4 | Skill book 归轴 | `data/skills/skills.json` 单点真值 + 渲染时按 skill 分组 |
| 5a | 反馈 UX | action result 加 `proficiency_delta`，事件描述区分突破/掉级 |
| 5b | Tool 过滤 + 难度展示 + 失败因果化 | factory 按 proficiency 过滤 craft 工具；reaction 难度注入 sub_option enum；失败 event 带难度/熟练度对比 |

---

## 10. 未决问题（可在实际跑起来后回头调）

1. **品质组合策略**：当前选 `min(base, skill_q)`。如果实测大师被烂原料卡得太死，可改成 `geometric_mean(base, skill_q) = sqrt(base * skill_q)`。
2. **学徒成长上限**：`d > p+30` 时 fail 已 clamp 100%，意味着学徒永远无法靠攻顶级 reaction 突破。需要别的途径（教学、技能书、长期低强度积累），或者放宽 clamp。
3. **失败回落起点**：当前 `p > 70` 才掉。如果觉得 80 高手不应该掉，把 70 提到 80。
4. **难度 rubric**：当前所有 reaction 都 ≤ 65，缺乏"大师级挑战"。需要新增 d=70-90 的 reaction 才能让 80+ 的 NPC 真正突破。
