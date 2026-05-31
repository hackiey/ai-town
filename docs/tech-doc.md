# 技术文档

> 本文档覆盖**技术架构、实现栈、安全沙箱、工具链与验证记录**。游戏设计、玩法机制见 [design-doc.md](./design-doc.md)。

---

## 1. 技术架构（四层栈）

### Layer 1：引擎层（开发团队代码）
- Godot 4.6 项目本体
- LuaJIT 嵌入 + 沙箱（白名单 API、指令计数 hook、内存上限、确定性 RNG）
- LLM 网关（服务端调 Claude API，客户端不接触 key）
- NPC AI 核心（memory / reflection / planning，参考 Generative Agents 论文）
- 服务端权威 + 存档 + 反作弊
- 玩家账号 / 计费 / 镇分配

### Layer 2：规则层（设计师配数据，不变）
- 基础属性公式（HP, Mana, 回复率, 速度）
- 资源类型与刷新规则
- 死亡/战斗/经济基线
- **基础 API（最关键，下一阶段重点）**
  ```
  world.*           查询世界状态
  self.*            操作自身
  inventory.*       物品操作
  events.on/emit    事件钩子
  fire.*  heal.*  metal.*  earth.*  life.*    基础学派
  nature.*  mind.*  time.*  summon.*           稀有学派
  ```
- 每个原语自带 mana cost 公式

### Layer 3：种子层（开发者手工预制 + 资源随机初始化）
- 地形、建筑、NPC 名册与人格、起始法术书、镇主题：开发者在编辑器内手工制作
- 资源节点：按预制的"区域 + 类型 + 密度"约束在新开服时随机初始化
- LLM 不参与建镇

### Layer 4：内容层（玩家与 NPC 涌现产生）
- 创造物、法术书流通、社会关系、市场价格

---

## 2. 安全与沙箱要求

**为什么不用 GDScript 让 LLM 直接写**：GDScript 与引擎同进程、有完整权限，无法沙箱化。

**选定方案：LuaJIT** （或 QuickJS，待定）
- 白名单 API：只暴露 §1 Layer 2 的接口，砍掉 `os` / `io` / `require` / `load` / `loadstring`
- 指令计数 hook：每 N 条指令检查超时，杀死跑飞的脚本
- 内存上限：自定义 allocator
- 确定性 RNG：游戏提供 seeded random，禁系统随机源
- 服务端执行：所有 LLM 生成、代码校验、运行时仲裁都在服务端，客户端只做表现

---

## 3. 工具链

### 3.1 动画重定向（`src/tools/animation_retarget/`）

**目的**：把异源 rig 的动画（Mixamo）烘焙到本项目使用的 rig（Synty）上。**编辑时一次性 bake → AnimationLibrary `.res`**，运行时 preload，无开销。

**结构**：
| 文件 | 作用 |
|---|---|
| `animation_retargeter.gd` | 静态类，核心算法（公式见 §4） |
| `bone_mapping.gd` | `BoneMapping` Resource：源骨名 → 目标骨名映射 + 选项 |
| `bake_tool.gd` | `@tool` 节点：批量烘焙入口（Inspector 里点 Bake 按钮）|
| `presets/mixamo_to_synty.tres` | 预设映射 |
| `README.md` | 详细用法 |

**加新动画**：拖 FBX 进 `bake_tool` 的 `source_fbxs`，点 Bake → 生成 AnimationLibrary。
**加新 rig 组合**：新建 BoneMapping 资源即可，算法零改动。

### 3.2 Vendor 资产管理

`third-party/` 目录全部 gitignore，每个 vendor 包手工下载到本地，由 `third-party/README.md`（待写）记录每个包的来源、版本、解压路径。

**为什么不进 git**：
- 法务：Synty 等付费资产 license 不允许公开再分发
- 体积：单个包 200M+，clone 体验差
- LFS 不解决以上两点，且引入额外配额成本

---

## 4. 技术验证记录（2026-04-30）

第一轮端到端验证已通过，结论：**Synty + Godot 4.6 + Mixamo 动画的技术栈跑通**。

### 4.1 已通过验证

| 项 | 状态 | 备注 |
|---|---|---|
| Synty PolygonFantasyKingdom 在 Godot 4.6 渲染 | ✅ | 角色/建筑/物品/材质/阴影全部正常 |
| Particle FX 包导入 | ✅ | 13 个环境特效（火/烟/雾/雨/雪等）可用 |
| Mixamo FBX 导入 Godot | ✅ | 自动用 ufbx，无需 FBX2glTF |
| Mixamo 动画重定向到 Synty 角色 | ✅ | 通过自定义脚本，已抽象为 §3.1 工具 |

