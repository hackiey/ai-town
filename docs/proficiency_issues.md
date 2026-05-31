# 熟练度系统 - 待解决问题

> 两次 session 的端到端调查合并清单。设计真值在 `proficiency_system.md`，本文件只跟踪"还没修的洞"。
>
> 修复一条划掉一条（保留条目作为历史记录）；新发现的问题追加到末尾，不要重排序。

## 当前状态总览

| 状态 | 编号 |
|---|---|
| ✅ 已解决 | #1, #2, #3, #4, #5, #6, #8, #9, #10, #15 |
| ⏸️ 已决定跳过 | #7（见 `proficiency_next_plan.md` A2 决议） |
| 🟡 待决策 / 待触发 | #11（B2）, #12（B3）, #13（C2）, #14（D1） |

---

## P0 — 直接影响 NPC 行为质量，应当先做

### ✅ 1. 工具列表没按 NPC proficiency 过滤 [DONE]

> **已解决**：`factory.ts` 用 `isAxisAccessibleTo(craft, currentContext)` 按 `currentContext.proficiency` 的 key 过滤注册。skill_id 真值走 `data/skills/skills.json` + `craft-registry.ts.skillIdForCraft`。

`backend/src/agent-shared/game-tools/factory.ts:78` 注释明说"所有工具永远 expose 给 LLM"。`edda_hale`（杂货店老板，`proficiency: {}`）依然看到全套 12 个 axis tool。

**后果**：浪费 token；LLM 误调；角色破设定（"老板娘竟然想去铸金币"）。

**根因**：`axis-registry.ts` 没有 `AXIS_REQUIRED_SKILL_ID: Record<slug, skillId>` 字段，门槛信息缺失。上次拆 `use_workstation` 时明确推迟的下一步，到现在所有 NPC tool 列表完全一致。

**修法**：先做 #4（单点真值），再用 `currentContext.proficiency[skillId] > 0` 过滤注册。0 或缺失不暴露。

---

### ✅ 2. LLM 看不到 reaction difficulty [DONE]

> **已解决**：lua reaction catalog 通过 boot dump → `ReactionCatalog` 缓存到 backend；sub_option enum 的 description 拼上"（难度 X）"；同时 `proficiency.usage_hint` i18n 给通用提示"难度 ≤ p+10 稳，超 p+30 几乎必败"。

NPC prompt 里只渲染了自己的 tier（"smithing: novice"），但每个 reaction 的难度 `d` 没渲染。

**后果**：物理事实是 `p=20` 去做 `d=80` 的 `mint_gold_coin` 失败率 ≈100%（clamp），但 LLM 不知道、会去试，浪费一整个动作回合 + 污染历史。

**根因**：失败率核心是 `(p, d)`，LLM 只能看到 `p`。`tools.json` 描述里"难度 25"、"难度 50-55"是**散文里硬编码的死字**，跟 lua 真值无任何同步保证。

**修法**：
- 最小：prompt skill section 末尾加一句"能稳定做的难度 ≤ p+10，超 p+30 几乎必败"（零代码、纯 i18n）
- 完整：tool schema 的 `sub_option` enum 注入难度（"`axe_head（难度 55）`"），数据从 lua 直接拉

---

### ✅ 3. 失败 event 对 LLM 不够因果化 [DONE]

> **已解决**：失败 event 无条件带 `proficiencyBefore` + `difficulty` + `failModeName`。renderer 给 actor 自己显示"（难度 X / 熟练度 Y）"。旁人不渲染（数值是私密反馈）。原料消耗状态由 `character_changes.backpack` 的 "失去 X x1" 表达，不在 event 上重复。fail_mode 文案"手法不稳"已改"熟练度不够"。

绝大多数失败（skill < 70）event 只渲染 `fail_mode_name`（"手法不稳"）：
- 没 proficiency suffix（5a 只在 |delta|≥0.5 渲染，新手失败 delta=0）
- 没 difficulty 对比
- lua 里区分"材料废 vs 退回"，event 层没把这差异渲染（影响 LLM 决策：下次再试 vs 重新备料）

