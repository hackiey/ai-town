# Lua Mechanic Migration Plan

> Status: **mostly-done** — Step 0–6 全部 landed（13 mechanics + inventory 套件 + MechanicVerb wrapper）；Step 7 (durative) deferred per §3.4 设计原则（runner 是引擎层，规则已在 crafting/mining lua）。Q1–Q5 决议见 §7。下一步是 god mode 接入（hot reload / sandbox hardening 等，见 §6 out-of-scope）。

把"游戏机制"从 GDScript 全部迁到 `data/mechanics/*.lua`。终态：GDScript 只剩引擎层（物理 / 网络 / RPC / SQLite / Lua VM / scene tree / UI），所有"什么变什么"住在 lua。这是 [scripting-layer.md](./scripting-layer.md) 落地的下一批实施。

LLM 安全 / hot reload / god mode 接入**不在本计划范围**，见 §6。本计划只做"已知逻辑搬家"。

## 1. 当前位置

### 1.1 已迁的 mechanic（3 个）

| Mechanic | 文件 | 责任 |
|---|---|---|
| Speech | `data/mechanics/speech.lua` | 喊话半径、目标在场校验、affected listeners 计算 |
| Crops | `data/mechanics/crops.lua` | varieties 数据、stage / 成熟度 / 害虫 / 收获 hook |
| Crafting | `data/mechanics/crafting.lua` | 26 reactions + dispatch + 匹配 + quality 策略 + failure + output 派生 |
| Physiology | `data/mechanics/physiology.lua` | hunger 衰减 / hungry 阈值进出 / 饿死扣血 / 死亡判定 |
| Container | `data/mechanics/container.lua` | deposit / withdraw / inspect 三合一 verb |
| Wages | `data/mechanics/wages.lua` | claim_wages：矿工日结 + 周结角色，复用 transfer_item 转银币 |
| Sleep | `data/mechanics/sleep.lua` | sleep start (on_resolve) + 醒来 (on_commit)；timer 仍 GDScript |
| Royal | `data/mechanics/royal.lua` | submit_royal_consumption，dry-run + 批量 take_item + world_event |
| Minting | `data/mechanics/minting.lua` | system slow_tick：金/银矿铸成币（spawn_item 入 vault）|
| Mining | `data/mechanics/mining.lua` | per-mine slow_tick settle + on_attempt 概率判定 |
| Perishable | `data/mechanics/perishable.lua` | 物品 tier 衰减 + tier=0 swap 成 rotten material（set_slot_state bulk）|
| Shelf | `data/mechanics/shelf.lua` | update / buy_from thin wrapper + world_event；listings 写还在 GDScript |
| Trade | `data/mechanics/trade.lua` | offer / respond thin wrapper + world_event；撮合 transactional 还在 GDScript |

### 1.2 已有基础设施

`src/sim/scripting/`：
- `MechanicHost`（autoload）：扫 `data/mechanics/*.lua`，每个 = 独立持久 sandbox state
- `ScriptExecutor`：`load_module()` 一次、`call_hook()` 反复；ctx 用 `_gd_to_lua` 递归转 LuaTable；hook 返回值深度转回 GDScript
- `ScriptApi`：注入 `affect.*` / `world.*` API 表
- `Effects`：`affect.*` 声明 → 应用层 mutation 落地
- `LuaConv`：`to_array` / `to_dict` / `to_variant` LuaTable ↔ GDScript boundary

`affect.*` 已有（async，lua 走完 GDScript apply）：`stamina` / `hunger` / `hp` / `broadcast_speech` / `crop_state` / `farm_state` / `crop_destroy` / `give_item` / `add_status` / `remove_status` / `set_alive` / `world_event`。

`affect.*` **synchronous**（lua 期间立即应用 + 返回值给 lua）：`take_item` / `transfer_item` / `set_slot_state` / `spawn_item` / `shelf_op` / `trade_op` —— 这些需要 lua 立即拿到结果做后续判断 / 消息格式化。

