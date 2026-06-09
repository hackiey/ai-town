# Impairment System（醉酒 / 生病 损伤层）

> Status: **landed v1.3**（2026-06-08）。drunk（醉酒）+ sickness（生病）两个 0..100 数值属性，sickness 由症状 `symptoms` 派生；`diseaseId` 只作为内部主病因，叠成一层"做什么都更差"的损伤效果。
> 配套 [player-stats.md](./player-stats.md)（基础数值）、[simulation-layer.md](./simulation-layer.md)（tick 衰减）、[scripting-layer.md](./scripting-layer.md)（effects / affect 通路）、[two-track-agent-session.md](./two-track-agent-session.md)（prompt 感知 + roleplay）。
> 单一口径在 `src/sim/characters/impairment.gd`（`class_name Impairment`）；**所有曲线只在那一个文件定义**，本文是它的设计说明。

---

## 0. 一句话模型

角色身上有两个会变化的损伤来源：

| 属性 | 范围 | 怎么涨 | 怎么落 |
|---|---|---|---|
| **drunk**（醉酒） | 0–100 | 喝酒（啤酒 +6/杯） | 自然衰减，**-1 / 10 游戏分钟**（1 杯约 1 游戏小时醒） |
| **sickness**（生病） | 0–100，由 `symptoms` 派生 + 内部 `diseaseId` 主病因 | 低体力/低精力/饥饿风险；吃腐烂 / 馊掉的食物（生成腹泻/恶心/腹痛等症状） | 自然症状衰减极慢；草药挂 4 小时 `medicine_effect` 缓慢改变具体症状，同一时间只保留一剂，重复吃药会刷新为新一剂 |

两者对"干活"的惩罚**取最重**：`impair = max(drunk, sickness)`——不双重暴击，喝醉又生病只按更重那个算。

**说话乱码** 和 **走路踉跄** 是**醉酒专属**，只读 `drunk`，生病不触发。

---

## 1. 为什么这样设计（关键约束）

1. **惩罚只在动作"真正执行"时临时结算，不写回存储的熟练度。**
   如果把醉酒折算成"降低的熟练度"存进 DB，prompt 渲染熟练度时就会显示被污染的值，NPC 会以为自己永久变菜。所以：存储的熟练度始终是真实值；执行某个动作的瞬间，临时算 `p_eff = p - impair` 喂给那一次结算。醒酒/病好后，下一次动作自动恢复——零清理逻辑。
   → 见 [[feedback_derived_state_persist_single_writer]] 的反面：这是**故意不持久化派生量**的例外，因为派生量依赖"此刻在做什么动作"。

2. **曲线单一来源。** 所有阈值、所有乘子公式都在 `impairment.gd`。各结算点（crafting / mining / 农活 / 打水 / 说话 / 走路）只调用，不自己写数。改手感 = 改这一个文件 + physiology.lua 的衰减常量。

3. **drunk 和 sickness 走对称的属性管线**，跟 `rest` 一样是 `character_states` 的 REAL 列，复用现成 hydrate/persist/snapshot/effects 全套，不新建子系统。

---

## 2. 数值曲线（`impairment.gd`，全部可调）

`impair = max(drunk, sickness)`，范围 0–100。

| 用途 | 函数 | 公式 | 醉/病满(100)时 |
|---|---|---|---|
| 烹饪/铁匠/冶炼/磨粉/煮盐/采矿 有效熟练度 | `proficiency_penalty` | `p_eff = max(0, p − impair)` | 熟练度直接扣满 → 失败率↑、品质↓ |
| 种植 / 除虫 失手概率 | `fail_chance` | `clamp(impair/200, 0, 1)` | 50% 失手 |
| 收获产量乘子 | `yield_mult` | `clamp(1 − impair/150, 0.05, 1)` | ×0.33 |
| 浇水入土湿度乘子 | `water_mult` | `clamp(1 − impair/110, 0, 1)` | ×0.09（土壤几乎没涨） |
| 打水量乘子 | `well_mult` | `clamp(1 − impair/200, 0.05, 1)` | ×0.5（只打一半） |
| 说话乱码逐字概率（drunk 专属） | `garble_text` | `clamp(drunk/150, 0, 0.9)` 每字符 | ~67% 字符变 `%^$#@&*` |
| 听不清逐字概率（drunk 专属，听者侧） | backend `garbleHeard` | `min(0.9, drunk/120)` 每字符 | ~83% 字符糊掉 |
| 走路踉跄概率（drunk 专属） | npc.gd `_apply_drunk_stumble` | 每 0.5s 窗口 `drunk/200` | 50%/窗口 → 频繁停顿 |

