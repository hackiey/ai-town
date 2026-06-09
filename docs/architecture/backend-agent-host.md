# Backend as agent host

> Status: **partial** — godot-link / agent-host / runtimes 目录分层、AgentRuntime 抽象、two-track-agent runtime、perception-manifest + world-state repo、agent-shared 共享模块链路已落地。仍未完成的是多 worker 黏附/failover、以及把 two-track-agent 完全改成只依赖 host 暴露的 GameTool 接口。
>
> Two-track-agent 是当前唯一 LLM runtime（agent-runtime 插件默认 `"two-track-agent"`）；本文档只描述 **host 通用层**——runtime 内部模型见 [two-track-agent-session.md](./two-track-agent-session.md)，runtime 之间共享的非策略代码见 [agent-shared.md](./agent-shared.md)。

Backend 在新架构下的角色：作为 **agent host**——Godot 协议适配器 + agent runtime 容器。

## 1. Context

Godot 协议（[godot-agent-protocol.md](./godot-agent-protocol.md)）锁死 Godot 单方面承诺什么。Backend 在协议另一侧，要能：

- 接收 Godot push 上来的 perception manifest / event，并能直接 SELECT 共享 sqlite 真值表
- 把 runtime 决策出的 action 翻译回协议格式提交给 Godot
- 让不同 NPC 用不同 runtime 实现（LLM、行为树、脚本……）

当前代码已经把 Godot 协议、agent host 抽象和具体 runtime 拆开，two-track-agent 通过 `agent-shared/prompt-context/assemble-from-manifest.ts` 拼 context（输入：当 turn manifest + `services/world-state/*-repo.ts` SELECT 结果），再用 `runtimes/two-track-agent/prompt/` 的 messages / renderer 编排成 prompt。旧的 `agents/context/*` snapshot bundle 链路已删除。

## 2. 整体职责

| 职责 | 做什么 | 不做什么 |
|---|---|---|
| 协议翻译 | Godot WS ↔ runtime API（perception manifest / event 入，action 出） | 不重定义 action/event 词表（Godot 说了算）|
| 路由 | event / manifest → 哪个 runtime；action → Godot | 不决定"该不该执行"（Godot 校验）|
| 缓存 | per-character 最新 perception manifest（id 清单）+ 近期 event ring buffer | 不持久化游戏状态、不 CREATE game-world 表（Godot owner，backend 只 SELECT）|
| World-state 查询 | `services/world-state/*-repo.ts` 按 manifest 给的 id 批量 SELECT sqlite 真值 | 不缓存查询结果（每 turn 当场 SELECT，无 cache 失效问题）|
| Runtime 容器 | 装载若干 runtime 实现，给它们提供受限 API | 不写死 runtime 具体长相 |

## 3. 目录分层