`world.*` 已有：`now()` / `material(id)` / `find_item_template(shape, body)` / **`find_items(holder, query)`**。

触发入口：
- GDScript 直接 `MechanicHost.invoke(name, hook, ctx)`（slow_tick / emit_say / craft commit 已在用）
- 玩家 chat：`/cast <mech_name> [args...]` → `Player.request_cast_spell` RPC → `MechanicHost.invoke(mech, "on_cast", ctx)`

### 1.3 性能现状

按当前调用频率（slow_tick 粒度 + on-demand）总成本估算约 **1.8 ms/s ≈ 0.011% 一帧预算**。距离瓶颈差 4 个数量级。本计划范围内不会成为约束。**唯一守住的纪律**：60Hz / per-frame 逻辑不能丢 lua hook，要丢就降级成"lua 当配置 + GDScript 跑 tick"。

## 2. 残留机制按"形状"分类

不同形状的迁移难度差很多，分开规划。

### 形状 A：per-entity slow_tick

数据 + 规则集中在一个 entity 上，按 game-hour 推进。**模式已被 crops 验证。复制粘贴。**

| 候选 | 当前位置 | 行数 | 需要的新 affect |
|---|---|---|---|
| Character 生理（hunger 衰减、starving 扣血、hungry status）| character.gd:259-307 | ~80 | `modify_hp`, `remove_status` |
| 物品腐烂（shelf_life 倒计时、变成 rotten_into）| perishable_aspect.gd | ~110 | `replace_item` 或 `set_item_field` |
| Mining / Minting 产出 | mines.gd / mints.gd | ~80 + 80 | `give_item` 已够 |

### 形状 B：atomic action verb

LLM 或玩家发一个 verb → GDScript 收 → 翻译成 affect。每个 verb 当前 ~80–250 行，本质是"参数校验 + 状态查询 + state mutation 序列"。lua 化后每个 verb = 一个 hook 函数。**形状新，第一个迁的 verb 要做模式验证。**

| 候选 verb | 当前位置 | 行数 | 需要的新 affect |
|---|---|---|---|
| 容器 deposit / withdraw / inspect | backend_action_runner.gd:416-475 | ~100 | `container_transfer`, `container_query` |
| 工资 claim_wages（含 miner / weekly / vault 转账）| backend_action_runner.gd:575-680 | ~160 | `transfer_money`, `read_vault_balance` |
| 货架 update / buy_from | backend_action_runner.gd:364-415 | ~100 | `shelf_update`, `shelf_consume_listing` |
| 睡眠 start / commit | backend_action_runner.gd:1162-1228 | ~80 | `set_sleeping`, `restore_hp_to_max` (or `modify_hp` 重复用) |
| 上贡 submit_royal_consumption | backend_action_runner.gd:476-574 | ~100 | `royal_record_consumption` |
| 交易 offer / respond（多方撮合）| backend_action_runner.gd:682-815 | ~250 | 同时复用 `container_*` `transfer_money` `shelf_*`；可能再加 `escrow_*` |
| 玩家 eat / give / drop | player.gd 散落 request_* | ~150 | 主要复用现有 |

### 形状 C：multi-tick durative action

动作要持续多个真实秒（走过去 → 挥工具 → 完成），中间可被打断 / 取消。**lua 化前先要设计跨 turn 的 lua state 模型。**

| 候选 | 当前位置 | 行数 | 阻塞设计 |
|---|---|---|---|
| Workstation craft 进度（staging / wear / commit）| workstation_action_runner.gd | ~700 | 跨 N 真实秒的 lua state 怎么持有；hot reload 撞上 in-flight craft |
| Farm 动作队列 | farm_action_runner.gd | ~474 | 队列状态机谁拿；中断 / 续接 / 取消语义 |

## 3. 路线图

