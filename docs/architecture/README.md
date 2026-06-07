# Architecture docs

Agent 系统、脚本层、实体模型的活文档。当前在迭代，**未完全沉淀到 [tech-doc.md](../tech-doc.md)**。回写是单独任务（见下方"下一步"）。

游戏整体设计见 [design-doc.md](../design-doc.md)；高层技术栈、沙箱概念、工具链见 [tech-doc.md](../tech-doc.md)。

## 首次 setup

克隆仓库后跑一次：
```
./scripts/install-lua-gdextension
```
拉 Lua VM binary（addons/lua-gdextension/build/ 是 gitignored）。详见 [scripting-layer.md §3](./scripting-layer.md#3-implementation)。

## 阅读顺序

跨域问题理解从上往下读；找具体契约或 schema 直接跳到对应文档。

1. [system-architecture.md](./system-architecture.md) — 当前代码结构下的系统总览：Godot client/runtime、backend、目录责任、关键链路
2. [runtime-layers.md](./runtime-layers.md) — 脑(agent runtime) / 身(Godot) 分层、战斗 cadence、headless server per town
3. [game-mechanics.md](./game-mechanics.md) — 玩家机制百科：按当前实装规则整理小镇、数值、制作、农场与互动系统
4. Agent runtime 两件套（一起读）：
   - [two-track-agent-session.md](./two-track-agent-session.md) — **当前唯一 LLM runtime**；action 轨 + thinking 轨双 session 并发，working_memory KV 单向传递，无打断机
   - [agent-shared.md](./agent-shared.md) — runtime 之间共享的非策略代码模块（name-resolver / event-descriptions / game-tools / prompt-context 等）+ per-agent 边界
5. [scripting-layer.md](./scripting-layer.md) — Lua VM + ScriptExecutor 公共契约 + spec.ts 设计原则
6. [entity-model.md](./entity-model.md) — Substance + Character + Wand + active_statuses
7. [simulation-layer.md](./simulation-layer.md) — 三种 tick 节奏 + emergent 反应 + Crop / NPC 行动 + 失败可观测性
8. [crafting-interaction.md](./crafting-interaction.md) — 动词系统 + 工作站 + 万能 ActionPanel UI；玩家怎么触发反应表
9. [reaction-schema.md](./reaction-schema.md) — 反应表的 Resource schema：Material / Verb / Reaction / Item 实例化 / 匹配语法 / 代价 + 失败模型
10. [100-item-experiment.md](./100-item-experiment.md) — 用 100 件具体 item 验证 schema；逐批跑 20/50/100，发现缺口回填 schema
11. [base-items.md](./base-items.md) — MVP 物品清单（29 件 + 5 工作站 + 9 NPC 职业链）；每件可制造
12. [player-stats.md](./player-stats.md) — 玩家数值系统：hp / stamina / hunger / rest 5 个 stats、动态 stamina_cap、衰减 / 恢复 / 行为消耗、buff schema、食物效果表
13. [state-persistence-plan.md](./state-persistence-plan.md) — 常见游戏状态的持久化规划：哪些要建正式真值表、谁负责写、按什么阶段落地
14. [godot-agent-protocol.md](./godot-agent-protocol.md) — Godot server 单方面对外承诺的 WS 协议：snapshot / event / status push + action 流 + authority 边界 + 版本演进
15. [backend-agent-host.md](./backend-agent-host.md) — Backend 作为 agent host 的内部架构：godot-link / agent-host / runtimes 三层、AgentRuntime 接口、per-NPC runtime 路由
16. [lua-mechanic-migration-plan.md](./lua-mechanic-migration-plan.md) — 把游戏机制全部迁到 `data/mechanics/*.lua` 的实施计划：已 landed Step 0–3.5，余下 physiology / perishable / mining / backend verbs / durative action
17. [combat-system.md](./combat-system.md) — 哈利波特式魔杖咒语对战：时间分层（frame/tick/LLM）、Spell+Wand schema、Lua 契约、行为树 NPC AI、LLM 战斗边界、P0→P4 实施路径
18. [impairment-system.md](./impairment-system.md) — 醉酒 / 生病 损伤层：drunk + sickness 两个 0..100 属性，干活惩罚取 max 在执行时临时算（不污染熟练度），醉酒专属双向说话乱码 + 走路踉跄，逐动作影响清单 + 调参索引

## 状态总表

| 域 | 文档 | 状态 | 关键 landed |
|---|---|---|---|
| Runtime layers | [runtime-layers.md](./runtime-layers.md) | partial | 三进程拆分（backend / godot server headless / godot client，ENet + @rpc）已落地 |
| Game mechanics | [game-mechanics.md](./game-mechanics.md) | partial | 玩家机制百科，整理当前版本的详细规则、数值、配方、农场与交互系统 |
| Agent session (two-track) | [two-track-agent-session.md](./two-track-agent-session.md) | landed | 唯一 LLM runtime；`ActionTrackSession` + `ThinkingTrackSession` 双轨；`runtime_storage.working_memory` KV 单向传递 brief；per-NPC 双模型配置；think-first 路径（woke_up）+ significant 事件异步触发 thinking |
| Agent shared modules | [agent-shared.md](./agent-shared.md) | landed | `agent-shared/` 9 个子模块清单 + 共享 vs per-agent 边界规则 |
| Scripting layer | [scripting-layer.md](./scripting-layer.md) | partial | Lua VM + `ScriptExecutor.execute()` + 1 个 effect type + 沙箱白名单 |
| Entity model | [entity-model.md](./entity-model.md) | partial | Substance（8 种）+ Character（hp/stamina/statuses/equipped）+ NPC extends Character |
| Simulation layer | [simulation-layer.md](./simulation-layer.md) | drafting | 仅设计稿；fast/slow tick + scheduled events + Crop 状态机 + NPC 行动 additive/possessive 分类 |
| Crafting & interaction | [crafting-interaction.md](./crafting-interaction.md) | drafting | 仅设计稿；动词系统 + 工作站 + 万能 ActionPanel + Recipe-as-shortcut + 经济闭环；端到端铁铲示例 |
| Reaction schema | [reaction-schema.md](./reaction-schema.md) | drafting | 仅设计稿；Material/Verb/Reaction Resource、匹配语法、verb 策略、品质 + 体力 + 时间 + 失败、物品实例化（无堆叠）|
| Base items | [base-items.md](./base-items.md) | drafting | 仅设计稿；MVP 29 件清单 + 反应规则草稿 + 9 NPC 职业链 |
| Player stats | [player-stats.md](./player-stats.md) | drafting | 仅设计稿；hp/stamina/hunger/rest 4 基础 + 衍生 movement/strength；动态 stamina_cap + 食物 + buff schema |
| State persistence | [state-persistence-plan.md](./state-persistence-plan.md) | partial | 计划文档；2026 主体已落地（Godot 持有 game-world schema，backend 通过 world-state repos SELECT-only） |
| Godot↔agent protocol | [godot-agent-protocol.md](./godot-agent-protocol.md) | partial | envelope version、typed TS action / perception-manifest / event、Godot agent-host WS、action lifecycle；Godot 侧仍是 Dictionary 校验 |
| Backend agent host | [backend-agent-host.md](./backend-agent-host.md) | partial | godot-link / agent-host / runtimes / services-world-state 分层、AgentRuntime 抽象、two-track-agent runtime、action_log/action bus、perception-manifest cache |
| Combat system | [combat-system.md](./combat-system.md) | drafting | 仅设计稿；三层时间线（frame/fast-tick/LLM）+ **三层职责（Spell 投递 / Reaction 物理 / Wand 装备）**：effect/难度/学派复用 reaction-schema，威力四因子，角色无 mana 耗魔杖储能，react.apply 桥 + channel 三段契约 + 投递层物理 API + 行为树 + LLM 战斗边界 + P0→P4 |
| Impairment system | [impairment-system.md](./impairment-system.md) | landed | drunk + sickness 两个 character_states 数值列；干活惩罚 `max(drunk,sickness)` 执行时临时算不持久化；曲线单一口径 `impairment.gd`；醉酒专属双向说话乱码（speaker Godot + listener backend）+ 走路踉跄；衰减走 physiology.lua；生病=吃馊食、解药=草药茶（来源暂不做）|

## 跨域待决问题（高优先级）

每个文档自己的 §Open questions 是域内问题。下面这些跨域：

- **Sandbox hardening**（[scripting-layer.md §5](./scripting-layer.md#5-沙箱当前状态)）：指令 cap / 内存 / timeout —— LLM 上线前必须
- **回写 design-doc**：mana 概念从角色属性迁到魔杖（[entity-model.md §2.2](./entity-model.md#22-角色资源模型)），design-doc §3 三层资源经济需要更新
- **回写 tech-doc**：把本目录全部 land 到 tech-doc 对应章节，覆盖现在含糊的 worker 描述（tech-doc §1）和过时的沙箱选型（tech-doc §2"LuaJIT 或 QuickJS"）
- **状态真值落地顺序**：按 [state-persistence-plan.md](./state-persistence-plan.md) 先补角色 / 物品 / 时间 / 农田 / effect，避免继续把 runtime 状态塞进 context JSON

## 下一步（按重要性）

1. **Co-design 第一轮**：用户提 5 个法术（自然语言），claude 写 mock lua（按现有 + 编新的 API 名），双方一起标注用了哪些 API、读写了哪些属性。spec.ts 形状靠这一轮收敛
2. **回写 design-doc**：mana 载体迁移
3. **回写 tech-doc**：把 architecture/ 内容沉淀

代码上的下一批实现（按依赖排序）：
- Wand class（[entity-model.md §2.2](./entity-model.md)）
- Item base class（另一个 session 在做）
- Simulation layer MVP：scheduled events / slow tick / Reaction dispatcher / containment graph / fast tick + 燃烧 / 一种作物端到端（[simulation-layer.md §4](./simulation-layer.md#4-implementation-status)）

## 修订记录

- 2026-05-06：从 `docs/agent-runtime-design.md`（已删）拆分。原文档把"还在讨论 / 已落地实现 / 状态追踪"三类内容混在一起，475 行难以扫读。拆成 4 个域 + 1 个索引，每个域文档可独立阅读，跨域问题集中在本 README
