# AI Town

*[English](README.md) | [简体中文](README.zh-CN.md)*

AI Town 是一个用 Godot + TypeScript 打造的**可玩的 AI 小镇**：一个手工搭建的中世纪世界，镇上的 NPC 都是会种植、采集、生产和交易的自治 LLM agent，无论玩家是否在场都让小镇保持鲜活。你将走进这个世界，体验生存、模拟经营与剧情解谜。当前代码是原型 / 研究性质的工作台，而非打包好的游戏成品。

## 功能介绍

- **一座会自己运转的小镇。** 约 25 名 NPC 都是自治的 LLM agent，跑的是和玩家完全相同的系统：种植、采集、制造、交易。物价、短缺与竞争都来自真实供需，而非脚本刷怪表；无论你是否在线，世界都在继续运转。
- **双轨 NPC 大脑。** 每个 NPC 同时跑一条快速反应轨（数秒内行动）和一条慢速策略轨（总结经历、规划、维护 working memory）——既保持灵敏，又目标明确，而代价远低于"每步都推理"。（详见下文。）
- **可用 Lua 自由扩展的玩法机制。** 配方、物品效果和世界规则都写在数据和沙箱化的 Lua 里，而非引擎代码中——加一种原料、甚至一整套全新行为，只需一段脚本，无需重新编译。这套沙箱能安全运行不受信任、乃至 AI 生成的脚本，而这正是"玩家自创魔法"得以成立的关键。
- **有真实赌注的制造。** 各行当的 0–100 熟练度配合每条配方的难度，决定制造能否成功、成色几何，而这份品质会跟着物品本身走。熟练度随练习成长，并通过技能书扩散——于是专精、雇佣大师、交易，都真正划算。
- **始终保有身份的物品。** 每样东西都是带结构化身份的类型实例——基础模板、制造它的反应所打上的涌现身份，以及每个实例自带的可变状态——因此品质、堆叠、容器、货架与交易在整个世界里都保持一致。

### 双轨 agent（two-track agent）

"快速反应"和"深度思考"方向相反：每步都跑一次 LLM 准确但又慢又贵，而纯反应式执行则容易跑偏、反复犯错、难以恢复。所以每个 NPC 会**同时跑两条独立的 LLM session**：

- 一条 **reactive track（反应轨）** —— 低延迟、关闭 extended thinking、握有完整工具集——在事件到来时被唤醒，并把事件直接转成世界中的行动；
- 一条 **strategic track（策略轨）** —— 开启 extended reasoning —— 定期总结 working memory 之后新发生的事件、规划，并写下一段简短的 working memory 简报。

反应轨读取这份简报、按当前策略以极低成本持续推进，只在出现实质事件或时间过去足够久时才重新唤起策略轨。最终 NPC 既能在数秒内行动，又能在后台持续深度思考——而不需要单一合并 session 在每次事件到来时都"中止再重启"的那套复杂机制。

### 路线图

除上述系统外，规划中的主要系统有：

- **魔法** —— 用自然语言描述一件物品或一个法术，由 LLM 生成沙箱化 Lua，变成世界中可用的对象，靠 mana 代价来平衡，而非靠设计师白名单。知识本身也是实体：法术书可被阅读、传授、逆向工程、买卖与盗窃。
- **战斗** —— 哈利波特式的魔杖对战，真 3D 弹道、躺地闪避、掩体格挡，由行为树 NPC AI 驱动。
- **DM 剧情** —— 一个 LLM 扮演的"地下城主"（Dungeon Master），根据玩家和 NPC 的行为，把动态任务、事件和涌现式剧情编织进小镇，支撑剧情解谜玩法。

完整设计见 [`docs/design-doc.md`](docs/design-doc.md)，落地实现相关的笔记见 [`docs/architecture/`](docs/architecture/)。

## 仓库里有什么

- 客户端 / headless runtime / UI / 世界模拟 / 农耕 / 制造 / 商业 / 本地交互系统的 Godot 4.6 工程。
- 使用 Fastify、SQLite，并通过 WebSocket 连接 Godot runtime 的 Node.js 后端。agent runtime 在同进程内运行（无 Redis，单进程）。
- 负责事件驱动的 NPC 思考、记忆、prompt 上下文和 action 提交的 agent runtime 代码。
- 种子数据、中文本地化、架构笔记和开发脚本。