**后果**：LLM 反复尝试同一件超出能力的活，不知道根因；也分不清是"再来一次"还是"该去备料"。

**修法**：失败 event 对**所有 viewer** 都打"难度 d / 你的熟练度 p"+ "材料是否消耗"。不限 actor 自己（旁人也该看到"老张又把斧头打废了"）。

---

## P1 — 结构性 / 真值漂移（命名层）

### ✅ 4. 同一个手艺有 3 套 slug，没有单一真值 ⭐ 根因 [DONE]

> **已解决**：单点真值改成 `data/skills/crafts.json`（craft slug → skillId + workstation/verb）+ `data/skills/skills.json`（skill_id → books）。三端共读：`craft-registry.ts`、`crafts.gd` 自动绑定 + `skill-catalog.ts`。命名漂移物理上不可能再发生。

| 概念 | Tool axis | Lua `skill_id` | i18n proficiency key |
|---|---|---|---|
| 挖矿 | `mine` | `mining` | `skill.mining` |
| 木工 | `woodwork` | `woodworking` | `skill.woodworking` |
| 锻造 | `smith` | `smithing` | `skill.smithing` |
| 冶炼 | `smelt` | `smelting` | `skill.smelting` |
| 烹饪 | `cook` | `cooking` | `skill.cooking` |
| 装配 | `assemble` | `assembly` | `skill.assembly` |
| 烧炭 | `burn_charcoal` | `charcoal_making` | `skill.charcoal_making` |
| 磨粉 | `mill_grain` | `milling` | `skill.milling` |
| 晒种 | `dry_seed` | `farming` ⚠️ | (无 skill.dry_seed) |
| 制盐 | `boil_salt` | `salt_making` | `skill.salt_making` |

10/10 都需要翻译，但没有中央 mapping 表。每个映射都是隐式约定。踩中 `[[feedback_llm_id_name_boundary]]` 的反面。

**修法**：`axis-registry.ts` 加 `SKILL_ID_BY_AXIS`，过滤、文案、event 渲染统一查这张表。#1/#5/#6/#7/#9 都建立在这条之上。

---

### ✅ 5. AXIS_DEFAULTS ↔ lua reaction.skill_id 无对账；漏写静默失败 [DONE]

> **已解决**：`crafting.lua` 顶部 `KNOWN_SKILLS` 集合 + boot 期 assert 校验每条 active reaction 都有 `skill_id` 字段且在集合内。漏写 / 写错直接 boot 崩。

- `axis-registry.ts` 说 "stove|bake → axis cook"，但 lua 里某条 stove 反应写 `skill_id="farming"` 不会报错、悄悄涨错轴
- 新加 reaction 忘写 `skill_id` 字段静默失败：不报错、不涨熟练度、无 lint

**修法**：
- lua reaction 注册时 assert `skill_id` 非空（或显式 `skill_id=nil` 表示"刻意无技能"，跟 `draw_water` 同档）
- boot-time check：用 `(workstation, verb)` 反查 axis，再对 reaction.skill_id 做相等校验

---

### ✅ 6. GD 镜像了 axis-registry 三处手抄 [DONE]

> **已解决**：GD 端 `Crafts` autoload（`src/autoload/crafts.gd`）直接读 `data/skills/crafts.json`。`backend_action_runner.gd` 的 `WORKSTATION_AXIS_ACTIONS` 和 `workstation_action_runner.gd` 的 `_AXIS_BY_WORKSTATION_VERB` 已删。改 craft 只动 JSON。

- `src/characters/parts/backend_action_runner.gd:42` `WORKSTATION_AXIS_ACTIONS`
- `src/sim/workstations/workstation_action_runner.gd:20` `_AXIS_BY_WORKSTATION_VERB`
- 改一行 TS 要同步改两处 GD

同 `[[project_wage_rates_in_npcs_json]]` 那种 stale 病。

**修法**：让 GD 通过启动期 json 读这张表，或干脆让 axis-registry 生成一份 `.gd` const file。

---

### ⏸️ 7. mining 和普通 craft 的 proficiency gain 路径分两套 [SKIPPED]