**档位阈值**（唯一定义在 `impairment.gd` 的 `*_tier_key()`，见下方"单一权威"）：

| | 一档 | 二档 | 三档 |
|---|---|---|---|
| drunk | ≥6 微醺 (`DRUNK_TIPSY`) | ≥30 醉酒 (`DRUNK_DRUNK`) | ≥60 烂醉 (`DRUNK_WASTED`) |
| sickness | ≥10 轻症 (`SICK_MILD`) | ≥40 中症 (`SICK_MODERATE`) | ≥70 重症 (`SICK_SEVERE`) |

### 档位的单一权威（**阈值只在 Godot 判一次**）

> ✅ **阈值常量只存在于一处：`impairment.gd` 的 `drunk_tier_key()` / `sickness_tier_key()`。** 其它任何地方都不准再写 `≥60`、`≥30` 这种判断。
>
> 数据流：Godot 算出档位 key（`""`/`tipsy`/`drunk`/`wasted`、`""`/`mild`/`moderate`/`severe`）→ 随 raw 数值一起持久化到 `character_states.drunkTier` / `sicknessTier`（[[feedback_derived_state_persist_single_writer]]，与 freshness `tier` 同一套路）→ backend `character-repo.ts` SELECT 这个 key → prompt / say 渲染**直接用 key**，不重判阈值。
>
> 各处只是**消费** key，不复制阈值：
> - HUD 标签：`impairment.gd` 的 `*_tier_label()` 自己也是 `match *_tier_key()`，阈值不二次出现。
> - Backend prompt：`assemble-from-manifest.ts::pushImpairmentLines(kind, tierKey, value)` 收 key，只拿 raw `value` 显示 "65/100"。
> - Backend 听不清门槛：`say.ts` 门槛是 `viewerDrunkTier === "wasted"`，**不再有 `HEAR_GARBLE_DRUNK = 60`**。
> - 文案 key：`data/i18n/zh/{prompts,ui}.json` 的 `impairment.*`——key 名（tipsy/wasted/...）是 wire 契约（[[feedback_wire_carries_ids_not_names]]），不是阈值。
>
> **想改档位分界 → 只动 `impairment.gd` 两个 `*_tier_key()` 函数，全链路自动跟随。**
>
> ⚠️ 历史教训：v1 曾把阈值在 Godot + `assemble-from-manifest.ts` 的 `IMPAIRMENT_TIERS` + `say.ts` 各写一份(共四处)，跨 Godot/backend 进程边界复制同一组数——这正是"改一处忘改另一处 → 一堆 bug"的典型。v1.1 收成单一权威，见 [[feedback_derived_state_persist_single_writer]]。

---

## 3. 状态影响逐项落地（**复杂在这里，逐个动作说清**）

每一项都遵循同一模式：**结算点读 `Impairment.work_impair(character)`（或 `drunk_level`）→ 套对应曲线 → 改这一次动作的结果**。下表是"哪个动作、在哪个文件、怎么被改"的完整清单。

### 3.1 干活惩罚（读 `work_impair = max(drunk,sickness)`）

| 动作 | 注入文件 | 怎么改 | 资源是否照扣 |
|---|---|---|---|
| **烹饪/铁匠/冶炼/磨粉/煮盐** | `crafting.gd::resolve` 传 `work_impair` 入参 → `crafting.lua::on_resolve` 在取到 `p = proficiency[skill]` 后做 `p = max(0, p − work_impair)`，再进 execute | 同时压低 fail_chance 和 quality（两者都由 `p` 驱动，单点注入） | 失败按 crafting.lua 既有规则（通常消耗输入） |
| **采矿** | `workstation_action_runner.gd` 调 `Mines.try_yield(ws_id, Impairment.work_impair(character))`；`mines.gd::try_yield` 内 `p = max(0, current_p − work_impair)` | 矿点产出概率/品质走降低后的 p | — |
| **种植** | `farm_action_runner.gd::try_plant_seed_at`：spawn 前掷 `fail_chance(impair)` | 失败 → 返回 `ok:false` | **失败也消耗种子**（`consume_one`，种子不返还 = 手抖种废了） |
| **收获** | `crop.gd` harvest ctx 传 `harvest_yield_mult = yield_mult(impair)` → `crops.lua::grant_harvest_item` 做 `qty = floor(qty × mult + 0.5)` | 产量按乘子缩水（mult<1 才触发） | — |
| **浇水** | `farm_action_runner.gd::try_water_farm_at`：`moisture_delta = WATERING_MOISTURE_DELTA × water_mult(impair)` | 入土湿度缩水（"手一抖洒了大半"） | **水照样全扣**——桶里的水全消耗，只是没浇进土里 |
| **除虫** | `farm_action_runner.gd::try_remove_pest_at` + `try_remove_pest_facing`（两处同逻辑）：掷 `fail_chance(impair)`，失败则不执行 `remove_pest` | 失败 → 害虫还在 | **草木灰先扣再判**，失手不返还 |
| **打水** | `workstation_action_runner.gd::_try_well_draw`：装入量 `full_add × well_mult(impair)`，桶里只到 `current + 缩水后的量` | 只打半桶 | — |

