# Simulation layer

> Status: **drafting** — 仅设计稿，尚无代码。本文整合"物理 tick + 慢速 simulation + scheduled events + NPC 行动消耗时间"四件之前散落或未明的事，作为 emergent 合成 / 农作 / 燃烧 / 腐烂 等机制的统一基底。

世界里"东西自己会变化"的统一机制。物理反应、农作物生长、buff 倒计时、腐烂生锈、季节流转都跑这一层。

## 1. Context

[entity-model.md](./entity-model.md) 定义了"东西的属性"（substance、temperature、moisture），但**没人在 tick 里推动这些属性变化**。[scripting-layer.md](./scripting-layer.md) 定义了"脚本怎么声明 effect"，但**只覆盖一次性、玩家触发的执行**，没说世界自己怎么演化。

本层补这一段。设计时面对的关键张力：

- **emergent 物理 vs RPG 配方书**：玩家自创的核心创新要求合成是涌现的（Noita / BotW chemistry），不是查表。但纯 emergent 失去 discoverability、丧失设计师控制——这是绝大多数 RPG 选配方书的真实理由
- **时间尺度跨 6 个数量级**：火焰传播是 sub-second，作物成熟是数十 game-day，树木生长是数百 game-day。一个 tick rate 跑不了所有事
- **NPC 必须真劳作**：[design-doc §3](../design-doc.md) 的核心 selling point 是 NPC 在玩家不在时也活着。如果作物纯靠 timer 自动成熟，农民就退化成装饰

## 2. Design

### 2.1 三种 tick 节奏

