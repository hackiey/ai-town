# AI Games Backend

Node + TypeScript backend for platform services and the character agent gateway.

## Responsibilities

- HTTP endpoints for health checks and operational/debug introspection (e.g. `/agent-connections`).
- Agent host client for the Godot server's WebSocket protocol — the only channel used for game traffic.
- SQLite for durable game facts, event history, and agent session state.
- The character agent runtime (LLM "brain"), running in-process. The gateway and runtime talk over an in-process event bus (`plugins/message-bus.ts`) — no Redis, no second process.

Godot still executes high-level character actions inside the world: navigation, animation, collision, combat, and local interaction checks.

## Quick Start

```bash
cd backend
cp .env.example .env
pnpm install
pnpm dev
```

This is a single Node process — gateway + agent runtime + `/debug` page — with no external services (SQLite is a local file). To launch the Godot server alongside it in one command, use `../scripts/dev all`.

Health checks:

```bash
curl http://127.0.0.1:3000/health
curl http://127.0.0.1:3000/ready
```

List connected Godot agent connections:

```bash
curl http://127.0.0.1:3000/agent-connections
```

Send a test action through the Godot agent protocol with `action.request`.

## Godot Agent Protocol

The backend connects to the Godot server:

```text
ws://127.0.0.1:3100/agent-host
```

Server to Godot:

- `runtime.accepted`
- `action.submit`
- `pong`
- `error`

Godot to server:

- `runtime.heartbeat`
- `action.ack`
- `action.request` — Godot-side dispatch of player/debug actions; payload is `{ characterId, action, target?, reason?, priority?, expiresAt?, preempt? }`. Backend invokes the same `submitAction` path as the agent runtime; failures come back as `error`.
- `player.command`
- `world.event`
- `ping`

Current Godot runtime integration has deliberate temporary pieces for MVP validation, especially direct movement fallback and hardcoded local runtime config. See `../docs/tech-doc.md` section 7 before treating it as production behavior.

## Action Lifecycle

Action records are written to `action_log` for observability. Godot owns action legality, serialization, timeout, cancellation, and terminal results.

## Shape of the First Real Integration

1. Godot serves the agent-host WebSocket.
2. Backend connects as agent host and drives `action.submit` actions.
3. Godot reports snapshots/events and owns action execution.
4. Runtime memory lives in `runtime_storage`.
