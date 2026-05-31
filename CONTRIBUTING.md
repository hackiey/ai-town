# Contributing

AI Games is still a fast-moving prototype, so contributions should favor small, well-scoped changes that keep the runtime behavior easy to inspect.

## Development Setup

```bash
./scripts/install-sqlite-gdextension
./scripts/install-lua-gdextension
./scripts/dev setup
```

Run the backend type check before opening a pull request:

```bash
cd backend
pnpm lint
```

For Godot changes, run a headless syntax/import check when possible:

```bash
godot --headless --path . --check-only --quit
```

If your Godot binary is not named `godot`, set `GODOT_BIN` and use `./scripts/dev`.

## Pull Request Expectations

- Keep unrelated refactors out of feature or bug-fix PRs.
- Do not commit `backend/.env`, SQLite state databases, logs, `.godot/`, generated backend `dist/`, or local agent/editor settings.
- Update `README.md`, `backend/.env.example`, or docs when changing setup, runtime flags, provider configuration, or public APIs.
- Treat `backend/data/town/*.json` and localization files as public seed data. Do not add private notes, test transcripts, or real user data.
- Call out third-party asset requirements when adding scenes that reference ignored vendor folders.

## Secret Scanning

Run this before publishing or opening a broad PR:

```bash
gitleaks detect --source . --redact=100 --verbose --no-banner
gitleaks dir . --redact=100 --verbose --no-banner
```

If a secret is found, remove it from the change and rotate it with the provider if it may have left your machine.
