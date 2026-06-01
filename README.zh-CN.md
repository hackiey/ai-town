# AI Games

*[English](README.md) | [简体中文](README.zh-CN.md)*

AI Games 是一个用 Godot + TypeScript 打造的**可玩的 AI 小镇**：一个手工搭建的中世纪世界，镇上的 NPC 都是会种植、采集、生产和交易的自治 LLM agent，无论玩家是否在场都让小镇保持鲜活。当前代码是原型 / 研究性质的工作台，而非打包好的游戏成品。

## 功能介绍

AI Games 的目标是做一个**可玩的 AI 小镇**：一个手工搭建的中世纪世界，镇上的 NPC 都是能真正生活和劳作的自治 LLM agent。无论玩家是否在场，它们都会让小镇运转下去——而你将走进这个世界，体验生存、模拟经营与剧情解谜。

**会真正做事的 NPC agent。** 这是整个项目的核心。每个 NPC 都是一套双轨 agent——一条快速的 action 轨对事件做出反应，一条较慢的 thinking 轨（开启 extended reasoning、按定时触发）进行反思与规划，思路参考了 Generative Agents（Smallville）论文。更关键的是，它们在世界里拥有真实的能力：

- **种植** —— agent 会播种、浇水、除虫、收获，作物随游戏时钟生长。
- **采集** —— agent 会外出采矿、从世界中收集原料。
- **生产** —— agent 会在工作站（铁炉、铁砧、磨坊、面包房、炭窑等）上沿多层配方链劳作，把矿石和作物加工成金属锭、部件、工具和食物。配方是数据驱动的 *reaction*，且每次制造都由服务端权威裁定：会掷出失败概率和品质结果，产出从不保证。
- **技能与熟练度** —— 每个角色在各个行当（采矿、冶炼、锻造、磨粉、烹饪等）上都持有 0–100 的熟练度，它决定制造的成功率、产出品质，以及技能本身随练习成长的速度。知识通过可被阅读、学习的技能书在镇上扩散。
- **交易** —— agent 会买卖自己生产和所需的东西，于是一套活的经济便从小镇真实的产出中涌现出来。

玩家与 agent 共用同一套系统，因此这个小镇开箱即可支撑真正的**生存**与**模拟经营**玩法。

### 路线图

除上述系统外，规划中的主要系统有：

- **魔法** —— 用自然语言描述一件物品或一个法术，由 LLM 生成沙箱化 Lua，变成世界中可用的对象，靠 mana 代价来平衡，而非靠设计师白名单。知识本身也是实体：法术书可被阅读、传授、逆向工程、买卖与盗窃。
- **战斗** —— 哈利波特式的魔杖对战，真 3D 弹道、躺地闪避、掩体格挡，由行为树 NPC AI 驱动。
- **DM 剧情** —— 一个 LLM 扮演的"地下城主"（Dungeon Master），根据玩家和 NPC 的行为，把动态任务、事件和涌现式剧情编织进小镇，支撑剧情解谜玩法。

完整设计见 [`docs/design-doc.md`](docs/design-doc.md)，落地实现相关的笔记见 [`docs/architecture/`](docs/architecture/)。

## 仓库里有什么

- 客户端 / headless runtime / UI / 世界模拟 / 农耕 / 制造 / 商业 / 本地交互系统的 Godot 4.6 工程。
- 使用 Fastify、Redis、SQLite，并通过 WebSocket 连接 Godot runtime 的 Node.js 后端。
- 负责事件驱动的 NPC 思考、记忆、prompt 上下文和 action 提交的 agent worker / runtime 代码。
- 种子数据、中文本地化、架构笔记和开发脚本。

## 目录结构

```text
src/        Godot 玩法、UI、runtime/client 逻辑、模拟系统
assets/     工程自有或生成的资产，以及 Godot 资源包装
data/       游戏机制、配方、本地化和资源定义
backend/    Node.js 后端、worker、SQLite schema、agent runtime
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
- Docker（仅当你希望开发脚本帮你启动 Redis 时需要）。
- Redis，可本地运行在 `127.0.0.1:6379`，或通过 Docker Compose 启动。

可选的 agent 提供商需要在 `backend/.env` 中配置 API key。不要提交真实的 `.env` 文件。

## 搭建

```bash
git clone <repo-url>
cd ai-games

./scripts/install-sqlite-gdextension
./scripts/install-lua-gdextension
./scripts/dev setup
```

`./scripts/dev setup` 会在需要时把 `backend/.env.example` 复制为 `backend/.env`，安装后端依赖，并确认 Redis 可达。

如果 Godot 没有安装在 macOS 默认应用路径，且 `PATH` 上也没有 `godot` 命令，请设置：

```bash
export GODOT_BIN=/path/to/Godot
```

## 本地运行

启动后端 gateway 和 worker：

```bash
./scripts/dev all
```

在另一个终端启动权威 Godot runtime：

```bash
./scripts/dev server --INIT
```

在第三个终端启动玩家客户端：

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
docker compose up -d
pnpm install
pnpm dev
```

后端职责与协议细节见 `backend/README.md`。

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