### 4.2 已验证的重定向算法

```
Q_t = (Wt_parent⁻¹ · Ws_parent) · Q_s · (Ws_self⁻¹ · Wt_self)

W = world rest rotation（从骨骼根累积到该 bone）
Q_s = 源动画该 bone 该帧的 local rotation
Q_t = 目标该帧应填的 local rotation
```

简单公式 `Q_s · R_s⁻¹ · R_t` 不够，必须考虑父链的世界 rest 朝向差异。实现见 `src/tools/animation_retarget/animation_retargeter.gd`。

### 4.3 历史验证场景（位于已 gitignore 的 vendor 子项目，仅本机存在）
```
third-party/polygon-fantasy-kingdom/test_animation.tscn  # Mage + 动画测试场景
third-party/polygon-fantasy-kingdom/test_scene.tscn      # 角色/建筑/物品视觉验证场景
```

### 4.4 已知问题与权衡

1. **手臂偏长（视觉）**：Mixamo 写实成人比例 vs Synty 半 Q 版身材的 rig 比例差异，Mixamo 任何动画套到 Synty 都会有这个问题。MVP 接受现状；后期可用 IK 修正
2. **Synty 不带动画**：必须依赖 Mixamo 或自做。Mixamo 免费动画库覆盖了基础动作，应该够 MVP
3. **手指/眼睛/嘴等次级 bone 不在 BoneMap**：当前重定向只覆盖躯干 + 四肢主骨，手指保持 T-pose。后期需要时可补充

### 4.5 资产覆盖度结论

- ✅ 23 种 NPC 角色，覆盖小镇典型职业（含法师、修女、隐士、铁匠、商人等）
- ✅ 241 个物品 → 直接做"图标词汇表"基础库
- ✅ 491 个道具装饰 + 187 环境元素 → 镇布置充足
- ⚠️ 战斗/魔法 VFX 缺失（Particle FX 只有环境氛围）：后期需购买 Hovl/JMO 等
- ⚠️ 怪物/野兽缺失：后期需补 Synty Monsters 或类似包

---

## 5. 已决策事项快速索引（技术）

| 决策 | 结论 |
|---|---|
| 引擎 | Godot 4.6 |
| 主项目渲染 | Forward+（与 FK 资产匹配）|
| 物理 | Jolt Physics |
| 内容生成方式 | LLM 生成沙箱化代码，服务端执行 |
| 沙箱语言 | LuaJIT（vs QuickJS 最终待确认）|
| LLM 服务 | 服务端调用 Claude API（客户端不接触 key）|
| 网络模型 | 服务端权威 + 反作弊 |
| 后端服务 | Node.js + TypeScript + Fastify；HTTP / debug API + Godot agent-host WebSocket client |
| 数据层 | SQLite 作为当前主库；Redis 用于 action / event / snapshot / status pubsub 与 gateway-worker 协调 |
| 角色 / 环境资产 | Synty Polygon Fantasy Kingdom |
| 动画来源 | Mixamo + `src/tools/animation_retarget` 编辑时烘焙 |
| VFX | MVP：Godot 内置 GPU 粒子；后期：Hovl/JMO 等付费包 |
| 资产管理 | vendor 不进 git，手工下载；动画 bake 产物进 git |
| FK 整合方式 | FK 资产直接位于主项目 `third-party/polygon-fantasy-kingdom/Assets/PolygonFantasyKingdom/`；不再独立子项目 |
| 地图坐标系 | 1m × 1m 网格 + 矩形定义的命名区域，运行时 baked 到 `PackedInt32Array` 查表（见 `src/world/`）|

游戏设计相关决策（资源经济、知识系统、战斗、NPC 行为等）见 [design-doc.md §10](./design-doc.md)。

---

## 6. 待决策事项（技术）

### 高优先级
1. **基础 API 表面设计**：哪些学派、每个学派的原语清单、mana 成本公式（与 design-doc §11 待决策 1 同条，需双向对齐）
2. **LuaJIT vs QuickJS 最终确认**：选型评估
3. **LLM 调用预算**：玩家每天能创造多少次？是否计费？影响成本结构
4. **服务器托管栈细化**：Godot runtime 部署、Node 服务部署、SQLite/Redis 备份与观测方案