> **"资源照扣"是这套设计的核心手感**：醉着干活不是"白干"，是"赔本干"——种子、草木灰、桶里的水都真消耗掉，只是产出打折或归零。这让醉酒有实际经济代价，NPC/玩家会避免醉着干活。

### 3.2 醉酒专属：说话乱码（**双向，最绕的一段**）

喝醉影响"说"和"听"两端，两端独立、用不同强度，要分开看：

**(a) 说出去糊（speaker 侧，Godot）**
`speech_controller.gd::emit_say` 在发事件前，用 `Impairment.garble_text(text, drunk_level(speaker))` 把要说的话按**说话者自己的 drunk** 逐字符糊掉（`drunk/150` 概率，空白保留）。
**糊过的文本进 RPC + world_event**——即 canonical 事件文本本身就是醉话版。所以**所有听众听到的都是这同一版乱码**（"他说话舌头打结"是客观事实，人人一致）。

**(b) 听不清再糊一层（listener 侧，Backend，烂醉专属）**
广播是一次发给多人，但"听不清"是**每个听者各自**的状态，不能写进 canonical 事件。所以这一层在**backend 按听者渲染时**做：
`say.ts::garbleHeard(spoken, viewerDrunk, viewerDrunkTier)`——当**正在被装配 prompt 的那个 agent（听者）**自己档位为 `wasted`（烂醉）时，把他听到的别人的话**再糊一层**（强度 `drunk/120`，更狠；强度是听者侧独有曲线，无 Godot 对应，留 backend 本地常量）。门槛走 Godot 算好的 `viewerDrunkTier`，**不在 backend 复制 `60`**。
关键细节：`if (event.actorId !== viewerId)` —— **只糊别人说的，不糊自己说的**（自己醉话已在 speaker 侧糊过，再糊自己听自己没意义）。

**听者 drunk + tier 是怎么传到 say.ts 的**（一条贯穿前后端的链路）：
```
character-repo.ts (SELECT drunk, drunkTier)
  → AgentCurrentContext.selfDrunk / selfDrunkTier   (assemble-from-manifest.ts)
  → renderer.ts renderAgentTimelineEntries(viewerDrunk, viewerDrunkTier)
  → event-descriptions/index.ts renderEventLine(viewerDrunk, viewerDrunkTier)
  → say.ts renderSayToEventLine(viewerDrunk, viewerDrunkTier) → garbleHeard()
```
> 只有 say 事件需要这两个参数，所以全链路默认 `0` / `""`，仅 say 路径真正使用。`viewerDrunkTier` 做门槛、`viewerDrunk` 只做强度曲线。

> 观感一致性：两端的符号池一样——Godot `GARBLE_CHARS = "%^$#@&*"`，backend `GARBLE_POOL = "%^$#@&*"`。

### 3.3 醉酒专属：走路踉跄
`npc.gd::_physics_process` 的 walking 分支，`move_and_slide` 前调 `_apply_drunk_stumble(delta)`：每 0.5s 窗口掷 `drunk/200` 概率，命中则 velocity 置 0 约 0.6s（原地踉跄一下）。
- 只作用于 `move_to_location` 的寻路移动，**不干预玩家手动 WASD**。
- 表现为醉酒 NPC 走两步顿一下，路上莫名其妙停顿。

---

## 4. 属性管线（drunk / sickness 怎么存怎么传）

跟 `rest` 完全对称，复用现成全套：

