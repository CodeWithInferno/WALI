#!/usr/bin/env python3
"""Exercise Finder metadata without mounting an image or calling Finder."""

import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "wali_dmg_metadata", ROOT / "scripts" / "package-dmg-metadata.py"
)
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)


def tree_header_offset(data):
    """Resolve DSDB through the Buddy directory, independently of writer offsets."""
    allocator = struct.unpack_from(">I", data, 8)[0] + 4
    block_count = struct.unpack_from(">I", data, allocator)[0]
    addresses = struct.unpack_from(">" + "I" * block_count, data, allocator + 8)
    position = allocator + 8 + ((block_count + 255) & ~255) * 4
    entry_count = struct.unpack_from(">I", data, position)[0]
    position += 4
    for _ in range(entry_count):
        length = data[position]
        position += 1
        name = data[position:position + length]
        position += length
        block_id = struct.unpack_from(">I", data, position)[0]
        position += 4
        if name == b"DSDB":
            return (addresses[block_id] & ~0x1F) + 4
    raise AssertionError("Finder allocator has no DSDB entry")


class FinderMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="wali-dmg-metadata-test-")
        self.addCleanup(self.directory.cleanup)
        self.volume = Path(self.directory.name)
        self.store = self.volume / ".DS_Store"
        # Alias bytes are opaque to the B-tree format. No native alias APIs or
        # live wallpaper/Finder stores participate in these fixture tests.
        with patch.object(metadata, "new_alias", return_value=b"fixture-alias"):
            metadata.write_layout(self.volume)

    def test_writer_uses_zero_internal_levels_for_single_leaf(self):
        data = self.store.read_bytes()
        _, levels, records, nodes, _ = struct.unpack_from(
            ">IIIII", data, tree_header_offset(data)
        )
        # DSStoreFormat's B-Tree section defines this as internal levels,
        # not the count of all levels: a root leaf has zero internal levels.
        self.assertEqual(nodes, 1)
        self.assertEqual(levels, 0)
        self.assertEqual(len(metadata.read_layout(self.store)), records)

    def test_reader_rejects_nonzero_internal_levels_for_leaf(self):
        data = bytearray(self.store.read_bytes())
        struct.pack_into(">I", data, tree_header_offset(data) + 4, 1)
        self.store.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "zero internal levels"):
            metadata.read_layout(self.store)

    def test_image_icon_view_includes_background_color_components(self):
        entries = metadata.read_layout(self.store)
        icons = plistlib.loads(entries[(".", b"icvp")])
        self.assertEqual(icons["backgroundType"], 2)
        # dmgbuild retains these real-valued fields even for image backgrounds;
        # Finder may ignore the icon-view settings when they are absent.
        for channel in ("Red", "Green", "Blue"):
            with self.subTest(channel=channel):
                value = icons.get("backgroundColor" + channel)
                self.assertIs(type(value), float)
                self.assertEqual(value, 1.0)

    def test_verifier_rejects_missing_background_color_component(self):
        (self.volume / "Applications").symlink_to("/Applications")
        (self.volume / ".VolumeIcon.icns").write_bytes(b"fixture-icon")
        (self.volume / ".background").mkdir()
        (self.volume / ".background" / "background.tiff").write_bytes(b"fixture-image")
        data = self.store.read_bytes()
        self.assertEqual(data.count(b"backgroundColorGreen"), 1)
        # Keep the binary plist's offsets intact while removing a required key.
        self.store.write_bytes(data.replace(b"backgroundColorGreen", b"backgroundColorOther"))
        with patch.object(metadata, "resolve_alias", side_effect=AssertionError("Native alias API reached")) as resolve:
            with self.assertRaisesRegex(ValueError, "backgroundColorGreen"):
                metadata.verify_layout(self.volume)
            resolve.assert_not_called()

if __name__ == "__main__":
    unittest.main()
