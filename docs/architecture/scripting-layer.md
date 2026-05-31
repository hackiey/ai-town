# Scripting layer

> Status: **partial** — Lua VM 集成 + 第一个 effect 类型 + 沙箱白名单已 landed；spec.ts 单一真相源、sandbox hardening、其他 effect 类型未做。

Lua 脚本执行管道。LLM/玩家创造的 item / spell / hook 行为都通过这一层。

## 1. Context

游戏的核心创新是"玩家描述 → LLM 生成 lua → 沙箱执行"的内容循环（[design-doc §5](../design-doc.md)）。本层提供：
- **执行环境**：沙箱化 Lua VM，跑不可信脚本不污染引擎
- **API surface**：Lua 能调的世界查询 + effect 声明
- **Effect 应用层**：把脚本声明的 effect 翻译成游戏状态变化

## 2. Design

### 2.1 归属：跑在 Godot 服务端 runtime

按 [runtime-layers.md](./runtime-layers.md) 的脑/身分层，"脚本执行 = 物理操作"是身的责任。如果 lua 在 worker，等于让脑直接改世界状态，把刚切干净的边界又粘回去。

**Worker 在脚本层只做两件事**：
1. **生成**：LLM 把玩家自然语言 → Lua 源 + visual 元数据 → SQLite / 资产存储
2. **校验**：解析 + 静态白名单检查 + dry-run（在 worker 里跑也是为了校验，不是执行）

执行永远在 Godot。

### 2.2 Effect 模型：声明而不 mutate

Lua 脚本**永远不直接改游戏状态**，只声明意图："我要给 caster 的 stamina +5"。executor 收集所有 effect → 校验 → 应用。

理由：
- 跨 server 重放结果一致（确定性）
- 校验放在 lua 之外，玩家代码再坏也只能让自己 fail
- effect 列表可以审计、可以被 LLM 反思读

### 2.3 持久挂载效果（active effects）

一次性 effect（伤害、爆炸、buff 倒计时）和持久 effect（光球跟人、aura、concentration spell）需要不同模型：

```
ActiveEffect {
  handle, owner_caster, source_item_id,
  type, params, anchor_id, anchor_bone,
  started_at, mana_per_tick,
}
```

**Concentration 模型**（D&D 5e 风）：
- 召唤期间 caster 的"已占用 mana 槽" `mana_reserved += N`
- caster 实际可用 = `max - reserved`
- 引擎统一在 caster 死亡 / 离线 / 进反魔法区时清理其所有 active_effects
- Replay：runtime 重启时从 SQLite 恢复 active_effects

未实现，等做光球类法术时一起。

### 2.4 spec.ts 单一真相源（最重要的设计原则）

**API 表设计是这个游戏唯一的核心创新点**，比所有沙箱/性能/网络问题都重要。

`spec.ts`（计划中，未实现）从单一定义派生：
- LLM 的 system prompt（"你能调的 API 是这些"）
- Validator 的白名单
- Mana cost 表
- Lua type stubs（in-context examples）
- 知识系统的"API 单元"颗粒（[design-doc §4](../design-doc.md)）

任何一处脱钩立刻出 bug：LLM 输出调不存在的 API（100% 失败率），或沙箱允许了但 cost=0（无限免费伤害）。

**设计方法：co-design**——不是先定属性再定 API，也不是先定 API 再定属性，而是：
1. 手写 5-10 个目标法术 lua 源
2. 倒推每个法术读/写了哪些属性、调了哪些 API
3. 整理累计清单 → spec.ts 初版 + entity schema 初版
4. 反复迭代

## 3. Implementation

