#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageChops


CRAFTPIX_DIR = Path(__file__).resolve().parents[2]
MODULE_PATH = CRAFTPIX_DIR / "scripts/export_character_psd.py"
SPEC = importlib.util.spec_from_file_location("export_character_psd", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


class CharacterPsdExporterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.psd = EXPORTER.load_psd(EXPORTER.DEFAULT_PSD)
        cls.preset_path = (
            EXPORTER.CRAFTPIX_DIR
            / "scripts/presets/craftpix-net-254170-rpg-character-sprite-sheet-generator/example_pale_adventurer.json"
        )
        cls.preset = json.loads(cls.preset_path.read_text(encoding="utf-8"))

    def test_expected_sheet_and_layer_catalog(self) -> None:
        self.assertEqual((144, 192), (self.psd.width, self.psd.height))
        catalog = EXPORTER.layer_catalog(self.psd)
        self.assertIn("Pale", catalog["Skin Tone"])
        self.assertIn("Short Brown", catalog["Hair"])
        self.assertIn("Sheathed Sword", catalog["Equipments"])

    def test_render_is_rgba_non_empty_and_deterministic(self) -> None:
        first = EXPORTER.render_preset(self.psd, self.preset)
        second = EXPORTER.render_preset(self.psd, self.preset)
        self.assertEqual("RGBA", first.mode)
        self.assertEqual((144, 192), first.size)
        self.assertIsNotNone(first.getbbox())
        self.assertEqual(first.tobytes(), second.tobytes())

    def test_manual_composite_matches_psd_visible_preview(self) -> None:
        visible_preset = {
            "include_top_level": ["Shadow"],
            "groups": {
                "Skin Tone": "Pale",
                "Down Vest": "Red Trousers",
                "Eyebrows": "Black",
            },
        }
        rendered = EXPORTER.render_preset(self.psd, visible_preset)
        embedded = self.psd.topil().convert("RGBA")
        background = EXPORTER.Image.new("RGBA", embedded.size, "white")
        embedded_visible = EXPORTER.Image.alpha_composite(background, embedded)
        rendered_visible = EXPORTER.Image.alpha_composite(background, rendered)
        difference = ImageChops.difference(embedded_visible, rendered_visible)
        max_channel_difference = max(extrema[1] for extrema in difference.getextrema())
        self.assertLessEqual(max_channel_difference, 1)

    def test_split_frames_writes_twelve_48px_images(self) -> None:
        sheet = EXPORTER.render_preset(self.psd, self.preset)
        with tempfile.TemporaryDirectory() as temp_dir:
            outputs = EXPORTER.split_frames(sheet, Path(temp_dir))
            self.assertEqual(12, len(outputs))
            self.assertEqual(
                "down_0_step_a.png",
                outputs[0].name,
            )
            for output in outputs:
                with EXPORTER.Image.open(output) as frame:
                    self.assertEqual((48, 48), frame.size)

    def test_component_library_exports_semantic_parts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            catalog = EXPORTER.export_component_library(
                self.psd,
                Path(temp_dir),
                "res://test/components",
                self.preset,
            )
            groups = {group["id"]: group for group in catalog["groups"]}
            self.assertIn("skin_tone", groups)
            self.assertIn("accessories", groups)
            self.assertTrue(groups["skin_tone"]["required"])
            self.assertTrue(groups["accessories"]["multi"])
            self.assertEqual([144, 192], catalog["sheet_size"])
            self.assertEqual([48, 48], catalog["frame_size"])
            selected = catalog["default_appearance"]["groups"]
            self.assertEqual(["skin_tone/pale"], selected["skin_tone"])
            self.assertEqual(["hair/short_brown"], selected["hair"])
            self.assertNotIn(
                "Matiz/Saturação 1 cópia",
                [part["name"] for part in groups["hair"]["parts"]],
            )
            part_path = Path(temp_dir) / "skin_tone/pale.png"
            self.assertTrue(part_path.is_file())
            with EXPORTER.Image.open(part_path) as component:
                self.assertEqual((144, 192), component.size)
                self.assertIsNotNone(component.getbbox())

    def test_exported_components_recompose_the_preset_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            catalog = EXPORTER.export_component_library(
                self.psd,
                output_dir,
                "res://test/components",
                self.preset,
            )
            selected_ids = {
                part_id
                for part_ids in catalog["default_appearance"]["groups"].values()
                for part_id in part_ids
            }
            selected_parts = sorted(
                (
                    part
                    for group in catalog["groups"]
                    for part in group["parts"]
                    if part["id"] in selected_ids
                ),
                key=lambda part: part["order"],
            )
            recomposed = Image.new("RGBA", (self.psd.width, self.psd.height))
            for part in selected_parts:
                with Image.open(output_dir / f"{part['id']}.png") as component:
                    recomposed = Image.alpha_composite(recomposed, component.convert("RGBA"))
            expected = EXPORTER.render_preset(self.psd, self.preset)
            self.assertIsNone(ImageChops.difference(expected, recomposed).getbbox())


if __name__ == "__main__":
    unittest.main()