```
backend/src/
  godot-link/         协议规范的 TS 实现，与具体 agent 解耦
    protocol.ts       envelope + message types
    perception-manifest.ts  PerceptionManifestPayload 类型 + normalize
    actions.ts        action wire 契约真值：词表 + per-action ActionTargetByName / ActionResultByName
    world-events.ts   world event data 契约真值：per-type WorldEventDataByType（camelCase 单 key，无 alias）
    events.ts         WorldEvent discriminated union（从 WorldEventDataByType 派生 + ambient 类型注册表）
    event-adapter.ts  Godot 入站 world event 校验 + 透传（无 alias 翻译；契约违反则 reject）
    session.ts        sequencer / replay cursor helper
    agent-connection-registry.ts  gateway 侧 Godot socket registry

  agent-host/         agent 抽象层
    host.ts           AgentHost：event 路由 + manifest cache + currentContext factory hook
    runtime.ts        AgentRuntime 接口
    router.ts         characterId → runtime 选择（按 npcs.json agent_runtime） + npcConfigFor lookup
    state-cache.ts    in-mem manifestByCharacter + event ring buffer
    catalog.ts        id ↔ 显示名（i18n）
    storage.ts        runtime-scoped KV store（持久化通道）
    game-tools/       每个 Godot action 包成 GameTool（schema + handler）

  agent-shared/       runtime 之间共享的非策略代码，见 [agent-shared.md](./agent-shared.md)
    utils/ name-resolver/ entity-descriptions/ event-descriptions/
    event-semantics/ action-semantics/ notices/ game-tools/ prompt-context/

  agents/
    model-registry.ts resolveTwoTrackAgentModels (two-track 用 npcs.json agent_models)
    types.ts          AgentKind / AgentSessionRecord / AgentToolSnapshot 等共享类型

  services/world-state/   按 manifest id 列表 SELECT sqlite 真值（每 repo 一类 entity）
    character-repo.ts     character_states (hp/stamina/hunger/rest/pos/equipped/statuses)
    inventory-repo.ts     item_instances (按 ownerKind/ownerId 过滤)
    farm-repo.ts          farm_states + farm_plots（locationId / totalSlots / 每格 variety / pest / moisture）
    workstation-repo.ts   workstation_states（运行时 busy/operator + boot seed 的静态字段）
    container-repo.ts     container_states + item_instances 拼内容
    shelf-repo.ts         shelf_listings + 拼货架
    location-repo.ts      location_markers（boot seed）
    trade-repo.ts         trade_offers
    name-resolver.ts      DisplayNameResolver：sqlite 真值表 → i18n catalog → raw id
    types.ts              所有 view 类型集中
    crops-catalog.ts      crop variety 的非派生展示常量（displayName + moisture 区间）+ stage 显示名 i18n fallback 链；stage 公式 / stages 数组 / maturation 全部下沉 Lua，由 Godot 算 stage 直接写 farm_plots.stage，backend 不镜像（[[feedback_godot_is_authority]]）

  services/perception-manifest-bus.ts   Godot → 进程内 bus → agent runtime 路由 manifest
  services/world-event-bus.ts           world event 同样的进程内 pubsub
  services/action-bus.ts / action-log-service.ts / etc.

  runtimes/           具体 agent 实现，可插拔
    two-track-agent/  当前唯一 LLM 实现（action + thinking 双 session）
      action-session/       action 轨：快速反应、关 thinking、消费 working_memory
      thinking-track.ts     thinking 轨：周期性深思 + significant event 触发
      semantics/events.ts   per-agent 事件反应表（shouldTriggerActionTurn 等）
      prompt/               system / user prompt 编排（多复用 agent-shared）
      runtime.ts            AgentRuntime 实现，attach/detach + onGameTime tick
    null/             空实现，testing / 角色"放空"用
    index.ts          轻量 registry（当前 agent-runtime 插件仍直接创建 two-track-agent）

  plugins/
    message-bus.ts         进程内事件总线（EventEmitter），取代 Redis pub/sub
    godot-agent-client.ts  backend 主动连接 Godot agent-host WebSocket
    action-bus.ts          进程内 action bus → Godot action.submit/action.cancel
    character-status-bus.ts  agent runtime thinking 状态 → Godot agent.thinking
    agent-runtime.ts    订阅进程内 event / perception-manifest / game-time bus，懒创建 AgentHost（原 worker.ts）

  routes/             HTTP（health, list runtimes, dev tools）
  db/                 SQLite schema + records（仅 backend 自有表；game-world 表由 Godot CREATE）
```

**关键边界**：
- `godot-link/` 不知道 LLM 或 prompt，是协议类型 / adapter / connection registry
- `agent-host/` 负责把 typed manifest/event 路由给 runtime，并提供缓存、catalog、storage、game tool 抽象；**不**直接 SELECT 游戏状态（那是 `services/world-state/`）
- `services/world-state/*-repo.ts` 是 SELECT-only 层：以 manifest 给的 id 列表为输入批量查 sqlite，返回 view 类型（`FarmView` / `WorkstationView` / `CharacterStateView` ...）。Repo 之间无相互依赖；不缓存，每 turn 当场 SELECT
- `runtimes/*/` 是具体实现；当前 two-track-agent 通过 agent-shared 的 assemble-from-manifest 拼 context，未来 runtime 也可以走完全不同路径

