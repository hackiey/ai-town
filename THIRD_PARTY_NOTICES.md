# Third-Party Notices

This file documents known third-party and separately licensed material used by the project. It is not legal advice; verify licenses before publishing a public build or asset bundle.

## Source Dependencies

- Backend npm dependencies are listed in `backend/package.json` and locked in `backend/pnpm-lock.yaml`.
- Godot itself is distributed under its own license by the Godot Engine project: https://godotengine.org/license

## Godot Addons

- `addons/lua-gdextension/` is Lua GDExtension by gilzoide. The addon is MIT licensed and includes its own `addons/lua-gdextension/LICENSE`: https://github.com/gilzoide/lua-gdextension
- `addons/godot-sqlite/` stores the Godot-SQLite manifest. Native binaries under `addons/godot-sqlite/bin/` are ignored and installed with `./scripts/install-sqlite-gdextension`. Godot's Asset Library lists Godot-SQLite 4.7 as MIT licensed: https://godotengine.org/asset-library/asset/1686

## Local Vendor Assets

`third-party/` is intentionally ignored and is expected to contain assets acquired separately by each developer.

Known local references include:

- `third-party/polygon-fantasy-kingdom/` for Polygon Fantasy Kingdom / Synty-style scene assets.
- `third-party/mixamo/` for animation FBX files.
- `third-party/particle-fx/` for local particle effect assets.

Do not redistribute these folders unless their licenses explicitly allow it.

## Tracked Game Assets

Tracked files under `assets/` may include project-owned resources, generated images, extracted scene wrappers, or downloaded/generated prototypes. Before a public release, review:

- `assets/buildings/` scene compositions that reference ignored vendor assets.
- `assets/sprites/characters/player/` generated character sprites.
- `assets/sprites/maps/` generated map images.
- `assets/sprites/props/` downloaded or generated prop images.

If an asset's provenance is unclear, either remove it from the public release or add a precise license/source note here.

## Release Rule

The MIT license in `LICENSE` applies to project code and documentation unless otherwise stated. It does not override third-party asset, model, font, audio, image, or addon licenses.