| 环节 | 文件 | 说明 |
|---|---|---|
| 内存属性 | `character.gd` | `var drunk: float` / `var sickness: float` / `var disease_id: String` / `var symptoms: Dictionary`；`const MAX_IMPAIRMENT := 100.0` |
| DB 列 + 迁移 | `db.gd` | `character_states` 加 `drunk`/`sickness` REAL + `diseaseId` TEXT + `symptoms` JSON TEXT + `drunkTier`/`sicknessTier` TEXT（派生档位 key，Godot 单一写者随 raw 一起 UPSERT，供 backend SELECT）；`_apply_schema_migrations` 走 `_ensure_column`；save SQL 带上这些列 |
| hydrate / persist | `character_state_io.gd` | hydrate 读 drunk/sickness/diseaseId/symptoms（tier 不回读，Character 现算）；老存档无 symptoms 时按 diseaseId+sickness 生成初始症状；persist payload 带 raw + symptoms + `Impairment.drunk_tier_key/sickness_tier_key` 算出的 tier |
| snapshot | `character_snapshots.gd` | `attributes()` 和 `ui_profile().vitals` 都给 `{current, max: Character.MAX_IMPAIRMENT}` |
| 多人同步 | `player.tscn` | SceneReplicationConfig 加 drunk / sickness / disease_id |
| HUD | `status_bars.gd` | 显示 `Impairment.drunk_tier_label` / `disease_label + sickness_tier_label` |
| Backend 读取 | `character-repo.ts` + `types.ts` | SELECT + 解析 `drunk`/`sickness`/`diseaseId`/`symptoms`；`CharacterStateView` 加字段 |

**效果通路**（喝酒 +drunk / 疾病生成症状 / 草药缓解症状都走这条）：
- `effects.gd`：`modify_drunk` / `modify_sickness` / `modify_disease_sickness`（照 `modify_rest`，clamp 0..MAX_IMPAIRMENT，persist；`diseaseId` 在 sickness 归零时清空）
- `script_api.gd`：lua 侧 `affect.drunk` / `affect.sickness` / `affect.disease_sickness` / `affect.symptom`
- `item_effects.gd::apply_to_caster`：`base_effects` 里的 `"drunk"` / `"symptom.<id>"` / `"disease.<id>"` key → modify_*；带 `medicine` tag 的物品由 `item_use.gd` 先把 `symptom.<id>` 转成 4 小时 `medicine_effect`，重复服药替换并刷新当前疗程但不叠加。

**衰减**（`physiology.lua::on_slow_tick`，按 tick 实际时长缩放，基准 10 游戏分钟）：
- `drunk_decay_per_tick = 1.0` → `affect.drunk(char, -min(dec, drunk))`
- `sickness_decay_per_tick = 0.05` → `affect.sickness(char, -min(dec, sickness))`
- `-min(dec, x)` 保证不会减成负数。

---

## 5. Prompt 感知 + roleplay

`assemble-from-manifest.ts::pushImpairmentLines`：drunk / sickness 各自超阈值时，往自我状态 push **三行**——
1. **状态行**：当前档位 + 数值（如"醉酒程度：烂醉 65/100"）
2. **后果提示**：告诉 LLM 这状态会让它做事更差（别让它以为自己状态正常）
3. **roleplay 指令**：要求它**演**得像个醉汉/病人（说话语无伦次、行动不利索）

文案在 `data/i18n/zh/prompts.json` 的 `prompt.context.impairment.{drunk,sick}.{label.*, line, consequence, roleplay}`；前后端共用 `data/i18n`。
HUD 文案在 `data/i18n/zh/ui.json` 的 `ui.status.impairment.*`。

**只给定性，不量化（2026-06-06 复核确认保持）**：prompt 里只有"会变差"的定性后果 + roleplay，**不写**有效熟练度落差（`62→50`）、失败率、产量乘子等具体数。而且属性/手艺块照显示**真实**熟练度（62），不是打折值——因为惩罚执行时才算、不写回存储（§1.1）。落差由"后果"那行定性桥接。这是刻意的：LLM 只译意图，量化结果交模拟层掷骰（[[project_reactions_are_physics]]）。代价是 LLM 缺量化信号去"知难而退"；若以后想让损伤更强地影响**决策**，可在手艺块加"有效值"落差或档位行动建议——当前选择不加。

---

## 6. 生病成因 + 解药（Phase 4）

- **自然成因**：`physiology.lua` 在低体力/低精力/饥饿风险命中时调用 `affect.disease_sickness`；体力过低偏向 `cold`（感冒），低精力/饥饿偏向 `exhaustion_sickness`（虚劳）。
- **腐食成因**：`item_use.gd` 在 `view.has_tag("spoiled")` 或 `perishable.is_rotten()` 时追加 `disease.stomach_illness = +35`（与新鲜度乘子无关的固定值）。
- **治疗**：`herbal_remedy` 是弱通用缓解；`mint_mugwort_tea` 作为感冒主药缓咳嗽/鼻塞/发冷并轻压发热，`ginger_plantain_broth` 作为肠胃主药缓腹泻/恶心/腹痛，`calendula_salve` 作为伤口主药缓伤口疼痛/红肿并轻压发热，`valerian_tonic` 缓乏力/头晕/手脚发软。一场病先按核心症状吃主药，若共享症状（乏力/头晕/发热/发冷）明显，可在疗程结束后换第二味辅药；药效不是即时扣除，而是 4 小时内按 tick 缓慢改变症状；同一时间只有一个 `medicine_effect`，再次服药会消耗药并用新药刷新疗程。
- **来源**：圣钟草药园两块田种薄荷、艾草、姜、车前草、金盏花、缬草；草药在炼金台 `compound` 成药。草药收获不直接给种子，必须由 NPC 把一部分收获物放进晾晒架留种：叶/花类 24 小时通常 1→2 颗种子，姜根/缬草根 36 小时通常 1→1 颗种子。