> **已决定跳过**：两条路径今天都调同一个 lua `compute_proficiency_gain` 函数，公式单点真值，实际无 drift。"未来改公式忘同步" 是假设性风险，commit 时 grep 两处即可。把开发时间留给 B2/B3 等真问题。见 `proficiency_next_plan.md` A2 决议。

- 普通 craft：直接读 lua 返回的 `proficiency_delta`
- mining：在 GD `_apply_mining_proficiency_gain` 里自己算 `q`、再 `MechanicHost.query("crafting", "proficiency_gain")`

**后果**：lua 公式改一处忘同步另一处 = silent drift。违反 `[[feedback_derived_state_persist_single_writer]]`。

**修法**：mining 走 lua 同一条路径；或者趁 #4 一起重构。

---

### ✅ 8. en/skills.json 没跟上 zh [DONE, 残余 → C1]

> **已解决（主因）**：`skill_axis` 字段已从 i18n catalog 彻底移除（按 axis 分组改成查 `data/skills/skills.json` 反查），en 不再因为字段缺失崩。
>
> **残余**：en/skills.json 整体内容仍只有 1 本 `character_attributes_basics`，其他 7 本未翻译。本质是项目级 i18n 完整度问题，不专属 proficiency。跟踪在 `proficiency_next_plan.md` C1。

zh 全套带 `skill_axis` 字段，en 只剩 `character_attributes_basics`。`player.locale=en` 时按 axis 分组的 skill memory 会拼一堆空 group label。

违反 `[[prompt_i18n_catalog]]` 双语对等。

**修法**：en/skills.json 补齐 `skill_axis` 字段。机械翻译即可。

---

### ✅ 9. Phase 4 axis 文案与 tool 文案靠"碰巧一致"维系 [DONE]

> **已解决**：随 #4 + #8 一起解。按 skill 分组渲染直接查 `data/skills/skills.json`（skillId → books），不再依赖 i18n 里冗余的 `skill_axis` 字段。tool 文案和 proficiency section 不会再"文案漂移"。

skill book 按 `smithing` 分组渲染到 `### 锻造`，工具叫 `smith` 也显示"锻造"——目前通是因为两套 i18n 都用同一个中文字串。哪天 tool 文案改"打铁"而 proficiency 还是"锻造"，关联就断了。

**修法**：和 #4 一起解，axis 文案抽成单点真值，工具描述和 proficiency section 共用。

---

## P1 — 设计漏洞 / 覆盖缺失

### ✅ 10. farming 轴覆盖严重失衡 [DONE — 改造为非熟练度系统]

> **已解决（B1 决议）**：用户拍板"种地不需要熟练度，知道相关的技巧就好了"。落实：
> - `farming` skill_id 从 `skills.json` / `crafting.lua` `KNOWN_SKILLS` 删除
> - `dry_seed` tool / 2 条 lua reaction / 完整 wire 链全删
> - `drying_rack` 工作站改造成 ContainerNode（`passive_tags=["drying"]`）
> - 新增被动机制：`Item.dries_into` + `data/mechanics/drying.lua` + `Containers.tick_passive`：晾架槽内水果每 game-hour tick，到 `drying_hours` 阈值 swap 成种子模板
> - `farm_action_runner._apply_farming_proficiency_gain` dead code 删除
> - 16 个农户 NPC：`proficiency.farming` 字段迁出 → `knowledge_books += farming_basics`

整个 farming 轴只接了 `dry_tomato_seed` / `dry_flax_seed` 两条边角反应。

**真正的农活无熟练度区分**：种地 / 浇水 / 收获 / 除虫 / 户主管理三块田。`oren_vale` 标 farming=70 但他干的活和零熟练度 `magda_kerr` 落到 `farm_action_runner` 里几乎走同一路径。

顺带：`dry_seed` 工具 ↔ farming 这种"跨轴串味"让 farming 单一数值同时代表"种地"+"晒种"两件本质不同的事。

