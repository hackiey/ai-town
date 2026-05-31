# Runtime layers

> Status: **partial** — 三进程拆分（backend / godot server / godot client）已落地（[§3.1](#31-三进程拆分已落地2026-05-06)）。Worker 端 two-track-agent runtime 已落地；物理 tick / 战斗 cadence 仍未实现。

四层进程架构 + 战斗 cadence + 离线小镇模拟。

## 1. Context

之前 worker 角色一直含糊（既像 job queue 处理器，又像 LLM 网关，又像状态机协调器），导致脚本归属、effect 应用、状态权威源都不清晰。

这一层把"谁干什么"切干净，让其他层（AgentSession、scripting、entity-model）能各自展开而不互相侵入。

## 2. Design

### 2.1 脑/身分层

| 层 | 角色 | 内容 |
|---|---|---|
| **Worker（脑）** | 决策、记忆、规划、生成 | LLM 调用、AgentSession（[two-track-agent-session.md](./two-track-agent-session.md)）、character memory、action tool 编排。Worker 进程内部进一步分层为 godot-link / agent-host / agent-shared / runtimes 四层，详见 [backend-agent-host.md](./backend-agent-host.md)；当前唯一 LLM runtime 是 `two-track-agent`（双轨：action + thinking 并发，同时服务 NPC 和 player command）。Runtime 之间共享的非策略代码（entity 名字解析、事件描述、通用 game tool、perception 装配等）集中在 `agent-shared/` 模块，见 [agent-shared.md](./agent-shared.md) |
| **Godot 服务端 runtime（身）** | 模拟、执行、Game-world sqlite owner | 物理（温度、燃烧、碰撞）、空间索引、动画、effect 应用、Lua 执行（[scripting-layer.md](./scripting-layer.md)）、世界 tick；所有 game-world 表（character_states / farm_plots / workstation_states 等）持续 UPSERT |
| **SQLite（档案/真值）** | 持久化 + 共享真值层 | 既是 Godot owner 的 game-world 真值表（backend 只读），又是 backend 自有表（runtime_storage / action_log / agent_sessions / agent_session_messages） |
| **Redis（神经）** | 协调 | action / world event / perception manifest / game time / character status pub/sub、gateway↔worker 协调 |

**关键边界**：
- Worker **完全不拥有**任何数字游戏状态（hp、temperature、position、inventory 数字）；每次决策前用最新 perception manifest 的 id 列表当场 SELECT 共享 sqlite
- Worker 主要通过 manifest + sqlite SELECT + event / context 文本做决策，不能预测 action 结果
- Godot 是"游戏世界里发生的事"的唯一权威源；同时是 sqlite game-world schema 的 owner，状态变更必须**同步** UPSERT 进表后再 emit world event（详见 [godot-agent-protocol.md §3.1](./godot-agent-protocol.md#31-perception-manifest)）

### 2.2 战斗 cadence：tick-based pseudo-real-time

**2-4Hz tick**（500ms 或 250ms 一格）：

- 所有 effects 在 tick 边界结算，同 tick 内按 priority + action_id hash 定序
- 玩家施法 = 一个 action，cast time 跨 N tick；途中被打断 cancel action，**effects 不结算**
- NPC 战斗时**不调 LLM**——切到便宜的 "combat behavior" 脚本（也是 lua，预制或 LLM 离线为 NPC 生成）；战斗结束 LLM 接回来反思

避免回合制开战时全镇暂停（破坏开放世界感），也避免 LLM 决策延迟卡住战斗。

### 2.3 离线小镇模拟

**问题**：按脑/身分层，谁在没玩家时跑物理？

**决定**：每镇跑一个**永远在线的 headless Godot 进程**作为权威 runtime。
- 玩家的 Godot 是 thin client，连接 headless runtime
- NPC 在你不在时也活着——这是 [design-doc §3-§5](../design-doc.md) 的核心 selling point
- 成本可接受（每月几十块/镇）

排除方案：
- ❌ "没玩家时停 Godot，worker 跑简化物理"——双实现复杂
- ❌ "完全不模拟离线时间，上线时 LLM 回顾"——杀死 emergent 涌现

## 3. Implementation

### 3.1 三进程拆分（已落地 2026-05-06）

```
worker (Node) ↘
                backend (Node) ←── JSON / WebSocket ──→ godot server (headless, 权威)
   curl /admin ↗                                                ↑
                                                     ENet + @rpc │
                                                   + Synchronizer│
                                                                 ↓
                                                     godot client (观察 + 输入)
```

两个不变量：

1. **Godot server 是唯一权威**——像普通 Godot 游戏一样 `_ready` 加载 town、初始化 NPC / character / navmesh / 物理。区别只是 headless、accept ENet。
2. **Client 只跟 godot server 说话**（ENet + @rpc + MultiplayerSynchronizer）。不知道 backend 存在，不写任何 HTTP / JSON。

#### 进程对照

| 进程 | 入口 | 职责 |
|---|---|---|
| backend gateway | `pnpm dev` | HTTP API、SQLite / Redis、Godot agent-host WS client、action 投递、event/snapshot/ack 入库 |
| agent worker | `pnpm worker:dev` | Redis 订阅、AgentHost、two-track-agent runtime、LLM tool 调用 |
| godot server | `./scripts/dev server` | town 场景、NPC 物理 / nav / 动画状态机、玩家 avatar 物理、监听 agent-host WebSocket |
| godot client | `./scripts/dev client` | 渲染 NPC + 其他玩家、相机跟随本地 avatar、点击 → @rpc |

backend ↔ server 这条边走 Godot agent JSON/WS 协议。当前连接方向是：Godot server 的 `BackendRuntimeClient` 在 `127.0.0.1:3100` 监听，backend 的 `godot-agent-client` 主动连入并发送 `agent.host.hello`。协议类型在 `backend/src/godot-link/*`，Godot 侧实现集中在 `src/autoload/backend_runtime_client.gd`。

#### Boot mode 路由

同一份 `project.godot`、同一份代码，按 cmdline 切角色：

- `RunMode` autoload（`src/autoload/run_mode.gd`）排在 autoload 列表最前。`_enter_tree` 解析 `OS.get_cmdline_user_args()`：`--mode runtime|client`、`--town`、`--port`、`--connect host:port`、`--backend-ws`，全部带默认值。
- main scene = `src/boot/boot.tscn`。`boot.gd._ready()` 按 `RunMode` 分支：runtime 直接切 `src/levels/town.tscn`；client 先切 `src/ui/main_menu/login.tscn`，登录完成后由 login.gd 切到 town。
- `BackendRuntimeClient` autoload `_ready` 顶上 `if not RunMode.is_runtime(): return` —— 玩家 client 不会监听或连接 backend。
- `NPC._physics_process` / `NPC.register_npc` 同样以 `RunMode.is_runtime()` 守门，client 端 NPC 只是 puppet。

#### 共用 scene（`town.tscn`）

server 和 client **加载完全同一份 `town.tscn`**——静态几何（Buildings / NavmeshTiler / Demo terrain）、NPCs、Players 容器、PlayerSpawner、CameraRig 都在里面。`town.gd` 根脚本 `_ready` 按 `RunMode.is_runtime()` 分支：

- runtime 分支：`queue_free` 掉 CameraRig（无渲染），起 ENet server，绑 `peer_connected` / `peer_disconnected`，配置 `PlayerSpawner.spawn_function`。
- client 分支：起 ENet client，监听 `Players.child_entered_tree`，本地 avatar spawn 后调 `CameraRig.set_target`。

共用而非两份场景的理由：MultiplayerSynchronizer 要求节点路径在两端**完全一致**——共用 scene 直接保证路径相同，不用维护两份 NodePath。静态几何不参与同步（baked content，两端各自从磁盘加载就完事），把它放进 server 端在 headless 下也只是不渲染，没有运行时成本。

#### Server / client 同步形状

- 用 `ENetMultiplayerPeer`，server 端 `create_server(port)`，client 端 `create_client(host, port)`。server 永远是 peer 1。
- 玩家 avatar 用 `MultiplayerSpawner`（`src/levels/town.gd:_spawn_player_from_data`）。**`owner_peer_id` / `character_id` 等"必须立刻知道"的字段走 spawn data，不走 SceneReplicationConfig**——后者要再等一轮同步，会出现 client 拿到默认值的窗口。
- NPC 在 `town.tscn` 里就 instance 好（NPC_1/2/3），server 和 client 各自从磁盘加载，路径完全一致。`MultiplayerSynchronizer` 同步 `position` / `rotation` (always) 和 `anim_state` (on_change)，client 端 setter 切 AnimationPlayer。NPC 物理 / nav 在脚本里以 `RunMode.is_runtime()` 守门，client 端 NPC 是 puppet。
- 玩家移动：client 点击地面 → `camera_rig.gd` 拿到本地 avatar → `player.request_move_to.rpc_id(1, world_pos)`。server 端 `@rpc("any_peer", "call_remote", "reliable")` 校验 `multiplayer.get_remote_sender_id() == owner_peer_id`，再走 nav。**没有 client prediction，server 跑物理后通过 synchronizer 推回**。

#### 玩家身份：peer_id ≠ character_id

两套 id 分开存，互不替代：

| 概念 | 字段 | 谁分配 | 生命周期 | 用途 |
|---|---|---|---|---|
| 传输层身份 | `Player.owner_peer_id: int` | ENet（连接时随机 int） | 单次连接 | `rpc_id()` 目标、owner-private 同步 visibility、RPC sender 鉴权 |
| 持久化身份 | `Player.character_id: String` | `player_accounts` 表（首次 login 生成 `player_<8hex>`） | 永久 | DB 行 key、backend agent id、节点名、世界事件 actor |

**所有 backend / DB / log 路径用 `character_id`；`owner_peer_id` 仅出现在 Godot 多人 API 内部**。任何 `"player_%d" % owner_peer_id` 拼接都是 bug。

Login & spawn 时序（client 端）：

1. `login.tscn` 输入名字 → 写入 `Players.pending_login_name`（`src/autoload/players.gd`），切到 `town.tscn`
2. `town.gd._init_client` 装 `auth_callback`、`create_client`
3. Godot `peer_authenticating` 信号触发 → `_peer.send_auth(1, name_bytes)` + `_peer.complete_auth(1)`
4. Server `_on_server_auth`：`Db.lookup_or_create_player_account(name)` 拿/建 `character_id`，查 `Players.is_character_online` 拒重复，accept 时 `Players.register(peer, cid)` + `complete_auth`，reject 时 `send_auth(error)` + `disconnect_peer(force=false)`（graceful 保证错误文案先 flush）
5. Server `_on_peer_connected` 用 `Players.character_id_of_peer(peer)` 拼 spawn data，节点 name = `character_id`
6. Client 收到 spawn 后 `Players.local_character_id` = 自己 avatar 的 `character_id`；本机判定改用 `Players.local_character_id == node.character_id`（取代旧的 `owner_peer_id == multiplayer.get_unique_id()`）

被踢回登录的路径（`connection_failed` / `server_disconnected`）走 `town.gd._return_to_login`，把 `Players.last_login_error` 透给下一次 login UI 显示。

#### 关键文件

```
src/autoload/run_mode.gd                # cmdline → 模式
src/autoload/backend_runtime_client.gd  # mode-gated，只 runtime 监听 agent-host WS
src/autoload/players.gd                 # peer↔character_id 注册中心 + local_character_id
src/boot/{boot.tscn,boot.gd}            # 主入口，按 RunMode 分支到 login / town
src/ui/main_menu/login.{tscn,gd}        # client 登录界面，user://login.cfg 记住名字
src/levels/town.{tscn,gd}               # 唯一主场景，server/client 共用，按 RunMode 分支
src/characters/player/{player.tscn,gd}  # server-authoritative 3D avatar + @rpc
src/characters/npcs/npc.{tscn,gd}       # 加 MultiplayerSynchronizer + anim_state
src/world/camera_rig.gd                 # 点击改成 RPC，target 等 avatar spawn 后绑
scripts/dev                             # server / client 子命令
```

### 3.2 仍未实现 / 未完成

- 多 worker 下的 AgentSession 黏附 / failover（当前 worker 进程内存持有 session，靠 SQLite 恢复历史）
- 物理 tick（[entity-model.md §2.1](./entity-model.md) 的属性都是静态字段，没人在 tick 里更新温度等）
- 战斗 tick / combat behavior 脚本路径
- 多镇路由 / 多 godot server 编排
- 兴趣域（AOI）过滤、client prediction、lag compensation
- Godot agent WS replay / ack 在 server 重启场景的端到端验证

## 4. Open questions

- Headless Godot 部署 / 编排（每镇 1 进程，supervise / 重启策略 / 镜像分发）
- Worker→character 黏附 mapping 用 Redis 什么 key 形状
- Tick 频率最终值（2Hz vs 4Hz vs 动态）
- Combat behavior 脚本怎么生成（手写 vs LLM 离线生成 vs 预制库）
- 玩家 avatar 输入授权模型——MVP 是 server-authoritative + 无 prediction，后期是否需要 prediction + reconciliation 视手感而定
