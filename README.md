# AI Town

*[English](README.md) | [简体中文](README.zh-CN.md)*

AI Town is a **playable AI town** built with Godot + TypeScript: a hand-built medieval world where the NPCs are autonomous LLM agents that farm, gather, produce, and trade, keeping the town alive whether or not a player is around. You step in to experience survival, management-sim, and story/puzzle play. The current codebase is a prototype/research workbench rather than a packaged game release.

## Features

- **A town that runs itself.** The ~25 NPCs are autonomous LLM agents that farm, gather, craft, and trade on the exact same systems the player uses. Prices, shortages, and rivalries emerge from real supply and demand rather than scripted spawn tables, and the world keeps living whether or not you're online.
- **Two-track NPC minds.** Each NPC runs a fast reactive track that acts within seconds and a slow strategic track that summarizes experience, plans, and maintains working memory — staying responsive *and* goal-directed at a fraction of the cost of reasoning on every step. (More below.)
- **Mechanics you can mod, in Lua.** Recipes, item effects, and world rules live in data and sandboxed Lua instead of engine code, so a new ingredient or a whole new behavior is a script away — no recompile. The sandbox safely runs untrusted, even AI-generated, scripts, which is exactly what makes player-authored magic possible.
- **Crafting with real stakes.** A 0–100 proficiency per trade and each recipe's difficulty decide whether a craft succeeds and how good it turns out, and that quality travels with the item. Proficiency grows with practice and spreads through skillbooks — so specializing, hiring a master, and trading all genuinely pay off.
- **Items that keep their meaning.** Every object is a typed instance with a structured identity — a base template, the identity its crafting reaction stamped on it, and mutable per-instance state — so quality, stacking, containers, shelves, and trade stay consistent across the whole world.

### Two-track agents

Reacting fast and reasoning deeply pull in opposite directions: an LLM call on every step is accurate but slow and expensive, while pure reaction drifts, repeats failures, and recovers poorly. So each NPC runs **two independent LLM sessions at once**:

- a **reactive track** — low latency, no extended thinking, full game toolset — that wakes on events and turns them straight into in-world actions, and
- a **strategic track** — extended reasoning — that periodically summarizes unsummarized events, plans, and writes a short working-memory brief.

The reactive track reads that brief and carries the plan forward cheaply, re-invoking the strategic track only at meaningful events or after enough time passes. The result is an NPC that acts within seconds yet still thinks deeply in the background — without the abort-and-restart machinery a single combined session would need on every event.

### Roadmap

Beyond the systems above, the major planned ones are:

- **Magic** — describe an item or spell in natural language and an LLM generates sandboxed Lua that becomes a usable object, balanced by mana costs rather than designer whitelists. Knowledge is physical: spellbooks can be read, taught, reverse-engineered, bought, and stolen.
- **Combat** — Harry-Potter-style wand duels with real 3D projectiles, dodging, and cover, driven by behavior-tree NPC AI.
- **DM storyline** — an LLM "Dungeon Master" that weaves dynamic quests, events, and emergent storylines into the town in response to what players and NPCs do, for story/puzzle play.

See [`docs/design-doc.md`](docs/design-doc.md) for the full design and [`docs/architecture/`](docs/architecture/) for implementation notes.

## What Is Here

- Godot 4.6 project for the client, headless runtime, UI, world simulation, farming, crafting, commerce, and local interaction systems.
- Node.js backend using Fastify and SQLite, with WebSocket links to the Godot runtime. The agent runtime runs in-process (no Redis, single process).
- Agent runtime code for event-driven NPC thinking, memory, prompt context, and action submission.
- Seed data, Chinese localization, architecture notes, and development scripts.

## Repository Layout

```text
src/        Godot gameplay, UI, runtime/client logic, simulation systems
assets/     Project-owned or generated assets plus Godot resource wrappers
data/       Game mechanics, recipes, localization, and resource definitions
backend/    Node.js backend, SQLite schema, in-process agent runtime
docs/       Design notes and implementation-grounded architecture docs
scripts/    Local setup, Godot launch, and maintenance helpers
addons/     Godot addon manifests; large binaries are installed separately
```

## Important Asset Notice

This repository can be opened as source, but it is not a complete redistributable asset bundle.

- `third-party/` is intentionally ignored. Some tracked scenes reference assets expected under `third-party/polygon-fantasy-kingdom`, `third-party/mixamo`, or other local vendor folders.
- `assets/buildings/*.tscn` are project scene compositions that reference Polygon Fantasy Kingdom resources. They will not render correctly unless the matching licensed asset pack is installed locally.
- Generated or downloaded image/sprite assets under `assets/sprites/` must be reviewed before publishing a release build. The code license does not automatically grant public redistribution rights for every asset.
- See `THIRD_PARTY_NOTICES.md` before distributing builds, screenshots, or asset archives.

## Prerequisites

- Godot 4.6 or newer with the Jolt physics backend available.
- Node.js 22 or newer.
- pnpm 9.x.

No external services are required — the backend is a single Node process and state lives in a local SQLite file.

Optional agent providers require API keys in `backend/.env`. Do not commit real `.env` files.

## Setup

```bash
git clone <repo-url>
cd ai-town

./scripts/install-sqlite-gdextension
./scripts/install-lua-gdextension
./scripts/dev setup
```

`./scripts/dev setup` copies `backend/.env.example` to `backend/.env` when needed and installs backend dependencies.

If Godot is not installed at the default macOS app path and no `godot` command is on `PATH`, set:

```bash
export GODOT_BIN=/path/to/Godot
```

## Running Locally

Start the Godot server + backend together (single command; tables are created on first run, backend serves `/debug`):

```bash
./scripts/dev all
```

To archive the current world and start a fresh one, add `--INIT` (old `state.db` is moved to `backend/data/archive/`):

```bash
./scripts/dev all --INIT
```

Start a player client in another terminal:

```bash
./scripts/dev client
```

Useful checks:

```bash
./scripts/dev status
curl http://127.0.0.1:3000/health
curl http://127.0.0.1:3000/ready
```

## Backend Only

```bash
cd backend
cp .env.example .env
pnpm install
pnpm dev
```

This is a single process — gateway + agent runtime + `/debug` page — with no external services. See `backend/README.md` for backend responsibilities and protocol details.

## Secrets And Local Data

The following must stay local:

- `backend/.env`
- API keys such as `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DASHSCOPE_API_KEY`, or provider-specific equivalents
- `backend/data/state.db` and archived runtime databases
- local debug logs, generated backend `dist/`, Godot `.godot/`, and local agent/editor settings

Before making a public release, run:

```bash
gitleaks detect --source . --redact=100 --verbose --no-banner
gitleaks dir . --redact=100 --verbose --no-banner
```

If a real key ever appears in Git history, rotate it with the provider even after rewriting history.

## Documentation

- `docs/architecture/system-architecture.md` is the best technical entrypoint.
- `docs/architecture/README.md` indexes architecture docs.
- `docs/tech-doc.md` contains older runtime notes and implementation caveats.

## License

Code and documentation are licensed under the MIT License. Assets and third-party packages may have separate terms. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