```
✅ Step 0  MechanicHost 基础设施
✅ Step 1  Speech → speech.lua
✅ Step 2  Crops → crops.lua
✅ Step 3  Crafting → crafting.lua
✅ Step 3.5  affect.add_status / world_event / /cast 入口
✅ Step 4  Character 生理 → physiology.lua  (affect.hp / remove_status / set_alive；smoke 10/10)
✅ Step 6 prereq §4.1 inventory 套件: take/transfer/set_slot_state + world.find_items (sync)
✅ Step 6 prereq §4.2 MechanicVerb wrapper: on_resolve / on_commit / on_offer 等多 hook + auto world_event
✅ Step 6.1 container deposit/withdraw/inspect → container.lua (smoke 30/30)
✅ Step 6.2 wages claim_wages → wages.lua (复用 transfer_item 转银币)
✅ Step 6.3 shelf update / buy_from → shelf.lua (thin wrapper；listings 写在 GDScript)
✅ Step 6.4 sleep start / commit → sleep.lua (修 sleeping schema duration_sec → expires_total_hours)
✅ Step 6.5 submit_royal_consumption → royal.lua (dry-run + batch take_item)
✅ Step 6.6 trade offer / respond → trade.lua (thin wrapper；撮合在 GDScript)
✅ Step 5 物品腐烂 + Mining + Minting → perishable.lua / mining.lua / minting.lua (system tick 规则)

⏸ Step 7 Durative action (workstation + farm runner)
   per §3.4 deferred-by-design：runner 是引擎层（timer / state machine / RPC / 动画），
   规则已在 crafting.lua / mining.lua / crops.lua。等 god mode 真要支持自定义法术 / 工艺
   动作（lua 持有跨-tick 状态）时再立项。
```

### 3.1 Step 4 — Character 生理 ✅

**作用域**：`character.gd::apply_slow_tick` + `_refresh_hungry_status` + alive 翻转。

**新增 affect**（Q2：lua 声明，GDScript setter 善后）：
- `affect.hp(target, amount)` — 同 `affect.hunger`/`affect.stamina` 命名（不叫 `modify_hp`，保持现有命名风格）
- `affect.remove_status(target, status_id)` — 解除 status（hungry 阈值清除走这条）
- `affect.set_alive(target, alive: bool)` — lua 只声明状态翻转；`Character.alive` setter 调虚 hook `_on_alive_changed()`，子类 NPC/Player 后续按需 override 做物理善后（NavMesh 移除、RPC 停发、动画切死亡）

**新文件 `data/mechanics/physiology.lua`** hook（Q1：只 slow_tick，不做 fast_tick）：
- `on_slow_tick(ctx)` — hunger 衰减 / hungry 阈值进出 / 饿死扣血 / 死亡判断
- `on_hunger_changed(ctx)` — 吃 / 喝 / heal 后调，只刷阈值（共享 `_check_hungry_threshold` helper）
- 数据：`hunger_decay_per_game_hour`, `hungry_threshold`, `clear_threshold`, `starving_hp_loss_per_hour`

**调用方**：
- `apply_slow_tick` → `MechanicHost.invoke("physiology", "on_slow_tick", ctx)` + 收尾（_expire_timed_statuses / _sync_head_status / tick_spoilage / _persist_state）
- `refresh_statuses` → `MechanicHost.invoke("physiology", "on_hunger_changed", ctx)` + sync_head + persist

**stamina 回复**：原 `@export var stamina_regen_per_sec` 是 dead code（只声明无人读），直接删；未来真要做被动回复时再走 lua-config 模式。

**实际净影响**：character.gd 净 -36 行；新增 physiology.lua 61 行 + script_api.gd +29 行 + effects.gd +43 行。

**验证完成**：
- boot smoke：client / runtime 两 mode 都 load 了 physiology mechanic，无 SCRIPT ERROR
- `scripts/physiology_smoke.tscn`：10 scenarios 全 PASS（健康/进/不重复/出/死区/扣血/致死/钳位/吃完/不重复 add）

**遗留**：`add_status` effect 应用末尾会自动 `target.refresh_statuses()`，对非 hungry 的 status 是冗余触发；Step 6.4 sleeping 迁 lua 时一并解耦。

### 3.2 Step 5 — 物品腐烂 / Mining / Minting

复制 Step 4 的模式，三个独立 mechanic 文件，可并行做。