按时间尺度分三套机制，**不强行统一成一个 tick**。三套都通过 [scripting-layer.md §2.2](./scripting-layer.md#22-effect-模型声明而不-mutate) 的 effect 系统落地变更。

| 机制 | 节奏 | 用途 | 实现 |
|---|---|---|---|
| **Fast tick** | 2-4 Hz | 热传导、燃烧、电导、phase change、力学反应 | `physics_tick.gd` + active_objects set，只 tick 被扰动的物体 |
| **Slow tick** | 1 / game-hour | moisture decay、pest_load 累积、growth_progress 推进、condition 衰减、温度回归 ambient | `simulation_tick.gd`，扫所有 simulated entities |
| **Scheduled events** | one-shot at game-time | 短时 buff 到期、约定的事件、"3 day 后腐烂"、"30 day 后生锈" | priority queue keyed by game-time，复用 active_effects 的 schema（加 `fire_at` 字段） |

scheduled events 和 active_effects 是同一个东西的两面（持久 vs 一次性），共用一张表 + 一个 tick loop。详见 [§2.6](#26-scheduled-events--active_effects-合并)。

### 2.2 反应规则三层（emergence + 配方）

按"修改频率"切，**不让 emergence 和 recipe 互斥**：

| 层 | 例子 | 实现 | 改动频率 |
|---|---|---|---|
| **物理基本律** | 热传导方程、燃烧消耗氧气、phase change 阈值 | gdscript 写死在 fast/slow tick | 极低 |
| **Substance 反应表** | `wood + temp > 300 → ignite`，`water + temp > 100 → boil → spawn(steam)` | `Reaction` Resource (.tres)，dispatcher 遍历匹配 | 中（迭代时常加） |
| **Emergent 合成 / 玩家自创** | 「会喷火的剑」、「LLM 即兴判合理性的奇怪组合」 | Lua 脚本，跑 [scripting-layer.md](./scripting-layer.md) 的 ScriptExecutor | 高（玩家驱动） |

**关键**：reaction 表是按 substance 颗粒（"任何 wood"），不是按 item 颗粒（"oak_log"）——所以 N 条规则可以覆盖 N×M 的 item 笛卡尔积。这是规则开放的核心。

### 2.3 Recipe 退化为 NPC 自然语言知识

之前一度考虑独立的 `recipes` collection（设计师 / NPC / 玩家三种来源）。**砍掉了**。理由：

- 既然 NPC 是 LLM agent，"recipe" 就是他记忆里的一段自然语言，不需要独立 schema
- 物理引擎完全不需要知道"recipe"概念，它只跑 reaction 表
- 玩家学到的 recipe = 笔记本 / 记忆 / 问 NPC 拿到的话

物理引擎里**没有 recipe 这个名词**。只有 substance + reaction。Recipe 活在对话和 NPC 知识里，由 LLM 中介。

**好处副作用**：
- "老铁匠死了，锻造秘技失传"天然成立——它本来就是文本
- recipe 可以错、可以是误传、可以是秘方
- LLM 不再只用于"生成 lua"，更常用的是"教玩家"和"判合理性"

### 2.4 Containment graph：邻接关系不能用 scene tree

物理交互的两种关系：

- **空间邻接**（"火球离木桶 0.5m"）：Godot 的 `Area3D` + `body_entered/exited` 信号天然能给，免费
- **包含 / 接触关系**（"苹果在锅里、锅在火上"）：**不**用 scene tree 的 parent/child（苹果不该是锅的子节点，否则 transform 错乱）

后者用单独的图：`src/sim/physics/containment.gd` 维护 `Dictionary[container_id → Array[content_id]]` 和反向索引。`affect.put_in(apple, pot)` / `affect.put_on(pot, fire)` 改这个图，不动 scene tree。

热传导走两条边：
- 空间邻接 = 辐射 / 对流近似
- containment 边 = 接触传导，效率高数倍

### 2.5 Crop 状态机：连续条件 + NPC 行动驱动

农作物的设计原则：**不能用 scheduled event "72h 后 ripen"**——那让 NPC 完全可被绕开，农民变装饰。

每株作物是 entity，有自己的内部状态和健康度，**生长进度只在条件满足时才推进**：

```gdscript
Crop {
  variety: CropVariety   # .tres，作物类型的所有静态参数
  stage: "seed" | "sprout" | "vegetative" | "flowering" | "ripe" | "rotten"
  growth_progress: 0.0..1.0     # 当前 stage 的进度
  health: 0.0..1.0              # 综合健康
  
  # 由 slow tick 维护的连续条件（不 clamp 在 1.0）
  moisture: 0.0..2.0            # 每 game-hour -= dehydration，浇水 +=
  pest_load: 0.0..1.0           # 每 game-day += infestation，除虫重置
  soil_fertility: 0.0..1.0      # 每次结实 -= drain，施肥重置
  
  # 协作元数据（暴露给 NPC 感知）
  last_watered_at: float
  last_watered_by: String
  currently_being_worked_by: String | null
  current_action_type: String | null
}
```

**Slow tick 推进规则**：

```
每 game-hour:
  moisture -= variety.dehydration_per_hour
  pest_load += variety.pest_susceptibility / 24
  
每 game-day:
  if moisture in optimal_band AND pest_load < threshold AND season_match:
    growth_progress += variety.daily_increment
    if growth_progress >= 1.0:
      stage = next_stage(stage); growth_progress = 0
  else:
    health -= stress(moisture, pest_load)
  
  if health <= 0:
    transmute → "dead_crop"
```

**Moisture 区间**（关键：不饱和、optimal 是带不是点）：

```
0.0 - 0.2     dry                 缺水，损失成熟度
0.2 - 0.8     optimal             正常生长
0.8 - 1.0     wet                 过湿，损失成熟度
```

**作物差异全在 .tres 数据**：

```
小麦   water_boost: 0.5  watering_interval: 24h  pest_susc: 0.3  multi_harvest: false  lifecycle: 60d
番茄   water_boost: 0.4  watering_interval: 12h  pest_susc: 0.7  multi_harvest: true   lifecycle: 120d
苹果树 water_boost: 0.3  watering_interval: 72h  pest_susc: 0.2  multi_harvest: true   lifecycle: 36500d (juvenile 1095d)
```

引擎只跑一套 `update_crop()`，参数全从 variety.tres 读。

### 2.6 NPC 行动：Additive vs Possessive

NPC 农事动作是 action，走 NPC 的 agent loop，**真实消耗 game-time**。

| 动作 | game time | 对作物影响 |
|---|---|---|
| `water(crop)` | 5 min | moisture += variety.water_boost |
| `weed(field)` | 30 min | 邻近 crop pest_load -= 0.3 |
| `pest_control(crop)` | 15 min | pest_load = 0 |
| `fertilize(field)` | 1 hour | soil_fertility = 1.0（消耗一袋肥） |
| `harvest(crop)` | 10 min | transmute → 产物 + 重置 / 进入下个周期 |
| `plant(seed, tile)` | 5 min | spawn 新 Crop entity at seed stage |

NPC 一天 8 game-hour 工作时间，自然形成劳动力瓶颈——50 株番茄一株浇 5 分钟就 4 小时，玩家会观察到"老张忙不过来"，雇帮工有了游戏理由。

#### 2.6.1 行动分类：Additive vs Possessive

不同动作的并发语义不同，**不一刀切用 lock**。

**Additive 类（可叠加，过量有代价）**：
- `water`、`fertilize`、`pest_control` 都是 additive
- 多个 NPC 同时执行 → 物理量叠加 → 超过阈值 → 触发延迟 / 持续 condition
- 例：2 NPC 同浇 dry crop (0.3) → moisture 1.3 → oversaturated → 触发 root_rot 计时
- **不需要 lock，自然惩罚**

**Possessive 类（同一目标只能一个 NPC）**：
- `harvest`（不能两人收同一果）、`plant`（不能在同一格播两棵）
- 实现是动作 commit 时检查原子标记，不是 lock：

```gdscript
func harvest(crop):
    if crop.harvested_this_cycle: return fail("already harvested")
    crop.harvested_this_cycle = true
    spawn yields...
```

第二个 NPC 看到 fail，think loop 转下一个目标。**没有 wait、没有队列、没有死锁**。

#### 2.6.2 过量伤害是延迟 + 持续的（关键）

如果过浇只是 `health -= X`，玩家 / NPC 看不到学不到。要触发**持续的 active_condition**，治疗要付出真实成本：

| Condition | 触发 | 后果 | 恢复 |
|---|---|---|---|
| `root_rot` | moisture > 1.2 持续 > 24 game-h | health -= 0.05/day（缓慢致命）；growth -50% | 必须 dry out 7 day + NPC 做 `treat_rot`（30 min + 药材） |
| `nutrient_leached` | 每次在 moisture > 1.0 时 water → soil_fertility -= 0.1 | 下个 stage growth 减慢 | 重新施肥（一袋肥 + 1h） |
| `pest_swarm` | moisture > 1.0 持续 > 48 game-h | pest_load 立刻 += 0.5 | 比平时更难 pest_control（要做两次） |
| `fertilizer_burn` | fertilize 累计超量 → 烧根 | health -= 0.03/day for 14d | 等自然恢复，无加速手段 |
| `soil_contamination` | pest_control 在 14d 内 >2 次 → 农药残留 | 之后 3 茬作物 -10% 产量 | 等待，无加速 |

**为什么这是对的**：
- 一次过量不致命，但**留疤**——3 周后才表现的虫害、几个月后才显现的贫瘠
- NPC 反思能把"这块田老出虫"和"那段时间老张和我都在浇"关联起来——emergent 学习的素材
- 玩家路过看得到霉斑、虫粒子、蔫黄——视觉反馈先于死亡，叙事完整
- 治疗成本不是 0 → NPC 学着避免，而不是无所谓地反复犯

#### 2.6.3 NPC 协作通过感知 emerge，不通过通信

不加 NPC 通信通道。让 crop 的 `last_watered_at / by` 和 `currently_being_worked_by / current_action_type` 出现在 farm_plots / 相邻 farm_states 真值表里，NPC perception 拼 context 时 SELECT 出来：

```
番茄 #4: moisture 0.3 (偏干)
  上次浇水: 老王，2 小时前
  当前: 老王正在浇水（还需 3 分钟）
```

LLM 看到这种描述会自己做对的事：「老王正在浇了，去隔壁那块」「老王 2h 前刚浇过现在还干 → 这块田渗透太快，要么缺肥要么换排水」。

**不需要新通信通道、不需要任务调度系统**——只要 perception 暴露足够上下文，LLM 的判断力足以处理。这是相对传统农业 sim（Stardew、Rune Factory）的架构优势：他们必须写优先级算法，这里只需要让 NPC 看到状态。

### 2.7 Scheduled events ↔ active_effects 合并

[scripting-layer.md §2.3](./scripting-layer.md#23-持久挂载效果active-effects) 已有 active_effects 模型（持久挂载、`started_at + duration_sec`）。Scheduled events 是同一个问题的另一面——**一次性的、按 game-time 触发的 effect**。

合并到一张表 + 一个 tick loop：

```gdscript
ActiveEffect {
  handle, owner_caster, source_item_id,
  type, params, anchor_id, anchor_bone,
  started_at,
  
  # 二选一：
  duration_sec: float | null,    # 持续型：到 started_at + duration 自动清理
  fire_at: float | null,         # 一次性：到 fire_at 触发 effect 然后清理
  
  # 可选：
  cancel_if: String | null,      # 一段表达式 / lua hook，每 slow tick 评估
  mana_per_tick: float | null,   # 持续型：caster mana 占用
}
```

slow tick 每次扫所有 active_effects：
- `fire_at <= now` → 触发 effect、删除
- `duration_sec` 到期 → 删除
- `cancel_if` 评估为 true → 删除（不触发）

农作物使用例：

```gdscript
# 播种
var seed = spawn_entity("wheat_seedling", pos)
ActiveEffects.create({
  type: "ripen", target: seed.id,
  fire_at: GameClock.now() + 72 * GAME_HOUR,
  cancel_if: "target.dead or target.uprooted",
})
```

但**作物生长其实更适合走 Crop 自己的 slow tick 推进（§2.5）**而不是 scheduled event——因为生长依赖条件累积，不是定时触发。Scheduled event 适合 buff 到期、约定的剧情事件、明确"X 时间后必然发生"的事。

## 3. 失败的可观测性契约

设计层面（不是工程）的强约束：**所有 simulation 状态恶化必须在世界里可见**。否则后台计算无意义。

| 状态 | 视觉契约 | NPC 自感知 |
|---|---|---|
| moisture < 0.2 持续 | sprite 蔫黄 | active_condition: "wilting" |
| pest_load > 0.5 | 虫粒子 / 叶斑 | "I noticed pests on the tomatoes" |
| root_rot 中 | 茎部霉斑 | "the crop near the well always rots" |
| dead_crop | 枯黑残骸（直到清理） | "I lost three plots last month" |
| 着火 | 火焰粒子 + 焦黑 substance 转换 | "Tomas's barn burned down" |

NPC 自感知通过 [entity-model.md §2.3](./entity-model.md#23-active-conditions状态条件-vs-数字-buffdebuff) 的 active_conditions 系统挂——视觉是 sprite/材质效果，认知是文本条件，**两套表达同源**。

## 4. Implementation status

全部未实现。需要按依赖顺序：

```
1. ScheduledEvents / ActiveEffects 合并（先有底层 dispatcher）
   ↓
2. Slow tick loop（无内容，框架先建）
   ↓
3. Reaction Resource + dispatcher（覆盖物理基本反应）
   ↓
4. Containment graph（put_in / put_on）
   ↓
5. Fast tick + active_objects set + 热传导（最小，"接触传染"近似）
   ↓
6. transmute / spawn / ignite / extinguish effect types
   ↓
7. MVP 端到端：苹果 + 锅 + 火 → 烤苹果
   ↓
8. Crop entity + Variety .tres + 一种作物 (麦)
   ↓
9. NPC 农事 action (water / harvest)
   ↓
10. 协作元数据 + 感知集成
   ↓
11. 过量伤害 conditions (root_rot 等)
```

每一步都可独立可玩可验证，不要跳跃。

## 5. Open questions

- **天气系统**：下雨自动浇水？阳光按季节？打开会拖出整个 weather sim，MVP 先不做
- **市场 / 经济联动**：作物产出去哪？谁拥有？拖出 inventory ownership / 集市 / NPC 经济目标
- **多 NPC 共有田地的所有权**：私田 vs 公田？影响 NPC 决策"这是我的责任吗"
- **季节系统**：crop variety 的 `season` 字段需要 game clock 有"季节"概念
- **慢 tick 在玩家离线时的行为**：headless server 永远在跑（[runtime-layers.md §2.3](./runtime-layers.md#23-离线小镇模拟)），所以理论上自动处理；但要验证作物状态在长时间无玩家时不会因边界 bug 漂移
- **Reaction 的优先级 / 排他性**：同一 tick 多 reaction 触发同一 entity 时的 ordering（参考战斗 cadence 的 "action_id hash" 思路）
- **active_effects 持久化频率**：每 tick 写 SQLite 太贵，每 N tick 或事件触发？