## 4. Per-NPC 路由 + 模型选择

按 [[project_npc_data_sources]]，NPC 配置真值在 `backend/data/town/npcs.json`。每条 npc 可加：

```jsonc
{
  "keir_march": {
    "name": "Keir March",
    "agent_runtime": "two-track-agent",   // 缺省 "two-track-agent"（项目默认，见 plugins/agent-runtime.ts）
    "agent_models": {                       // ⚠ two-track 必填——缺则 fatal
      "action":   "dashscope:glm-5.1/off",  // action 轨模型（建议关 thinking）
      "thinking": "dashscope:glm-5.1"       // thinking 轨模型（建议带 reasoning）
    }
    // ...其他字段
  }
}
```

**Boot 时**：`plugins/agent-runtime.ts` 一次性调 `loadNpcRuntimeConfig()` 拿 npcs 快照，传入 `createTwoTrackAgentRuntime({ ..., npcConfigs })`。AgentHost 用 `loadNpcRuntimeRouter()` 同源加载，按 `agent_runtime` 路由事件，Router 新增 `npcConfigFor(id)` 方法暴露原始 config。

**Default 路由**：agent-runtime 插件用 `defaultRuntime: "two-track-agent"`——常量在 `router.ts` `DEFAULT_AGENT_RUNTIME`，memory-service 同源消费保证命名空间一致。NPC 可在 npcs.json 用 `"agent_runtime": "null"` 把单个角色暂时挂空。

**模型选择**：

| 来源 | 缺失行为 |
|---|---|
| `npcs.json` `agent_models.action` / `.thinking`，校验两者都在 `AGENT_AVAILABLE_MODELS` | **fatal**，启动即抛带 NPC id 的错误 |

`resolveTwoTrackAgentModels(config, identity, raw)` 在 `agents/model-registry.ts`；解析结果在 two-track runtime per-character 缓存（lazy，首次 session() 创建时调）。env `AGENT_AVAILABLE_MODELS` 是模型清单白名单。

**Player**：玩家自然语言 `player.command` 也走同一个 runtime（two-track 的 player agentKind session，共用 NPC 的 action 模型），所以 player 角色也要在 `npcs.json` 配 `agent_models`。

**MVP 不支持热加载**：改 npcs.json 要重启 backend 进程。Router 和 two-track runtime 各自持自己的 npcs 快照，不共享对象引用。

## 5. 持久化收缩

按"是不是 Godot 真值"分两类。Backend 不持久化 Godot 拥有的东西，并且**不**对 game-world 表执行 `CREATE TABLE`（[[feedback_backend_not_game_db_owner]]）。