**`data/mechanics/perishable.lua`**：on_slow_tick 检查所有持有 perishable_aspect 的物品（schedule 由 GDScript 提供），shelf_life 走完则替换成 rotten_into。需要 `affect.replace_item(slot_ref, new_item_id)` 或更通用的 `affect.set_item_field(slot_ref, key, value)`。

**`data/mechanics/mining.lua`**：on_interact(miner, mine_node) → 校验 cooldown / 工具 → 给矿石。需要 `affect.set_node_field(node, key, value)`（设 cooldown 时间戳）。

**`data/mechanics/minting.lua`**：同上模式，输入消耗 + 输出币。

### 3.3 Step 6 — Backend action verbs（按从小到大）

每个 sub-step 一份 `data/mechanics/<verb>.lua`。每完成一个验证一次，再开下一个。

**前置（一次性）**：开 Step 6.1 前先把 §4.1 inventory 套件 + §4.2 `MechanicVerb` wrapper 落地。之后所有 sub-step 调 `MechanicVerb.resolve("xxx", ctx)`，backend_action_runner 的 `_run_xxx` 退化成 5 行。

**sub-step 顺序（按风险递增）**：
1. **容器 deposit/withdraw/inspect** — 最小、最纯的"两个 actor 间转移物品"，验证 inventory 套件 + MechanicVerb wrapper 真好用
2. **工资 claim_wages** — 钱币就是 `item_id="silver_coin"` 的普通 item，`transfer_item(vault, actor, ...)` 即可，无新 affect
3. **货架 update/buy_from** — 复用容器 + 钱，第一次跨多个 mechanic 协作
4. **睡眠 start/commit** — `add_status("sleeping", -1)` + 唤醒时 `remove_status` + `modify_hp`；不需要 `set_sleeping` 专用 affect
5. **上贡 submit_royal_consumption** — 单独的 royal_history 表写入（用 `affect.world_event` 触发，GDScript handler 落 SQLite）
6. **交易 offer/respond** — 复用前面所有，最大也最难；escrow 要不要单独建表见 §8

每个 sub-step 估 ~100 行 lua，GDScript 几乎无新增（基础设施在前置一次性给齐）。

### 3.4 Step 7 — Durative action

形状 C **不立即开始**。先有个设计文档定下：

- 跨 turn 的 lua state 谁存？三种方案：
  - (a) GDScript 持有 active_action 字典，每个 tick 把字典 lua-marshal 给 lua 并接收新版本
  - (b) lua module 自己用 globals 存（reload-unsafe）
  - (c) 新 `affect.persist_state(key, value)` + `world.read_state(key)`，状态归 lua-namespace 但物理上存在 SQLite
- 中断 / 取消语义如何在 lua 表达
- 进度 UI 数据怎么 pull（每 0.25s 跑 progress hook 还是 lua 一次给个时长 + GDScript 自插值）

设计完再做。预期**等 god mode 真要支持自定义法术 / 工艺动作时**才必须做。

## 4. 基础设施缺口（按 step 索引）

### 4.1 Inventory affect 套件（Q3 决议）

Step 5/6 大部分逻辑都要改背包。一次性把这 5 个 API 做扎实，后续 step 不再扩。

```lua
-- 凭空给（已有）
affect.give_item(receiver, item_id, qty, qual)

-- 扣掉
affect.take_item(holder, query, qty) -> consumed_qty

-- 跨持有者移动；尽力转、返回真实 qty（不强制原子，lua 自己看返回值）
affect.transfer_item(from, to, query, qty) -> moved_qty

-- 改单槽位字段（quality / durability / content_id 等）
affect.set_slot_field(holder, slot_index, key, value)

-- 查询
world.find_items(holder, query) -> [{slot_index, item_id, qty, quality, content_id}, ...]
```

`query` schema（最小 dict，多字段全 AND 组合）：

```lua
{ item_id = "wheat" }                                  -- 按 id
{ slot_index = 3 }                                     -- 按槽位
{ content_id = "water" }                               -- 容器内容物
{ item_id = "iron_blade", min_quality = 60 }           -- 加品质下限
```

