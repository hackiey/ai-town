# Godot ↔ Agent host protocol

> Status: **partial** — 协议主干已在 `src/autoload/backend_runtime_client.gd` 和 `backend/src/godot-link/*` 落地。Action target 和 world event data 的形状契约现在分别由 `backend/src/godot-link/actions.ts`（`ActionTargetByName`）和 `backend/src/godot-link/world-events.ts`（`WorldEventDataByType`）单点定义；翻译 / 兼容字段解析层已删除。Godot 侧仍是 `Dictionary` 消息，运行时校验只剩"形状不对就 reject"这种硬错。

Godot server 单方面对外承诺的协议。任何 agent host（今天的 Node backend、未来其它）符合这份就能驱动 NPC；不符合就是 bug。

## 1. Context

Godot server 是世界状态的唯一权威（[runtime-layers.md §2.1](./runtime-layers.md#21-脑身分层)）。"agent" 这一侧——决策、记忆、规划——可以是 LLM、可以是行为树、可以是脚本。为了让两侧**可独立演进**，必须先把它们之间的接口钉死，agent host 实现按规范来。

**契约真值（single source of truth）**：

- Action wire：`backend/src/godot-link/actions.ts` 的 `ActionTargetByName` / `ActionResultByName`。Backend tool-factory 直接写这个 shape，Godot dispatcher 按 canonical 单 key 读，**中间没有翻译层**（旧版本的 `action-adapter.ts` 已删除）。
- World event data：`backend/src/godot-link/world-events.ts` 的 `WorldEventDataByType`。Lua mech 和 GDScript emit 站点直接写这个 shape，backend renderer 按 canonical 单 key 读。
- 命名：camelCase，单字段。**禁止** alias（`characterId`/`actorId` 不能并存；`affectedCharacterIds`/`visibleToCharacterIds` 不能并存；snake_case 变体不能并存）。任何字段加 alias 都是 schema 漂移的开始。
- 校验：违反契约就 reject（参见 §3.2 / §4），不再"宽容兜底"——历史经验：兜底层会把空数据偷偷传下去，bug 浮到 prompt 层才被发现（offer_trade 的"付（无），换（无）"就是这么来的）。

## 2. 角色与连接

```
┌─────────────────┐                    ┌─────────────────┐
│  Godot server   │ ←── WebSocket ───→ │   Agent host    │
│   (authority)   │                    │    (driver)     │
└─────────────────┘                    └─────────────────┘
```

- **一对一**：一个 Godot server 接受**一个** agent host 连接。"不同 NPC 用不同 agent 系统"是 agent host 内部 router 解决的事，Godot 不知道。
- **谁是真值**：Godot 是游戏世界状态的唯一权威，并把所有可变实体（character / item_instance / farm_plot / workstation_state / container_state / location_marker / world_event 等）**持续 UPSERT 进共享 SQLite**。Agent host 不持久化游戏状态；每次决策当场 SELECT sqlite 真值 + 当 turn manifest 拼 context（详见 §3.1）。
- **传输**：JSON over WebSocket。每条消息是 envelope：`{ id, seq, type, townId, createdAt, version, payload }`。
- **连接方向**：Godot server 的 `BackendRuntimeClient` 在本地监听 agent-host WebSocket；Node backend 的 `godot-agent-client` 主动连接并发送 `agent.host.hello`。
- **Auth & town routing**：`agent.host.hello` 携带 `townId`、`token`、`lastAckSeq`、`locale`；Godot 接受或拒绝。
- **重连**：agent host 重连后，Godot 根据 `lastAckSeq` 回放 replay buffer 中未 ack 的 sequenced world event；并对所有 character 各 push 一份 perception manifest 重建 cache。

## 3. Push 流（Godot → Agent host）

两类核心 push，按用途和触发时机分开：

### 3.1 Perception manifest

**用途**：某个 character 此刻**感知到的实体 id 清单**（地点 / 人 / 物 / 农田 / 工作台 / 货架 / 容器，按类别分组）+ 自身 location/position/groupIds/isAsleep 等少量随包字段。**不**携带实体的状态细节（hp、库存、农田每格是否成熟、工作台是否 busy 等）——那些一律由 backend 当场 SELECT sqlite 真值表得到。

Manifest 是个"目录"，不是 "snapshot"。`message type = character.perception_manifest`；envelope payload 在 TS 侧定义为 [`PerceptionManifestPayload`](../../backend/src/godot-link/perception-manifest.ts)。

**触发**（全部由 Godot 主动 push）：
- `_ready` 完成：character 上线时主动推一次作为 cache 起点
- **事件 emit 前强制 flush**：任何 `send_world_event(...)` 之前，遍历该事件的 `actorId + affectedCharacterIds`，对每个 character 调 `send_perception_manifest`

**因果同步契约（关键）**：

> **任何 `send_world_event` 调用之前，相关状态变更必须已经写到共享 sqlite，且相关 character 的 manifest 已经反映此刻能感知到的所有实体。**

manifest 本身只列 id，所以"反映状态"主要体现在两件事：
1. **状态变更先 UPSERT 进 sqlite**：改 condition / inventory / attribute / farm_plot / workstation_state 等都**必须同步发生在 `send_world_event` 之前**，且不得 `await` / `call_deferred` 错开调用栈——保证之后任何 SELECT 读到的是新值
2. **manifest flush 在事件之前**：`send_world_event` wrapper 内部先按 `actorId + affectedCharacterIds` flush manifest，再发事件
3. 通过 WebSocket 单连接 in-order 保证 backend 收到顺序：manifest 先到入 cache，event 后到处理时读 cache 必然 ≥ 事件时点；同 turn 内 SELECT 读到的 sqlite 行也已经是新值

**反例（禁止）**：
```gdscript
backend.send_world_event("item_used", "", {...})    # 先 emit
character.consume_item(item_id)                     # 后改状态 ← 错误：backend SELECT 拿到事件前的旧值
```

正确顺序：
```gdscript
character.consume_item(item_id)                     # 先改状态（同步 UPSERT sqlite）
backend.send_world_event("item_used", "", {...})    # 再 emit；wrapper 内 flush manifest，新值已落库
```

**本帧去重**：character 维护 `_perception_manifest_pushed_this_frame` flag，一帧内多次 flush 只推第一次（同帧主线程未让出，manifest 内容相同）。每帧末 `_process` 尾 reset。

**Backend 端**：`AgentHostStateCache.manifestByCharacter` 按 `townId + characterId` 缓存最新 manifest；订阅 `character.perception_manifests:*` Redis bus 无条件覆盖；`getManifest` 直接读 cache。**无 pull 路径**——cache miss 时返回 null，调用方自行判定是否 fallback（一般 character `_ready` 时已 push 过初始 manifest，cache miss 仅在启动竞争窗口内出现）。

具体状态查询走 `backend/src/services/world-state/*-repo.ts`：runtime 拿到 manifest 后用其中的 id 列表批量调 repo SELECT，得到 view 对象，再交给 prompt assembler 拼 LLM context。

### 3.2 Event

**用途**：离散世界事件。"A 对 B 说了 X"、"日落"、"作物成熟"、"背包被偷"。Snapshot 是**状态**，event 是**发生过的事**——前者代表"现在是什么样"，后者解释"为什么变成这样"。

**触发**：事件发生时立即 push。Godot 给每条 event 附带 `affectedCharacterIds`——感知到这件事的 character 列表（声音/视野半径由 Godot 计算）。

**Type 词表**：closed set。Godot 定义所有可能的 event type，每个 type 自带固定 data 形状。Agent host 收到不认识的 type 不该崩，记录后忽略（向前兼容）。

**Data 形状契约**：每种 event type 的 `data` 形状定义在 `backend/src/godot-link/world-events.ts` 的 `WorldEventDataByType`。所有 payload 必须包含：

- `data.actorId: string` —— 行为人；backend `event-adapter.ts` 在入站时提升到顶层 `event.actorId`。
- `data.affectedCharacterIds: string[]` —— 感知 / 受影响的 character 列表；同时被 `BackendRuntimeClient.send_world_event` 用于事件前 snapshot flush，被 backend 用于路由判断哪个 character 该收到这件事。

不允许的 alias：~~`characterId`~~（用 `actorId`）、~~`visibleToCharacterIds`~~（用 `affectedCharacterIds`）、~~`actor_id` / `target_character_id` / `duration_game_minutes` 等 snake_case 变体~~、~~`to`~~（用 `targetCharacterId`）。Per-event-type 字段也走 camelCase 单 key，例如 trade 直接用 `buyerCharacterId` / `sellerCharacterId`，**不**再写 `targetCharacterId` 复述一遍。

**Ingress 校验**：`event-adapter.ts` 入站时检查 `actorId || affectedCharacterIds.length > 0`（或 `data.scope === "global"` 的 ambient 事件），不达标直接 reject。不做 alias 翻译；emitter 不按契约写就在源头 fail loud。

### 3.3 Heartbeat / Protocol Ack

**用途**：连接活性和 replay cursor。

- Godot 定期发送 `runtime.heartbeat`，payload 中包含 instance、在线玩家数、角色数和 game time。
- 两边收到带 `seq` 的消息后，用 `protocol.ack` 回传 `ackSeq`，供 replay buffer 剪裁。
- 当前 “开始 / 停止 thinking” 不是 Godot→Agent 的 status，而是 Agent host→Godot 的 `agent.thinking` 控制消息，用于头顶状态展示。

## 4. Action 流（Agent host → Godot）

### 4.1 Action 形状

```
{
  id: string,           // agent host 生成，ack 时回带
  characterId: string,
  action: ActionName,   // closed enum，由 Godot 定义；TS 类型里也叫 CharacterAction
  target: object,       // 形状由 action 决定，见下方
  reason?: string,      // 调试 / 观测用
  priority?: number,
  expiresAt?: string,
  createdAt?: string,
  gameTime?: object,
}
```

`action` 是 closed enum——加新动词必须 Godot 加完才能用。Agent host 不能发明 action。

**Target 形状契约**：每种 action 的 `target` shape 定义在 `backend/src/godot-link/actions.ts` 的 `ActionTargetByName`。Backend `tool-factory` 通过 `submitToolAction<TName>(actions, characterId, action, target: ActionTarget<TName>, ...)` 提交时 TS 编译期就把 shape 钉死；Godot dispatcher 按 canonical 单 key 读。**中间无翻译层**——`action-log-service` 直接透传 `target` 字典进 sqlite，Godot dispatcher 再原样取出。

不允许 alias：和 §3.2 的命名规则相同（camelCase 单 key，不写 snake_case 变体也不并存语义重复的字段）。例如 `offer_trade.target` 就是 `{characterId, offer: TradeLine[], request: TradeLine[]}`，不再有 `targetCharacterId` / `offerItemIds` 等并存形态。

Ack 回来的 `result` 形状对应 `ActionResultByName[<action>]`，同样 camelCase 单 key。

### 4.2 Lifecycle

```
agent host                      Godot
  │  submit ──────────────────────▶
  │                               │ (校验：在不在附近、目标存在不存在 ...)
  │                               │
  │  ◀──── ack { accepted } ──────│   ⟵ Godot 收到并开始执行
  │                               │
  │  (可选) ◀──── progress ack ───│   ⟵ 长任务的中间状态 / partial result
  │                               │
  │  ◀──── ack { terminal } ──────│   ⟵ completed / failed / cancelled / interrupted
```

- **串行 / preempt**：每个 character 的 `BackendActionRunner` 同时只持有一个 active action。提交第二个 action 时，Godot 端会按 runner 规则打断或覆盖正在执行的 action；backend 也可以通过 `preempt` 先发 cancel。
- **Speech overlay**：`say_to` 是例外。若角色已有 active action，Godot 的 `BackendActionRunner` 会直接执行 `say_to` 并立刻 ack，不 preempt 当前 active action。用于“采矿/农事/走路时边干活边回话”。
- **Sensory events**：`say_to` 和 `move_to_location` 这类带 `affectedCharacterIds` 的可感知事件可在角色工作中触发 agent 的 `sensory` turn。Agent host 只根据 Godot 给出的可见性列表判断谁感知到事件，不重算距离。
- **Tool 校验权威全在 Godot**：所有 game tool 永远 expose 给 LLM，agent host 不预判"现在能不能做"。Godot 在 action 执行时按真实规则（DIRECT_RADIUS、库存、可见性 etc.）校验，不达标返回 tool error。Manifest 的 `perceivedFarmIds / perceivedWorkstationNodeIds` 等只表达"能感知到"，不表达"能直接交互"——后者由 tool 执行结果回答。
- **长动作 detached result**：backend 可以在不 cancel active action 的情况下停止等待某个长 tool，并先把 progress result 返回给 LLM。此时 action lifecycle 在协议层不变：Godot 仍继续执行原 action，完成后照常发送 terminal ack。是否把 terminal ack 转成 AgentSession 的额外提醒，是 agent runtime 内部策略，不是协议新消息。
- **Cancel**：agent host 提交 cancel 给 Godot（协议级控制消息，不是 action），Godot 处理完发 terminal ack。
- **Progress**：长任务可以用 `accepted` ack 携带 `result` 作为中间进度；backend 会保留在 `action_log.result`。
- **Result**：terminal ack 可能带 `result` 数据（如 `plan_farm_work` 一次执行多步要回 partial summary）。Result shape 由 action 决定。
- **Control**：Agent host 还可以发送 `agent.thinking`、`character.groups.refresh` 等控制消息。Godot 处理后用 `protocol.ack` 确认，不进入 action lifecycle。

新增 action/event 时，协议只定义词表、target/result shape、progress/result 字段和可见性列表；agent runtime 是否把它当作 `body`、`speech`、`sensory` 或 hard interrupt，统一在 backend 的 `agent-shared/event-semantics` 与 `runtimes/<agent>/semantics` 注册。

## 5. Authority 边界

**Godot 是权威**：

- 拥有共享 sqlite 的 game-world schema（`character_states / item_instances / farm_states / farm_plots / workstation_states / container_states / location_markers / world_events / character_groups / runtime_sessions` 等），所有 mutation 立即 UPSERT
- 校验 action 合法性（"目标在不在附近"、"背包里有没有这个物品"、"角色还活着"）—— **agent host 不预校验**
- 决定执行顺序、决定打断、决定 timeout
- 失败/拒绝 reason 在 terminal ack 里编码（`status: "failed"`、`error: "<reason>"`）
- 在 action 结束时返回结构化事实变动；当前统一放在 `action.ack.payload.result.character_changes`
- **派生量也由 Godot 算并写盘**：原则上每个被 LLM / DB 读到的状态字段都只能有一个写者。即使是公式可恢复的派生量（典型如 `farm_plots.stage` 从 `spawnedAtGameHour + variety.maturation_hours` 推），也由 Godot 端唯一公式入口（Lua `compute_stage`）算完后随 raw 字段一起落 sqlite。backend SELECT 拿现成，不再镜像 stages 数组 / maturation_hours / 公式（曾出现 Lua `stages={vegetative,flowering}` vs backend `stages={tillering,heading}` 单位漂移）

**Agent host 不做**：

- ❌ 校验 "action 现在能不能做"（提交即可，被拒就被拒）—— [[feedback_godot_is_authority]]
- ❌ CREATE / 拥有 game-world 表（只 SELECT；backend 自己的表见 §backend-agent-host.md §5）—— [[feedback_backend_not_game_db_owner]]
- ❌ 镜像 Godot 端的派生公式 / variety catalog；显示名（如 stage 中文名）走共享 i18n catalog（`prompt.context.crop_stage.<variety>.<stage>` → `.default.<stage>` fallback），两边读同一份 key
- ❌ 预测 action 结果（等 ack）
- ❌ 在协议层编写给 LLM 看的 prompt 文案

这一条已经在 [[feedback_godot_is_authority]]，规范里写白主要给未来 agent host 看。

### 5.1 `character_changes`

`character_changes` 是 Godot server 在 action 收口时根据执行前后状态 diff 生成的结构化事实。它不是 prompt 文案，字段名应使用稳定 slug，可被 runtime 通过 name resolver 再渲染。

当前形状：

```ts
type CharacterChanges = {
  attributes?: Array<{
    field: string;
    before: unknown;
    after: unknown;
  }>;
  backpack?: Array<
    | { kind: "quantity"; item_id: string; display_name: string; quality?: number; before: number; after: number; delta: number }
    | { kind: "durability"; item_id: string; display_name: string; before: number; after: number; max: number }
    | { kind: "container"; item_id: string; display_name: string; before: string; after: string }
  >;
};
```

Rules:

- Only include changed facts; omit empty `attributes` / `backpack` sections.
- Attribute `field` is the stable attribute slug (`hp`, `stamina`, `hunger`, ...). Runtime resolves display names through the attribute name resolver / i18n catalog.
- Attribute changes are actual current-value changes, not predicted costs. For example, do not put cumulative theoretical stamina cost in `character_changes` unless the character's stamina value really changed.
- Backpack quantity changes are aggregated by item/quality/display name.
- Durability and liquid-container changes are slot-state changes and should be reported even when quantity is unchanged.
- Runtime-specific wording such as "next suggestion" or "status: success" belongs nowhere in this payload.

## 6. 标识与命名

- **Slug 是协议 first-class 类型**：`characterId`、`locationId`、`itemId`、`workstationId` 等 id 是稳定 slug（snake_case 或 kebab-case 由对应 catalog 决定），跨重启稳定。
- **没有显示名**：Godot 协议层不发"人类可读名字"。Agent host 自己负责 i18n（i18n catalog 在 agent host 内）。
- **跨边界翻译只在 agent host 内做**：LLM 看到的是显示名，发回的 tool call 在 agent host 边界翻译回 slug，再走协议。这条已经在 [[feedback_llm_id_name_boundary]]。

## 7. 版本演进

- Message envelope 带 `version: <semver>` 字段。
- Agent host 收到 **major 不一致** 的消息：reject 整个连接（不要尝试部分兼容）。
- Backward-compat 规则：
  - Snapshot/event payload **加字段** = minor bump（低版本 agent host 忽略新字段即可）
  - **改字段含义、删字段、改名** = major bump
  - Action enum **加新词** = minor bump
  - Action enum **删词、改 target shape** = major bump

没有运行时能力协商（[[feedback_prefer_simpler_designs]]）；版本 mismatch 等于配置错，应该在部署阶段就发现，而不是 runtime 适配。

## 8. 现状差距

记录今天的实现跟目标协议的偏差，作为重构 backlog：

- Godot 侧仍是 `Dictionary` payload，没有从 TS schema 生成 GDScript 校验器。类型约束在 Godot 侧靠 GDScript dispatcher 按契约 key 读 + backend `event-adapter` 入站时 reject 形状不合法的 payload，没有自动 schema diff。
- Action target / world event data 的契约已收口到 `actions.ts` / `world-events.ts`（[2026-05 重构](#)），翻译层 `action-adapter.ts` 已删除；但 `perception-manifest.ts` 仍保留少量兼容字段解析（snake_case / 旧字段名），是收窄协议面的下一刀。
- `AgentConnectionRegistry` 的 backend→Godot `nextSeq` / `lastAckSeq` 主要在内存；断线时写 `runtime_sessions`，但还没有 durable replay queue 来恢复未 ack 的 `action.submit`。
- Godot 的 replay buffer 当前只保存 replayable `world.event`；perception manifest 通过重连后重新发送，action 去重 / finished action cache 仍是内存缓存。
- `perceivedContainerIds` 已上行但 prompt 侧还未消费 container 内容；`soul` 由 backend i18n / runtime_storage 侧承接，未作为协议一等 typed payload 使用。

补齐顺序：perception-manifest 收窄兼容字段 → Godot 侧 schema 校验生成 → durable backend→Godot replay queue → prompt 消费 container 内容 / 明确 `soul` 边界。每一步独立 PR。

## 9. 与其它文档的关系

- 本规范定义 **Godot 对外承诺**；agent host 的内部架构见 [backend-agent-host.md](./backend-agent-host.md)
- AgentSession 是 two-track-agent runtime 内部的会话机制，不属于本协议；见 [two-track-agent-session.md](./two-track-agent-session.md)
- 进程拓扑见 [runtime-layers.md](./runtime-layers.md)