### 中优先级
5. **Mixamo IK 修正方案**：手臂偏长问题
6. **Vendor 资产团队分发方案**：共享 cache / 私有 mirror / setup 脚本

### 低优先级
7. **LLM 生成失败的降级策略**：玩家描述太离谱、生成不合规怎么办
8. **内容审核流程**：玩家描述触发不当内容时的检测与处理

---

## 7. 当前运行链路 / 技术债

本节记录当前“Agent worker → backend gateway → Godot runtime → action ack → Agent tool result”的主链路和仍需补强的技术债。

### 7.1 Godot runtime 连接配置

- 进程拆成两份（2026-05-06）：headless godot server 是权威 runtime，玩家 client 不再连 backend。架构详见 [architecture/runtime-layers.md §3.1](./architecture/runtime-layers.md#31-三进程拆分已落地2026-05-06)。
- 同一份 `project.godot` 用 `--mode runtime|client` cmdline 切角色，由 `RunMode` autoload + `src/boot/boot.gd` 统一进入 `src/levels/town.tscn`，再由 `town.gd` 按模式分支。
- `BackendRuntimeClient` autoload `_ready` 顶上 `if not RunMode.is_runtime(): return`。runtime 进程在 `127.0.0.1:3100` 监听 agent-host WebSocket；backend 主动连接。client 进程完全不发 HTTP / WS 给 backend。
- 默认 token 为 `dev-headless-only-token`，instance_id 默认 `headless_godot`。开发机 `backend/.env` 需同步更新。
- runtime token 通过 `agent.host.hello` payload 传递，只适合本地开发；生产需要改成更正式的鉴权方式，例如短期签名 token、TLS、服务端注册 runtime 实例。
- `lastAckSeq` / replay cursor 当前仍偏 MVP：Godot 侧 replay buffer 在进程内存，backend 断线时把连接摘要写入 `runtime_sessions`。Godot 重启后不能恢复未 ack 的 replay buffer，backend→Godot 的 durable action replay 也未实现。
- 玩家 ↔ godot server 走 ENet (`scripts/dev` 默认 `:7777`) + `MultiplayerSpawner` / `MultiplayerSynchronizer`：NPC 同步 `position` / `rotation` / `anim_state`；玩家 avatar 也是 server-authoritative，client 通过 `@rpc("any_peer")` 把直接移动或自然语言命令发给 server，server 跑 nav 后通过 synchronizer 推回 transform。无 client prediction。
- 玩家自然语言指令走 `player.command` WebSocket 消息。Gateway 只记录为 `player_command` world event 并发布给 worker；worker 找到对应 player agent session，主动查询 Godot live snapshot 后解析命令并调用已有 action tools。

### 7.2 Character 指令执行

- 当前 runtime 支持 `move_to_location`。worker 会把当前 `visibleLocations` 中的具体地点名或 alias 写进 `location` 参数 enum，例如 `blacksmith_shop`、`铁匠铺`、`current_location`，不接收坐标；隐藏子地点需要先前往父地点后才会出现在参数 enum 里。
- 当前 runtime 支持 `say_to`、`sleep`、`use_item`、`pick_up_item`、`drop_item`、`offer_trade`、`respond_to_trade`、`create_item`、货架、容器、王室消耗、领工资、工作台和农事 action。`say_to` 会由 Godot 计算 `affectedCharacterIds` 并广播头顶气泡。真实库存、交易、创造物落地属于 Godot server 权威逻辑，worker 只消费 server 回写的 snapshot/event。
- backend 通过 `action.submit` 下发 action；Godot 收到后先回 `action.ack` / `accepted`，执行结束后再回 `completed`、`failed` 或 `cancelled`。backend 用 SQLite `action_log` 区分“已提交、已投递、已接受、已终止”。
- action 提交路径是：Agent tool -> `submitAction()` -> SQLite `action_log` -> Redis `action bus` -> gateway `action.submit` -> Godot `BackendActionRunner`。工具调用会轮询 `action_log` 等待 terminal ack，再把结果回填给 LLM。
- Godot `BackendActionRunner.finish()` 会在 action 前后做角色状态 diff，并把实际变化写入 `result.character_changes`。当前覆盖属性变化（`hp`、`stamina`、`hunger`、`rest`、`temperature`、`burning`）和背包变化（数量、工具耐久、容器内容）。属性只传稳定 slug，显示名由 agent 的 attribute name resolver 渲染。没有变化就不返回对应字段。
- Agent runtime 负责把 `action.ack.result` 渲染成 LLM 可读 context。工具结果只描述发生的事实，例如“挖了几次、收获什么、背包/耐久怎么变”；不输出通用“状态：成功”或“后续建议”，也不暴露 `runtime` / `ack` / `result 字段` 等实现词。
- 当前单角色同时执行的最终约束在 Godot 的 `BackendActionRunner`；新 action 到来会按 runner 规则 preempt 正在执行的 action，backend 也能通过 `requestCancelAction()` 发 `action.cancel`。
- 取消和运行时主动打断已接入基础链路：agent runtime 在工具执行期间收到 interrupt 可请求 cancel，Godot 处理后回 `cancelled` / terminal ack。还没完成的是 action durable replay、复杂优先级策略和重启时非终态 action 的恢复语义。

### 7.3 Region / 地点解析

- `region_candidate_points_world()` 当前根据矩形 region 采样候选点，不代表真实语义地点。
- `TownWorld` 现在把 `Positions` 的 Marker3D 场景树编成正式地点层：顶层 Marker3D 是大地点，子 Marker3D 是抵达父地点附近后才暴露的局部地点。`move_to_location` 先解析这个地点层，找不到再 fallback 到 region。

### 7.4 数据与事件

- SQLite / Redis 已作为后端基础设施接入：SQLite 保存 `action_log`、`world_events`、`runtime_storage`、`agent_sessions`、`agent_session_messages` 等；Redis 负责 Worker→Gateway pub/sub（world event、snapshot request/response、game time、action、character status）。
- `world.event` 已接入说话、物品、交易、货架、工作台、农事、容器、王室消耗、领工资等链路。战斗等事件类型仍是未来工作。
- worker 在 event/think 前发送 `character.snapshot.request`；runtime 返回 `character.snapshot`，包含 `currentLocationId`、`characterAttributes`、`nearbyBuildings.near/far`、`nearbyCharacters.near/far`、`nearbyItems.near/far`、`nearbyFarms`、`nearbyWorkstations`、`nearbyShelves`、`nearbyContainers`、`inventory`、`backpack`、`pendingTrades`。backend 不持久化快照，worker 只把本次 live snapshot 用于当前 prompt / event classification；空区块不出现在 prompt 中。
- worker 不推导交易状态，只信 Godot server 写入 context 的 `pendingTrades`。`respond_to_trade` tool 只在 context 存在 pending trade 时注入，平时交易相关 tool 只有 `offer_trade`。
- Character memory、session message 持久化和 planning 已接入 two-track-agent。reflection / compaction 的触发规则仍需要继续收敛。

### 7.5 测试方式

- 已用当前 Godot agent protocol 跑通过 backend ↔ Godot action submit / ack、player.command、world.event、character.snapshot、thinking status 等主链路。
- 真实集成测试仍应沉淀成脚本化测试：启动 Redis、gateway、worker、headless Godot server，再用 `action.request` / debug agent 覆盖 action 生命周期、cancel、重连 replay 和 snapshot 更新。

---

## 修订记录

- v0.1 (2026-05-05)：从 design-doc.md 拆出；包含技术架构（四层栈）、沙箱、技术验证记录、工具链、技术决策与待决项
- v0.2 (2026-05-05)：FK 子项目并入主项目（删 inner project.godot），主项目渲染切到 Forward+；解决 §6 待决策 #5、#6；新增地图坐标系决策
- v0.3 (2026-05-05)：新增 Node+TS 后端、SQLite/Redis、Godot runtime WebSocket，以及当前临时实现/技术债记录
- v0.7 (2026-05-06)：godot 进程拆成 headless server + 玩家 client；§7.1 更新连接配置（boot mode、token、ENet 同步），架构详细说明落到 architecture/runtime-layers.md §3.1
- v0.8 (2026-05-06)：server / client 共用唯一一份 `town.tscn`（不再拆 town_runtime / client_main），由 `town.gd` 按 RunMode 分支初始化——保证两端 NodePath 自动一致，client 也直接拿到完整世界几何用于渲染
- v0.9 (2026-05-14)：回写当前 backend/Agent 架构：Godot server 监听 agent-host WS、backend 主动连接；`action_log` + action bus、agent session、world event/snapshot bus 和 action tool 等主链路已落地
