# AI Games

AI Games is an experimental Godot + TypeScript simulation game about a living town, persistent world state, and LLM-driven character agents. The current codebase is a prototype/research workbench rather than a packaged game release.

## What Is Here

- Godot 4.6 project for the client, headless runtime, UI, world simulation, farming, crafting, commerce, and local interaction systems.
- Node.js backend using Fastify, Redis, SQLite, and WebSocket links to the Godot runtime.
- Agent worker/runtime code for event-driven NPC thinking, memory, prompt context, and action submission.
- Seed data, Chinese localization, architecture notes, and development scripts.

## Repository Layout

```text
src/        Godot gameplay, UI, runtime/client logic, simulation systems
assets/     Project-owned or generated assets plus Godot resource wrappers
data/       Game mechanics, recipes, localization, and resource definitions
backend/    Node.js backend, worker, SQLite schema, agent runtime
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
- Docker, only if you want the dev script to start Redis for you.
- Redis, either local on `127.0.0.1:6379` or via Docker Compose.

Optional agent providers require API keys in `backend/.env`. Do not commit real `.env` files.

## Setup

```bash
git clone <repo-url>
cd ai-games

./scripts/install-sqlite-gdextension
./scripts/install-lua-gdextension
./scripts/dev setup
```

`./scripts/dev setup` copies `backend/.env.example` to `backend/.env` when needed, installs backend dependencies, and ensures Redis is reachable.

If Godot is not installed at the default macOS app path and no `godot` command is on `PATH`, set:

```bash
export GODOT_BIN=/path/to/Godot
```

## Running Locally

Start the backend gateway and worker:

```bash
./scripts/dev all
```

Start the authoritative Godot runtime in another terminal:

```bash
./scripts/dev server --INIT
```

Start a player client in a third terminal:

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
docker compose up -d
pnpm install
pnpm dev
```

See `backend/README.md` for backend responsibilities and protocol details.

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