| 数据 | 处理 |
|---|---|
| 最新 perception manifest（id 清单 + 自身位置/睡眠状态） | **不持久化**，`AgentHostStateCache.manifestByCharacter` 内存缓存最新一份；Godot push（character `_ready` + 每次 `send_world_event` 前 flush，详见 [godot-agent-protocol.md §3.1](./godot-agent-protocol.md#31-perception-manifest)）；agent runtime 不主动 pull |
| 各实体当前状态（hp / 库存 / 农田每格 / 工作台 busy ...）| **Godot owner 的 sqlite 表**：`character_states / item_instances / farm_states / farm_plots / workstation_states / container_states / location_markers / shelf_listings / trade_offers`。Backend 只 SELECT，不 CREATE / UPSERT。每 turn 用 manifest 的 id 列表批量查 |
| world event 流 | SQLite `world_events`；Godot 写，backend 读，runtime 用做 relevance 排序 |
| in-flight action 记录 | SQLite `action_log`；状态为 `submitted / pushed / accepted / cancelling / completed / failed / cancelled`，用于观测、工具等待 terminal ack 和 cancel |
| runtime 长期记忆 / session 附属状态 | SQLite `runtime_storage`；通过 `RuntimeStorage` 暴露，按 runtimeName + townId + characterId 命名空间。two-track-agent 用它保存 working_memory KV、continued actions 队列、memory 表等 |
| Godot 连接记录 | **in-memory**；单连接情况下基本 trivial |

**Schema 归属**：
- **Backend 自有表**（backend CREATE）：`runtime_storage`、`action_log`、`agent_sessions`、`agent_session_messages`
- **Godot game-world 表**（Godot `db.gd` CREATE，backend 只读写）：上表所有 game-world entity 表 + `world_events` / `runtime_sessions` / `character_groups`

## 6. AgentRuntime 接口

```ts
interface AgentRuntime {
  readonly name: string;
  attach(ctx: AgentRuntimeContext): void;
  onEvent(event: WorldEvent, ctx: AgentRuntimeContext): Promise<void>;
  detach(ctx: AgentRuntimeContext): Promise<void>;
  // 可选：游戏时间 tick。当前 agent-runtime 插件直接对每个 runtime 调（不走 AgentHost），
  // 用于 thinking-track 定时 fire 等周期任务。
  // 本接口未来想统一到 AgentRuntime 上但 v1 还没收口。
  onGameTime?(townId: string, gameTime: GameTimeSnapshot, enabledCharacterIds?: Set<string> | null): Promise<void>;
}

interface AgentRuntimeContext {
  readonly characterId: string;
  readonly townId: string;

  gameTools(): GameTool[];                                  // host 包好的游戏 action
  getManifest(): Promise<PerceptionManifestPayload | null>; // 读 cache 中最新 manifest（id 清单）
  currentContext(): Promise<AgentCurrentContext | null>;    // 现 manifest + SELECT sqlite repos 拼好的 view
  recentEvents(opts?: { sinceMs?: number; limit?: number }): WorldEvent[];

  resolveCharacterName(id: string): string;   // i18n helper
  resolveItemName(id: string): string;
  resolveLocationName(id: string): string;

  storage(): RuntimeStorage;   // namespace 隔离的 KV，runtime 自己决定用不用
}

type GameTool = {
  name: string;            // "say_to" / "pick_up_item" / ...
  description: string;
  inputSchema: JSONSchema7;
  handler: (input: unknown) => Promise<ActionResult>;  // 内部 emitAction 给 godot-link
};
```

**关键设计选择**：

- `emitAction()` 不暴露：所有 game action 走 GameTool。这避免 runtime 绕过 host 的 game-tool 层（i18n 转换、schema 校验、命名规范）。
- `gameTools()` 由 host 提供：每个 Godot action 一份 GameTool 定义；任何 runtime 拿到的是同一份。**所有 tool 永远 expose**——agent host 不按上下文裁剪可用动作列表，"能不能做"由 Godot 在执行时校验返回 tool error（[[feedback_godot_is_authority]]）。Runtime 自己适配成所用框架的 tool 格式（pi-mono / 自写 dispatcher / langgraph）。
- Memory 类 tool 是 **runtime 内部的**（pi-mono 的 `update_memory`、未来 BT 的 state save 各自不同），不在 GameTool 列表里。Runtime 用 `storage()` 实现持久化。
- `storage()` 是 runtime 自己持久化的通道，host 不规定 schema；i18n catalog / events 等 host 已经做好的能力直接用。
- Runtime **不**经 host 拿 LLM SDK：runtime 自己 import anthropic / openai。Host 不假设 runtime 用 LLM。
- `currentContext()` 是个 factory hook：host 启动时由 agent-runtime 插件注入（`AgentHost` 构造参数），实现里组合 manifest + `services/world-state/*-repo`。Runtime 拿到的是已经渲染好的 view，不需要自己写 SQL。

## 7. 与现有代码的对应

**已落地**：

- `godot-link/perception-manifest.ts` / `actions.ts` / `events.ts` 定义 typed protocol vocabulary
- `agent-host/runtime.ts` 定义 `AgentRuntime` / `AgentRuntimeContext`
- `agent-host/host.ts` 负责 event ring buffer 与 runtime 路由；perception manifest 通过 `AgentHostStateCache.manifestByCharacter` 缓存最新一份供 runtime 读；`currentContext` 由 agent-runtime 插件注入的 factory 当场 SELECT sqlite 拼好
- `agent-host/router.ts` 支持按 `backend/data/town/npcs.json` 的 `agent_runtime` 选 runtime + `agent_models` 字段解析 + `npcConfigFor(id)` 暴露原始 config
- `agent-host/game-tools/*` 将 Godot action 封装成 tool，最终走 `submitAction()` / `action_log`；所有 tool 一直 expose 给 runtime
- `agent-shared/*`（[agent-shared.md](./agent-shared.md)）抽出 entity 名字解析 / 事件描述 / 通用 game tool / perception 装配等"非策略"代码
- `services/world-state/*-repo.ts` 完整覆盖 character / inventory / farm / workstation / container / shelf / location / trade 八类 view + `DisplayNameResolver` 统一 id→名翻译
- `runtimes/two-track-agent/`（[two-track-agent-session.md](./two-track-agent-session.md)）：action + thinking 双 session 模型，共享 `runtime_storage.working_memory`，per-NPC 双模型由 `agent_models` 配置
- `agents/model-registry.ts`：`resolveTwoTrackAgentModels` 按 npcs.json `agent_models` 解析 + 校验在 `AGENT_AVAILABLE_MODELS` 里，缺则 fatal
- `plugins/agent-runtime.ts` 订阅进程内 bus（`world.events:*` / `character.perception_manifest:*` / game time），驱动 `AgentHost.onEvent/onGameTime`；收到 manifest 一律 `ingestManifest` 写入 cache；启动时一次性 `loadNpcRuntimeConfig()` 快照传给 two-track，**改 npcs.json 要重启进程**

**仍待收口**：

- `runtimes/index.ts` 还没有成为唯一注册表；agent-runtime 插件仍直接创建 two-track-agent
- two-track-agent 仍直接 import `createSharedGameAgentTools`，没有完全只通过 `AgentRuntimeContext.gameTools()` 工作
- `agent-host/catalog.ts` 是 identity fallback；真实 i18n / catalog 在 `agent-shared/name-resolver/` + `services/world-state/name-resolver.ts`
- `nearbyContainers` 内容（container_states + 其 item_instances）尚未渲染进 prompt
- `services/perception-manifest.ts` adapter 仍认 snake_case / 旧字段名做兼容

## 8. 下一步

1. 把 `runtimes/index.ts` 补成真正 runtime registry，让 agent-runtime 插件不再手写 runtime map。
2. 让 two-track-agent 通过 `AgentRuntimeContext.gameTools()` 获取工具，减少 runtime 对 action-log-service / 总线的直接耦合。
3. 把 prompt catalog / i18n resolution 收口到 `agent-host/catalog.ts` 和 `services/world-state/name-resolver.ts`。
4. 定义多 worker 黏附与 failover：characterId → worker mapping、session 恢复、in-flight LLM call 丢弃策略。
5. 为 `action_log` 的非终态记录定义重启策略：启动时 fail 掉、显式 resumable，或由 Godot replay/ack 修复。

## 9. 与其它文档的关系

- 协议规范在 [godot-agent-protocol.md](./godot-agent-protocol.md)
- two-track-agent runtime 内部模型见 [two-track-agent-session.md](./two-track-agent-session.md)（当前唯一 LLM runtime）
- runtime 之间共享的非策略代码见 [agent-shared.md](./agent-shared.md)
- 进程拓扑见 [runtime-layers.md](./runtime-layers.md)；本文档对应那里的 "Worker（脑）" 进一步分层
- 系统总览（含本架构演进前的现状）见 [system-architecture.md](./system-architecture.md)