---

## 7. 调参索引

| 想改 | 改哪 |
|---|---|
| 干活惩罚力度 / 各曲线 | `src/sim/characters/impairment.gd` |
| 衰减速度（醒酒快慢 / 病好快慢） | `data/mechanics/physiology.lua` 的 `drunk_decay_per_tick` / `sickness_decay_per_tick` |
| 喝一杯涨多少 drunk | `data/items/beer.tres` `base_effects.drunk` |
| 吃馊食涨多少 sickness | `src/sim/items/item_use.gd` `ROTTEN_SICKNESS` |
| 草药缓解哪些症状 | `data/items/*.tres` `base_effects.symptom.<id>` |
| 对症药效果 | `data/items/*tea.tres` / `*broth.tres` / `*salve.tres` / `*tonic.tres` 的 `base_effects.disease.<id>` |
| 档位阈值（含听不清门槛 wasted） | **只动 `impairment.gd` 的 `drunk_tier_key()` / `sickness_tier_key()`**——backend 读持久化的 tier key，零阈值复制（见 §2） |

---

## 8. 验证清单（本机无 godot 二进制，编辑器内手测）

1. **累计/衰减**：连喝 2 杯 → drunk≈12 → HUD"微醺"；`/timewarp` 加速 ~2 游戏时归 0。
2. **干活变差**：烂醉(>60)烹饪失败率/品质↓；收获产量↓；浇水土壤几乎没涨且桶空了；打水只装半桶；种植/除虫频繁失手且不返还种子/草木灰。
3. **醉酒专属**：醉酒 NPC 说话冒 `%^$#`；`move_to_location` 途中踉跄停顿；自己烂醉时听别人说话也糊（debug-agent 看 prompt）。
4. **生病闭环**：低资源或吃馊食 → symptoms↑、sickness 派生↑ 且 diseaseId 设置；干活变差但**说话不乱码/走路不停顿**；通用草药弱缓解，对症状的药缓慢下降对应症状。
5. **prompt**：debug-agent 看醉/病 NPC 的 system prompt，确认有状态行 + 后果 + "演成醉汉/病人"的 roleplay。
6. **backend**：`pnpm -C backend tsc --noEmit` 过 character-repo / assemble-from-manifest / say.ts 改动。

---

## 修订记录

- 2026-06-08 (v1.3)：新增症状层 `symptoms`。疾病只负责内部病因和症状生成；病人 prompt 只显示实际症状，不泄露 `diseaseId`；草药 `base_effects.symptom.<id>` 进入 4 小时 `medicine_effect` 慢性疗程，重复服药刷新但不叠加；`sickness` 由症状派生，继续作为干活惩罚输入。
- 2026-06-08 (v1.2)：新增 `diseaseId` 主病种和 `disease.<id>` 对症药效果；低资源自然生病带感冒/虚劳，腐食带肠胃病；圣钟草药园接入草药作物和对症药配方。
- 2026-06-06 (v1.1)：**档位阈值收成单一权威**。新增 `impairment.gd::drunk_tier_key/sickness_tier_key`（阈值唯一定义处），`character_states` 加 `drunkTier`/`sicknessTier` 持久化列（Godot 单一写者），backend 删 `assemble-from-manifest.ts` 的 `IMPAIRMENT_TIERS` 与 `say.ts` 的 `HEAR_GARBLE_DRUNK`，全部改读持久化 tier key。消除跨 Godot/backend 进程的阈值复制（原四处）。见 [[feedback_derived_state_persist_single_writer]]。
- 2026-06-05 (v1)：drunk + sickness 损伤层落地。统一口径 `impairment.gd`；干活惩罚 `max(drunk,sickness)` 在执行时临时算不持久化；醉酒专属双向说话乱码（speaker 侧 Godot + listener 侧 backend）+ 走路踉跄；生病成因=吃馊食、解药=草药茶（来源暂不做）。