**Lua VM**：[gilzoide/lua-gdextension v0.8.0](https://github.com/gilzoide/lua-gdextension)（Lua 5.4）
- macos/win/linux/android/ios/web 全平台 prebuilt binaries 进 git
- vs Luau：Luau 沙箱设计更精致，但无 prebuilt mac binaries，要从源码 CMake build
- 未来迁移：换 Luau 或自加 `debug.sethook` 仅修改 `script_executor.gd` 内脏

**文件位置**：

| 路径 | 作用 |
|---|---|
| `addons/lua-gdextension/` | GDExtension manifest + lua_api_definitions（小，进 git） |
| `addons/lua-gdextension/build/` | 平台 binaries（**gitignored**，跑 `./scripts/install-lua-gdextension` 拉取） |
| `src/sim/scripting/script_executor.gd` | 公共入口 `ScriptExecutor.execute()` |
| `src/sim/scripting/script_api.gd` | 注入 `affect.*` / `world.*` 给 Lua |
| `src/sim/scripting/effects.gd` | `Effects.apply()` 派发表 |

**首次 setup**：克隆仓库后跑一次 `./scripts/install-lua-gdextension`（默认装当前 OS 的 binary，~8MB）。`--all` 装全部平台（CI / 跨平台 dev），`--force` 覆盖重装。升级版本：改脚本顶部 `VERSION` 一处。

## 4. Contract

**所有需要执行 lua 的子系统**（inventory 用消耗品、施法、命中触发 hook 等）都通过这一个入口：

```gdscript
ScriptExecutor.execute(source: String, entry: String, ctx: Dictionary) -> Dictionary
```

**参数**：
- `source` — Lua 源代码（顶层只允许 function 定义；不允许顶层 side-effect）
- `entry` — 入口函数名，按场景定：`"on_use"` / `"on_cast"` / `"on_hit"` / `"on_equip"` 等
- `ctx` — 上下文字典，会转成 lua table 传给 entry。**约定字段**：
  - `caster: Character` — 使用者 / 施法者（必填）
  - `target: Character | null` — 目标（按 entry 类型可选）
  - `item: Resource | null` — 触发的 item 实例（让脚本通过 `ctx.item` 自检 self）

**返回**：
```gdscript
{
  ok: bool,                  # 执行成功且 effects 都应用完
  effects: Array,            # 每个 effect 的应用结果摘要
  error: String,             # ok=false 时填错误描述
}
```

每个 `effects[i]` 形状：
```gdscript
{ type: String, applied: bool, summary: String, error?: String }
```

**调用方应**：
1. 构造 ctx
2. 调 `ScriptExecutor.execute(item.source, "on_use", ctx)`
3. 检查 `result.ok` 决定是否 commit（消耗物品 / 扣资源 / 落档）
4. **不**自己解析 effects——effect 应用已经在 executor 内部做完，调用方只需要看 ok

### 4.1 当前 effect 类型

只支持一个原语（co-design 第一轮再扩展）：

| type | payload | 行为 |
|---|---|---|
| `modify_stamina` | `{ target: Character, amount: float }` | `target.stamina = clamp(target.stamina + amount, 0, max_stamina)` |

加新 effect type：
1. 在 `effects.gd` 的 `apply()` match 里加 case
2. 在 `script_api.gd` 的 `inject()` 里加对应 `affect.*` 注入
3. 后续：从 spec.ts 派生（见 §2.4）

### 4.2 Lua 可用 API

**白名单的 Lua 标准库**：`base / string / table / math`

**禁用**：`io / os / package / debug / coroutine` + 整个 Godot 集成那一组（VARIANT/SINGLETONS/CLASSES）——脚本不该直接 new Object 或拿 OS 单例

**Godot 注入的全局**：

| 全局 | 形状 | 说明 |
|---|---|---|
| `affect.stamina(target, amount)` | 写：声明意图 | 不立即生效，executor 跑完后由 Effects.apply 统一应用 |
| `world.now()` | 读：免费查询 | 返回当前 ticks 秒（占位；后续扩 `world.distance` / `world.find_nearby` / `world.faction_of`） |

**第一个 demo lua**（验证用，已删除）：
```lua
function on_use(ctx)
    affect.stamina(ctx.caster, 5)
end
```

## 5. 沙箱当前状态

| 项 | 状态 |
|---|---|
| 库白名单（io/os/package/debug 全屏蔽） | ✅ |
| 错误用 LuaError 接住，不 crash 引擎 | ✅ |
| 指令计数 cap（防死循环） | ❌ lua-gdextension 未直接暴露 `debug.sethook`，需要 fork addon 或换 Luau |
| 内存 hard cap | ❌ addon 提供 `get_memory_used` 可观测，但没强制 cap API |
| Wall-clock timeout | ❌ 未来加 OS thread + abort |

**LLM 生成内容上线前必须补齐这三项**；当前 hand-coded lua 阶段可控。

## 6. 验证记录

2026-05-06 跑通的两个测试（fixture 已删除，同形 demo 任何时候可临时挂回 town.tscn 重做）：
- ✅ Apple positive：`affect.stamina(ctx.caster, 5)` → NPC.stamina 50 → 55
- ✅ Sandbox negative：`os.execute("echo escape")` → "attempt to index a nil value (global 'os')"，stamina 不变

## 7. Open questions

- **Sandbox hardening**：指令 cap / 内存 cap / timeout（LLM 上线前必须）
- **spec.ts 何时建**：等 co-design 第一轮跑出 5-10 法术
- **Active effects 的 SQLite schema**：等做第一个持久 effect（光球）
- **LLM 生成失败的降级策略**：玩家描述太离谱、生成不合规怎么办（[tech-doc §6 待决 #7](../tech-doc.md)）