**修法（待确认）**：
- (a) 把 farming 拆成 `cultivation`（耕种）+ `drying`（晒制）
- (b) 补 `farm_action_runner` 里所有动作的 proficiency 接入
- 需要先和用户确认设计意图

---

### 🟡 11. 没有"技能书 → proficiency 数值"通路 [OPEN — B2 待决策]

`skills.json` 现在只把 entries 灌进 agent memory（按 axis 分组渲染），不写 `npc_proficiency`。

doc §10 提到的"学徒永远无法靠攻顶级 reaction 突破"目前没补救路径：要么静态 seed 高 p，要么慢慢攒——技能书理论上是天然出口但没接。

**修法（待确认）**：是否要让"读完 saltmaking_basics → `proficiency.salt_making += 10`"？要确认设计意图（读书是一次性涨上限，还是给一次"起步推力"，还是只解锁感知）。

---

### 🟡 12. 天花板事实上爬不到 master [OPEN — B3 待决策]

- lua 最高 difficulty=65
- 公式在 p>75 时 `slow_base = (100-p)/80 < 0.3`，`^1.5 ≈ 0.16`；`chal = max(0, (d-p)/20)` 在 d≤p 时为 0
- master tier 阈值 90，普通 game loop 内没人能自然爬到

**修法（待确认）**：
- (a) 加几个 d=80+ 的传说级 reaction
- (b) 调曲线把 plateau 拉到 85
- 要确认"是否希望普通 loop 内有人能爬到 master"

---

## P2 — UX / 工程整洁

### 🟡 13. 玩家本人看不到自己的熟练度 [OPEN — C2 等触发]

DB / `character.get_proficiency_table` 已经通用化，Player 也能读；LLM 在 prompt 里看得到，但游戏 UI 没有任何窗口告诉玩家"我木工到了多少"。

玩家干一周不知道涨没涨。

**修法**：先看玩家有没有抱怨；UI 设计要和已有的 character_attributes 面板风格统一。

---

### 🟡 14. `smelt`（forge + mint）没有 group gate [OPEN — D1 等触发]

doc 写"国家管控铸币靠未来 group 过滤"，目前不存在。Godot `_find_workstation` 的 `access_denied` 是 group→workstation 那层，不是 tool→workstation 那层。

短期 NPC 没动机也没材料去 mint，但 player 端会暴露。

**修法**：等真有玩家走过去再说；或趁 #1 加 axis gating 时顺手把"axis 是否需要特定 group"也加进 registry。

---

### ✅ 15. `factory.ts` 把 axis 工具和 `draw_water`/`use_container` 混在一起 [DONE]

> **已解决**：`factory.ts` 把这两个工具物理上拆成独立块，注释明确写"未来加 proficiency gating 时**不要**误伤 use_container / draw_water"。

`axis-registry` 注释明确把这俩排除在 axis 外，但 factory 注册位置紧贴 axis 工具。将来加 proficiency gating 时要小心别把这俩一起 gate 掉。

**修法**：注释里点一下、或在 factory 里把它们物理上分两块注册。

---

## 优先级建议（执行顺序）

```
P0 三个一起做（互相强化）：
├─ #1  factory.ts 按 proficiency 过滤
├─ #2  prompt 加 difficulty 提示（先做零代码版：i18n 一句话）
└─ #3  失败 event 加 difficulty/fail_mode 因果信号

P1 真值层做一次性根治（#4 是其他几个的根）：
├─ #4  axis-registry 加 SKILL_ID_BY_AXIS 单点真值
├─ #5  顺手 boot-time assert reaction.skill_id 完整性
├─ #6  GD 从 axis-registry 读，删两处镜像
├─ #7  mining gain 路径合并
├─ #8  en/skills.json 补 skill_axis
└─ #9  axis 文案抽成单点真值（和 #4 同次解决）

需要先和用户确认设计意图：
├─ #10 farming 是否拆轴 / 是否补全所有农活
├─ #11 技能书是否给 proficiency 数值
└─ #12 master 是否能爬到

P2 等需求触发：
├─ #13 玩家 UI
├─ #14 mint group gate
└─ #15 factory 工程整洁
```