GDScript 端约 ~120 行一次性实现（query 匹配函数 + 4 个 affect handler + 1 个 world helper）。`holder` / `from` / `to` 接受 Character / ContainerNode / ShelfNode（任何有 inventory 的实体），统一通过 `_get_inventory(node)` 拿到 InventorySlotData[] 操作。

### 4.2 MechanicVerb wrapper（Q4 决议）

Step 6 开始前一次性写 `class_name MechanicVerb`（~50 行 GDScript）：

```gdscript
# backend_action_runner._run_xxx 统一长这样：
func _run_buy_from_shelf(req):
    return MechanicVerb.resolve("buy_from_shelf", { actor, shelf, item_id, quantity })
```

Wrapper 责任：调 `MechanicHost.invoke(verb, "on_resolve", ctx)` + normalize 返回 + 自动 world_event 上行（如 lua return 里有 `world_event` 字段）。Lua hook 约定 return `{ ok, message?, world_event? }`。

`world_event.data` 必须按 `backend/src/godot-link/world-events.ts` 的 `WorldEventDataByType[<event_type>]` 写——至少包含 `actorId` 和 `affectedCharacterIds: string[]`，per-event-type 字段走 camelCase 单 key。**不允许写 alias**（`characterId`/`visibleToCharacterIds`/snake_case 变体），backend `event-adapter.ts` 不再做兼容翻译，shape 不对直接 reject。见 [godot-agent-protocol.md §3.2](./godot-agent-protocol.md#32-event)。

Crafting 不合并（两阶段 lifecycle 形状不同），保持独立。

### 4.3 其他 affect / world API 缺口

按 step 排序：

| Step | 新 affect / world API | 复杂度 |
|---|---|---|
| 4 | ✅ `hp`, `remove_status`, `set_alive` | 低 |
| 5 | `set_node_field`（mining/minting cooldown 戳）；item 替换待定（见 §8） | 中 |
| 6.1 | （inventory 套件已够，需 ContainerNode 实现 `_get_inventory`） | 低 |
| 6.2 | （钱币 = 普通 item，走 `transfer_item` + `find_items`，无新 affect） | 低 |
| 6.3 | shelf listings 复用 inventory 套件 + `world.shelf_listings(node)` | 中 |
| 6.4 | `set_sleeping` 用 `add_status("sleeping", -1)` 已够；hp 回复用 `modify_hp` | 低 |
| 6.5 | `world_event("royal_consumption", ...)` + 历史落 SQLite 走现有 GDScript handler | 低 |
| 6.6 | （主要复用 inventory 套件）+ 可能 escrow（见 §8） | 高 |

### 4.4 设计原则（避免 affect 爆炸）

- **优先扩展现有**：能用 `add_status("sleeping", -1)` + setter 副作用表达的，不再加 `set_sleeping`
- **通用 setter 优先**：能用 `set_slot_field(slot, "quality", 50)` 表达的，不加 `modify_quality`
- **复用 query schema**：所有 inventory affect 共享同一个 `query`，新场景应该是"加 query 字段"而不是"加新 affect"
- **inventory / money 高频**：做扎实；royal / escrow 是单一用例，能用 world_event + GDScript 兜底就别 lua 化

## 5. 模式定义

每个 mechanic 文件遵循同一形状：

```lua
-- 文件头注释：mechanic 描述 + ctx schema + return schema

-- 数据（toplevel 常量，可被 query 读）
some_threshold = 30
some_table = { ... }

-- 私有 helper
local function _internal(...) end

-- Hook（被 MechanicHost.invoke 调用）
function on_some_event(ctx)
    -- 1. 读 ctx 字段
    -- 2. 算（纯 lua）
    -- 3. affect.* 声明意图
    -- 4. return 给调用方（nil/string=reject 原因/dict=结构化数据）
end

-- Query（被 MechanicHost.query 调用，纯函数 / 数据）
function get_xxx(arg) ... end
```

ctx 永远由 GDScript 准备：包含必要的 entity 引用（actor / target / world node）+ 引用对象的字段快照（hp / hunger / inventory）。lua 不反查 GDScript 字段（除了 `world.*` 显式 query）。

## 6. Out of scope

本计划**不包括**以下事项。各自单独立项：

1. **Hot reload** — 运行时改 lua 不生效；需要 `MechanicHost.reload(name)` + 失败回滚 + multiplayer reload 同步
2. **Sandbox hardening** — 指令 cap / 内存上限 / wall-clock timeout；LLM 上线前必做（[scripting-layer.md §5](./scripting-layer.md#5-沙箱当前状态)）
3. **LLM-authored mechanic 管道** — `write_mechanic` tool / `data/mechanics/` ↔ `user://mechanics/` 优先级 / 校验 / 持久化
4. **Mechanic 发现** — `MechanicHost.list_mechanics()` 上报 / 自描述 metadata / LLM tool 自动生成
5. **NPC 用 cast_spell action verb** — 让 LLM 主动施法（不是只玩家 /cast）；要扩 backend action runner 的 verb enum + ACL
6. **Backend status / event 翻译表** — `STATUS_PROMPTS` / `EVENT_PROMPTS` 把 lua id 转自然语言塞进 LLM context
7. **World event 路由约定** — 现 say_to 用 heardByCharacterIds，其他 event 没规则；建议加 `__audience` 通用字段
8. **Cross-mechanic 调用** — `mechanic.crops.query(...)` 跨 sandbox
9. **Lua 自定义持久化字段（mechanic_state）**（Q5 决议推迟）— 未来"NPC 仇恨值 / 派系声望 / 法术 concentration"等用例需要，方案是给 character_states 加 `mechanic_state TEXT` JSON 列 + `affect.set_mechanic_field` / `world.get_mechanic_field` API。Step 4–6 全部用现有字段 + `active_statuses` 完成，不需要这条；等真有 per-actor 持久 lua 字段需求时立项

这些大致按 god mode 接入的依赖顺序，本计划完成后开新 plan 做。

## 7. 已决问题（前期讨论结论）

| # | 问题 | 决定 | 理由 |
|---|---|---|---|
| Q1 | 要不要 `fast_tick` (60Hz) hook? | **不做。** slow_tick (game-hour) 是 mechanic 唯一 tick 节奏 | 60Hz × N 角色 ≈ 9% CPU 是已知悬崖；高频逻辑走 "lua 当配置 + GDScript 跑 tick"（如 stamina_regen_per_sec） |
| Q2 | 死亡 / alive 谁决定？ | **lua 声明 `affect.set_alive(target, bool)`**，GDScript setter 做物理善后（NavMesh / RPC / 动画） | "死了" = 规则；"死后不能动" = 引擎事。同 hunger 模式 |
| Q3 | Inventory mutation 的 affect 粒度？ | **4 affect + 1 query**（详见 §4.1）：give_item / take_item / transfer_item / set_slot_field + world.find_items；都吃统一 `query` dict；`transfer_item` 尽力转、返回真实 qty（不强制原子） | 5 类操作正好对应 5 个 API；query schema 让 affect 数量不爆炸 |
| Q4 | 6 个 backend verb 共享 wrapper？ | **抽 `class_name MechanicVerb` 静态类**，自动 world_event 上行。Crafting 不合并（两阶段 lifecycle 不同形状） | 否则 6 × 50 行模板重复 |
| Q5 | lua 自定义持久化字段（"魔法学派偏好"等）？ | **本计划不做，移到 §6**。Step 4–6 全部用现有字段 + `active_statuses` 完成 | 实际盘点 9 个 sub-step 全用现有 schema 够；mechanic_state JSON 列等真有需求再立项 |

## 8. 仍开放

- **Step 5 物品腐烂用 `set_slot_field` 还是新 `replace_item`**：腐烂涉及 item_id 变化（fresh_meat → rotten_meat），不只是字段改。开始 Step 5 时定
- **Step 6.6 交易的 escrow 模型**：双方提交→撮合→落库 是不是要专门一个 escrow 表；交易最后做时再看
- **Step 7 durative action 的 lua state 模型**（§3.4 列了 3 个备选）；要做 Step 7 时单独设计

## 9. 完成标准

本计划 done 时：
- [ ] `backend/.../backend_action_runner.gd` < 300 行（当前 1235；只剩 dispatcher shell + RPC bridge）
- [ ] `character.gd::apply_slow_tick` 调用 `MechanicHost.invoke("physiology", ...)` 后 < 30 行
- [ ] `data/mechanics/` 至少 10 个文件（speech / crops / crafting / physiology / perishable / mining / minting / container / wages / shelf / sleep / royal / trade）
- [ ] 所有 verb 走统一 lua wrapper（无 verb-specific GDScript 翻译）
- [ ] Boot 干净，3 个 mode（client / runtime / 默认）启动无 SCRIPT ERROR
- [ ] perf 总开销 < 5 ms/s（约 0.03% 一帧预算）

不做完整端到端测试自动化（需要多 client + 真键盘）；每个 step 完成时手动验证一遍核心 flow。

## 修订记录

- 2026-05-15：初稿。基于 Step 0–3.5 已 landed 状态规划余下迁移。
- 2026-05-15：Q1–Q5 决议落定（§7 表）。inventory affect 套件细化为 4 affect + 1 query (§4.1)；MechanicVerb wrapper 提案进 §4.2；mechanic_state JSON 列推迟到 §6 #9。Step 4/6 描述更新引用决议。
- 2026-05-15：Step 4 ✅。physiology.lua + `affect.hp` / `remove_status` / `set_alive` 落地；apply_slow_tick / refresh_statuses 改走 lua hook；Character.alive 加 setter + `_on_alive_changed` 虚 hook；`scripts/physiology_smoke.tscn` 10 场景全 PASS。`affect.modify_hp` 改名 `affect.hp` 与现有命名一致。
- 2026-05-15：Step 5 推迟到 Step 6 之后做（mints/mines 是纯系统规则，god mode 价值低；perishable 触 §8 开放问题且 LLM 用不到）。
- 2026-05-15：Step 6 prereq + 6.1 ✅。`InventoryAdapter` (RefCounted base + Character/Container/Shelf 内嵌) + `MechanicVerb` 静态类 + container.lua 落地。inventory 套件改 sync（lua 期间立即应用 + 返回 moved_qty/taken_qty/bool 给 lua），与原 plan §4.1 的 async 假设不同 —— 原因：transfer_item 语义需要 lua 立即知道 moved_qty 才能格式化错误消息。Shelf adapter 仅支持 read（write 留 6.3）。set_slot_field 改名 set_slot_state（与 crop_state/farm_state 风格一致）。`scripts/inventory_adapter_smoke.tscn` 30 场景全 PASS。
- 2026-05-15：Step 5 + 6.2–6.6 全部 ✅。新增 mechanics: wages / sleep / royal / minting / mining / perishable / shelf / trade（共 8 个），加上之前的 5 个 = 13 个 lua mechanic。新增 sync affects: `spawn_item` (任意 holder 凭空生 item)、`shelf_op` (wrap Shelves 业务)、`trade_op` (wrap BackendActionRunner.trade_create/respond)。MechanicVerb.resolve 加 hook 参数支持 on_commit / on_buy / on_respond 等多 hook (sleep / trade / shelf 用)。Sleep schema 修了 duration_sec → expires_total_hours。Containers 死代码（actor-facing deposit/withdraw/inspect）清理 ~90 行。Step 7 deferred per §3.4。
- 2026-05-15：Shelf / Trade 走 thin-wrapper 路径——listings/transactional 写仍在 GDScript，lua 只负责 args 校验 + world_event payload + 错误消息。这是承认两个域本质是 data-heavy 操作，lua 不增加表达力；未来要让 LLM 改 shelf/trade 规则（动态定价 / 税 / 自动接受）再深入。
