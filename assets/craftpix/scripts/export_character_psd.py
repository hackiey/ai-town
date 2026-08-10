#!/usr/bin/env python3
"""Export layered CraftPix character presets from the source PSD.

Usage:
    .venv-psd/bin/python assets/craftpix/scripts/export_character_psd.py list
    .venv-psd/bin/python assets/craftpix/scripts/export_character_psd.py export \
        --preset assets/craftpix/scripts/presets/craftpix-net-254170-rpg-character-sprite-sheet-generator/example_pale_adventurer.json \
        --output assets/craftpix/craftpix-net-254170-rpg-character-sprite-sheet-generator/exported/example_pale_adventurer.png \
        --frames-dir /tmp/example_pale_adventurer_frames

The exporter intentionally composites ordinary pixel layers itself instead of
using PSDImage.composite(). The source file only contains normal, unmasked
pixel layers, so this keeps the dependency small and avoids optional SciPy /
scikit-image compositing dependencies.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

try:
    from PIL import Image
    from psd_tools import PSDImage
except ImportError as exc:  # pragma: no cover - exercised through the CLI.
    print(
        "Missing PSD exporter dependencies. Create an isolated environment and run:\n"
        "  python3 -m venv .venv-psd\n"
        "  .venv-psd/bin/python -m pip install -r assets/craftpix/scripts/requirements-psd.txt\n"
        "Then use .venv-psd/bin/python to run this script.",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


CRAFTPIX_DIR = Path(__file__).resolve().parents[1]
PACK_DIR = (
    CRAFTPIX_DIR / "craftpix-net-254170-rpg-character-sprite-sheet-generator"
)
DEFAULT_PSD = PACK_DIR / "Rpg Character Sprite Sheet Generator.psd"
DEFAULT_COMPONENT_DIR = PACK_DIR / "exported/components"
DEFAULT_COMPONENT_CATALOG = PACK_DIR / "exported/character_components.json"
DEFAULT_COMPONENT_RESOURCE_PREFIX = (
    "res://assets/craftpix/"
    "craftpix-net-254170-rpg-character-sprite-sheet-generator/exported/components"
)
DIRECTIONS = ("down", "left", "right", "up")
FRAME_NAMES = ("step_a", "idle", "step_b")
MULTI_SELECT_GROUPS = {"Accessories", "Equipments"}
REQUIRED_GROUPS = {"Skin Tone", "Down Vest", "Up Vest", "Eyes"}
EXCLUDED_COMPONENTS = {
    ("Hair", "Matiz/Saturação 1 cópia"),
}


class ExportError(RuntimeError):
    """A user-facing preset or PSD validation error."""


def load_psd(path: Path) -> PSDImage:
    if not path.is_file():
        raise ExportError(f"PSD file does not exist: {path}")
    return PSDImage.open(path)


def pixel_layers(group: Iterable[Any]) -> Iterable[Any]:
    for layer in group:
        if layer.is_group():
            yield from pixel_layers(layer)
        elif layer.has_pixels():
            yield layer


def layer_catalog(psd: PSDImage) -> dict[str, list[str]]:
    catalog: dict[str, list[str]] = {}
    for layer in psd:
        if layer.is_group():
            catalog[layer.name] = [child.name for child in pixel_layers(layer)]
    return catalog


def top_level_pixel_layers(psd: PSDImage) -> list[str]:
    return [layer.name for layer in psd if not layer.is_group() and layer.has_pixels()]


def slugify(value: str, fallback: str) -> str:
    normalized = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "_", normalized.lower()).strip("_")
    return slug or fallback


def selectable_layer_records(psd: PSDImage) -> list[dict[str, Any]]:
    """Return every selectable PSD pixel layer in paint order."""
    records: list[dict[str, Any]] = []
    order = 0
    for layer in psd:
        if layer.is_group():
            for child in pixel_layers(layer):
                records.append(
                    {
                        "group": layer.name,
                        "name": child.name,
                        "layer": child,
                        "order": order,
                    }
                )
                order += 1
        elif layer.has_pixels():
            records.append(
                {
                    "group": "",
                    "name": layer.name,
                    "layer": layer,
                    "order": order,
                }
            )
            order += 1
    return records


def normalize_choice(value: Any, group_name: str) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    raise ExportError(
        f"Preset group {group_name!r} must be a layer name or a list of layer names"
    )


def load_preset(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ExportError(f"Preset file does not exist: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ExportError(f"Invalid JSON preset {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ExportError("Preset root must be a JSON object")
    return payload


def selected_layer_paths(
    psd: PSDImage, preset: Mapping[str, Any]
) -> set[tuple[str, ...]]:
    catalog = layer_catalog(psd)
    available_top_level = set(top_level_pixel_layers(psd))
    selected: set[tuple[str, ...]] = set()

    includes = preset.get("include_top_level", [])
    if not isinstance(includes, list) or not all(
        isinstance(item, str) for item in includes
    ):
        raise ExportError("include_top_level must be a list of layer names")
    for layer_name in includes:
        if layer_name not in available_top_level:
            choices = ", ".join(sorted(available_top_level)) or "<none>"
            raise ExportError(
                f"Unknown top-level layer {layer_name!r}. Available: {choices}"
            )
        selected.add((layer_name,))

    groups = preset.get("groups", {})
    if not isinstance(groups, dict):
        raise ExportError("groups must be a JSON object")
    for group_name, raw_choices in groups.items():
        if group_name not in catalog:
            raise ExportError(
                f"Unknown group {group_name!r}. Available: "
                f"{', '.join(sorted(catalog))}"
            )
        for layer_name in normalize_choice(raw_choices, group_name):
            if layer_name not in catalog[group_name]:
                raise ExportError(
                    f"Unknown layer {layer_name!r} in group {group_name!r}. "
                    f"Available: {', '.join(catalog[group_name])}"
                )
            selected.add((group_name, layer_name))

    if not selected:
        raise ExportError("Preset did not select any layers")
    return selected


def apply_opacity(image: Image.Image, opacity: int) -> Image.Image:
    rgba = image.convert("RGBA")
    if opacity >= 255:
        return rgba
    alpha = rgba.getchannel("A")
    alpha = alpha.point([value * opacity // 255 for value in range(256)])
    rgba.putalpha(alpha)
    return rgba


def composite_layer(canvas: Image.Image, layer: Any) -> None:
    if str(layer.blend_mode).split(".")[-1] != "NORMAL":
        raise ExportError(
            f"Unsupported blend mode {layer.blend_mode!s} on layer {layer.name!r}"
        )
    if layer.has_mask():
        raise ExportError(f"Layer masks are not supported: {layer.name!r}")

    image = layer.topil()
    if image is None:
        raise ExportError(f"Could not decode pixel layer: {layer.name!r}")
    image = apply_opacity(image, layer.opacity)

    left, top, right, bottom = tuple(layer.bbox)
    canvas_width, canvas_height = canvas.size
    source_left = max(0, -left)
    source_top = max(0, -top)
    source_right = image.width - max(0, right - canvas_width)
    source_bottom = image.height - max(0, bottom - canvas_height)
    if source_right <= source_left or source_bottom <= source_top:
        return

    clipped = image.crop((source_left, source_top, source_right, source_bottom))
    destination = (max(0, left), max(0, top))
    canvas.alpha_composite(clipped, destination)


def render_preset(psd: PSDImage, preset: Mapping[str, Any]) -> Image.Image:
    selected_paths = selected_layer_paths(psd, preset)
    canvas = Image.new("RGBA", (psd.width, psd.height), (0, 0, 0, 0))
    rendered_paths: set[tuple[str, ...]] = set()

    def record_paths(
        group: Iterable[Any], prefix: tuple[str, ...] = ()
    ) -> Iterable[Any]:
        # psd-tools exposes Photoshop layers in paint order, from the backmost
        # layer to the frontmost layer. Preserve that order when compositing.
        for layer in group:
            path = (*prefix, layer.name)
            if layer.is_group():
                yield from record_paths(layer, path)
            elif path in selected_paths:
                rendered_paths.add(path)
                yield layer

    for layer in record_paths(psd):
        composite_layer(canvas, layer)

    missing = selected_paths - rendered_paths
    if missing:
        formatted = ", ".join("/".join(path) for path in sorted(missing))
        raise ExportError(f"Selected layers were not rendered: {formatted}")
    return canvas


def render_component(psd: PSDImage, layer: Any) -> Image.Image:
    canvas = Image.new("RGBA", (psd.width, psd.height), (0, 0, 0, 0))
    composite_layer(canvas, layer)
    return canvas


def export_component_library(
    psd: PSDImage,
    output_dir: Path,
    resource_prefix: str,
    default_preset: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Export aligned transparent component sheets plus a Godot-readable catalog."""
    output_dir.mkdir(parents=True, exist_ok=True)
    records = selectable_layer_records(psd)
    grouped_records: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        group_name = str(record["group"])
        if group_name and (group_name, str(record["name"])) not in EXCLUDED_COMPONENTS:
            grouped_records.setdefault(group_name, []).append(record)

    groups: list[dict[str, Any]] = []
    part_ids_by_name: dict[tuple[str, str], str] = {}
    used_group_ids: set[str] = set()
    written_paths: set[Path] = set()
    for group_index, (group_name, group_records) in enumerate(grouped_records.items()):
        group_id = slugify(group_name, f"group_{group_index + 1}")
        original_group_id = group_id
        suffix = 2
        while group_id in used_group_ids:
            group_id = f"{original_group_id}_{suffix}"
            suffix += 1
        used_group_ids.add(group_id)

        parts: list[dict[str, Any]] = []
        used_part_slugs: set[str] = set()
        for part_index, record in enumerate(group_records):
            part_name = str(record["name"])
            part_slug = slugify(part_name, f"part_{part_index + 1}")
            original_part_slug = part_slug
            part_suffix = 2
            while part_slug in used_part_slugs:
                part_slug = f"{original_part_slug}_{part_suffix}"
                part_suffix += 1
            used_part_slugs.add(part_slug)
            part_id = f"{group_id}/{part_slug}"
            relative_path = Path(group_id) / f"{part_slug}.png"
            output_path = output_dir / relative_path
            output_path.parent.mkdir(parents=True, exist_ok=True)
            render_component(psd, record["layer"]).save(output_path)
            written_paths.add(output_path.resolve())
            parts.append(
                {
                    "id": part_id,
                    "name": part_name,
                    "path": f"{resource_prefix.rstrip('/')}/{relative_path.as_posix()}",
                    "order": int(record["order"]),
                }
            )
            part_ids_by_name[(group_name, part_name)] = part_id

        groups.append(
            {
                "id": group_id,
                "name": group_name,
                "multi": group_name in MULTI_SELECT_GROUPS,
                "required": group_name in REQUIRED_GROUPS,
                "parts": parts,
            }
        )

    for stale_path in output_dir.rglob("*.png"):
        if stale_path.resolve() not in written_paths:
            stale_path.unlink()
    for directory in sorted(
        (path for path in output_dir.rglob("*") if path.is_dir()),
        reverse=True,
    ):
        if not any(directory.iterdir()):
            directory.rmdir()

    default_groups: dict[str, list[str]] = {}
    if default_preset is not None:
        raw_groups = default_preset.get("groups", {})
        if not isinstance(raw_groups, dict):
            raise ExportError("Default preset groups must be a JSON object")
        group_ids_by_name = {str(group["name"]): str(group["id"]) for group in groups}
        for group_name, raw_choices in raw_groups.items():
            if group_name not in group_ids_by_name:
                continue
            selected_ids: list[str] = []
            for part_name in normalize_choice(raw_choices, group_name):
                part_id = part_ids_by_name.get((group_name, part_name))
                if part_id is not None:
                    selected_ids.append(part_id)
            if selected_ids:
                default_groups[group_ids_by_name[group_name]] = selected_ids

    for group in groups:
        group_id = str(group["id"])
        if group_id not in default_groups and bool(group["required"]) and group["parts"]:
            default_groups[group_id] = [str(group["parts"][0]["id"])]

    return {
        "format": "craftpix_character_components",
        "catalog_id": "craftpix_rpg_48",
        "version": 1,
        "sheet_size": [psd.width, psd.height],
        "frame_size": [psd.width // len(FRAME_NAMES), psd.height // len(DIRECTIONS)],
        "directions": list(DIRECTIONS),
        "frames": list(FRAME_NAMES),
        "groups": groups,
        "default_appearance": {"groups": default_groups},
    }


def split_frames(sheet: Image.Image, frames_dir: Path) -> list[Path]:
    if sheet.width % len(FRAME_NAMES) or sheet.height % len(DIRECTIONS):
        raise ExportError(
            f"Unexpected sheet size {sheet.width}x{sheet.height}; expected a 3x4 grid"
        )
    frame_width = sheet.width // len(FRAME_NAMES)
    frame_height = sheet.height // len(DIRECTIONS)
    frames_dir.mkdir(parents=True, exist_ok=True)
    outputs: list[Path] = []
    for row, direction in enumerate(DIRECTIONS):
        for column, frame_name in enumerate(FRAME_NAMES):
            frame = sheet.crop(
                (
                    column * frame_width,
                    row * frame_height,
                    (column + 1) * frame_width,
                    (row + 1) * frame_height,
                )
            )
            path = frames_dir / f"{direction}_{column}_{frame_name}.png"
            frame.save(path)
            outputs.append(path)
    return outputs


def command_list(args: argparse.Namespace) -> None:
    psd = load_psd(args.psd)
    payload = {
        "canvas": [psd.width, psd.height],
        "frame": [psd.width // 3, psd.height // 4],
        "top_level": top_level_pixel_layers(psd),
        "groups": layer_catalog(psd),
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    print(f"PSD: {args.psd}")
    print(f"Canvas: {psd.width}x{psd.height}; frame: {psd.width // 3}x{psd.height // 4}")
    print("Top-level layers:")
    for layer_name in payload["top_level"]:
        print(f"  - {layer_name}")
    print("Groups:")
    for group_name, choices in payload["groups"].items():
        print(f"  [{group_name}]")
        for layer_name in choices:
            print(f"    - {layer_name}")


def command_export(args: argparse.Namespace) -> None:
    psd = load_psd(args.psd)
    preset = load_preset(args.preset)
    sheet = render_preset(psd, preset)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.output)
    print(f"PASS sheet: {args.output} ({sheet.width}x{sheet.height}, RGBA)")

    if args.frames_dir:
        outputs = split_frames(sheet, args.frames_dir)
        print(f"PASS frames: {args.frames_dir} ({len(outputs)} PNG files)")


def command_export_components(args: argparse.Namespace) -> None:
    psd = load_psd(args.psd)
    default_preset = load_preset(args.default_preset) if args.default_preset else None
    catalog = export_component_library(
        psd,
        args.output_dir,
        args.resource_prefix,
        default_preset,
    )
    args.catalog.parent.mkdir(parents=True, exist_ok=True)
    args.catalog.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    part_count = sum(len(group["parts"]) for group in catalog["groups"])
    print(
        f"PASS components: {args.output_dir} "
        f"({len(catalog['groups'])} groups, {part_count} sheets)"
    )
    print(f"PASS catalog: {args.catalog}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compose 48x48 CraftPix character sprites from a layered PSD"
    )
    parser.add_argument(
        "--psd", type=Path, default=DEFAULT_PSD, help=f"source PSD (default: {DEFAULT_PSD})"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="list all selectable PSD layers")
    list_parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    list_parser.set_defaults(handler=command_list)

    export_parser = subparsers.add_parser("export", help="export one JSON character preset")
    export_parser.add_argument("--preset", type=Path, required=True)
    export_parser.add_argument("--output", type=Path, required=True)
    export_parser.add_argument(
        "--frames-dir",
        type=Path,
        help="also split the sheet into 12 named 48x48 PNG files",
    )
    export_parser.set_defaults(handler=command_export)

    components_parser = subparsers.add_parser(
        "export-components",
        help="export every selectable PSD layer as an aligned transparent sheet",
    )
    components_parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_COMPONENT_DIR,
        help=f"component output directory (default: {DEFAULT_COMPONENT_DIR})",
    )
    components_parser.add_argument(
        "--catalog",
        type=Path,
        default=DEFAULT_COMPONENT_CATALOG,
        help=f"catalog JSON path (default: {DEFAULT_COMPONENT_CATALOG})",
    )
    components_parser.add_argument(
        "--resource-prefix",
        default=DEFAULT_COMPONENT_RESOURCE_PREFIX,
        help="Godot res:// prefix written into the catalog",
    )
    components_parser.add_argument(
        "--default-preset",
        type=Path,
        help="optional preset used only as the editor's initial component selection",
    )
    components_parser.set_defaults(handler=command_export_components)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.handler(args)
    except ExportError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