## 目录结构

```text
src/        Godot 玩法、UI、runtime/client 逻辑、模拟系统
assets/     工程自有或生成的资产，以及 Godot 资源包装
data/       游戏机制、配方、本地化和资源定义
backend/    Node.js 后端、SQLite schema、同进程 agent runtime
docs/       设计笔记与基于实现整理的架构文档
scripts/    本地搭建、Godot 启动和维护辅助脚本
addons/     Godot 插件清单；大体积二进制需单独安装
```

## 关于资产的重要说明

本仓库可以作为源码打开，但它**不是**一个完整可再分发的资产包。

- `third-party/` 目录被刻意 gitignore。部分被追踪的场景引用了预期位于 `third-party/polygon-fantasy-kingdom`、`third-party/mixamo` 或其他本地 vendor 目录下的资产。
- `assets/buildings/*.tscn` 是引用 Polygon Fantasy Kingdom 资源的工程场景组合。除非在本地安装了对应的授权资产包，否则它们无法正确渲染。
- `assets/sprites/` 下生成或下载的图片 / sprite 资产在发布构建前必须经过审查。代码 license 并不自动授予对每一项资产的公开再分发权利。
- 在分发构建、截图或资产归档前，请先阅读 `THIRD_PARTY_NOTICES.md`。

## 前置依赖

- Godot 4.6 或更新版本，并启用 Jolt 物理后端。
- Node.js 22 或更新版本。
- pnpm 9.x。

无需任何外部服务——后端是单个 Node 进程，状态保存在本地 SQLite 文件里。

可选的 agent 提供商需要在 `backend/.env` 中配置 API key。不要提交真实的 `.env` 文件。

## 搭建

```bash
git clone <repo-url>
cd ai-town

./scripts/install-sqlite-gdextension
./scripts/install-lua-gdextension
./scripts/dev setup
```

`./scripts/dev setup` 会在需要时把 `backend/.env.example` 复制为 `backend/.env`，并安装后端依赖。

如果 Godot 没有安装在 macOS 默认应用路径，且 `PATH` 上也没有 `godot` 命令，请设置：

```bash
export GODOT_BIN=/path/to/Godot
```

## 本地运行

一条命令同时启动 Godot server + 后端（首次运行会自动建表，后端自带 `/debug` 页面）：

```bash
./scripts/dev all
```

想归档当前世界、开新一局，加 `--INIT`（旧 `state.db` 会被移到 `backend/data/archive/`）：

```bash
./scripts/dev all --INIT
```

在另一个终端启动玩家客户端：

```bash
./scripts/dev client
```

常用检查：

```bash
./scripts/dev status
curl http://127.0.0.1:3000/health
curl http://127.0.0.1:3000/ready
```

## 仅运行后端

```bash
cd backend
cp .env.example .env
pnpm install
pnpm dev
```

这是单个进程——网关 + agent runtime + `/debug` 页面，无需外部服务。后端职责与协议细节见 `backend/README.md`。

## 密钥与本地数据

以下内容必须只保留在本地：

- `backend/.env`
- 诸如 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`DASHSCOPE_API_KEY` 等提供商专用的 API key
- `backend/data/state.db` 及归档的运行时数据库
- 本地 debug 日志、生成的后端 `dist/`、Godot `.godot/`，以及本地 agent / 编辑器设置

在公开发布前，请运行：

```bash
gitleaks detect --source . --redact=100 --verbose --no-banner
gitleaks dir . --redact=100 --verbose --no-banner
```

如果真实 key 曾出现在 Git 历史中，即使重写了历史，也务必到对应提供商处轮换该 key。

## 文档

- `docs/architecture/system-architecture.md` 是最佳的技术入口。
- `docs/architecture/README.md` 是架构文档索引。
- `docs/tech-doc.md` 包含较早的 runtime 笔记与实现注意事项。

## 许可证

代码与文档采用 MIT 许可证。资产与第三方包可能另有条款。详见 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`。
