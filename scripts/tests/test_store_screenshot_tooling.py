import binascii
import importlib.util
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("validate_store_screenshots", ROOT / "scripts" / "validate_store_screenshots.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)


def png(width: int = 1320, height: int = 2868, metadata: bool = False) -> bytes:
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    scanline = b"\0" + b"\0\0\0" * width
    image = zlib.compress(scanline * height, level=9)
    optional = chunk(b"tEXt", b"owner=not-allowed") if metadata else b""
    return MODULE.PNG_SIGNATURE + chunk(b"IHDR", header) + optional + chunk(b"IDAT", image) + chunk(b"IEND", b"")


class StoreScreenshotToolingTests(unittest.TestCase):
    candidate = "a" * 40

    def create_set(self, root: Path) -> None:
        for path in MODULE.expected_files(root):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(png())

    def test_complete_set_produces_manifest_with_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            manifest = MODULE.validate_set(root, self.candidate)
            self.assertEqual(len(manifest["screenshots"]), 14)
            self.assertTrue(manifest["syntheticFixturesOnly"])
            self.assertTrue(all(len(item["sha256"]) == 64 for item in manifest["screenshots"]))

    def test_wrong_dimensions_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            MODULE.expected_files(root)[0].write_bytes(png(width=1290))
            with self.assertRaisesRegex(MODULE.ValidationError, "dimensions"):
                MODULE.validate_set(root, self.candidate)

    def test_text_metadata_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            MODULE.expected_files(root)[0].write_bytes(png(metadata=True))
            with self.assertRaisesRegex(MODULE.ValidationError, "sensitive metadata"):
                MODULE.validate_set(root, self.candidate)

    def test_sensitive_metadata_is_stripped_without_reencoding_pixels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "capture.png"
            original = png(metadata=True)
            original_idat = original[original.index(b"IDAT") + 4 : original.index(b"IEND") - 8]
            target.write_bytes(original)

            MODULE.strip_sensitive_metadata(target)

            sanitized = target.read_bytes()
            sanitized_idat = sanitized[sanitized.index(b"IDAT") + 4 : sanitized.index(b"IEND") - 8]
            self.assertEqual(original_idat, sanitized_idat)
            self.assertNotIn(b"tEXt", sanitized)
            info = MODULE.inspect_png(target)
            self.assertEqual((info.width, info.height), (1320, 2868))

    def test_missing_screenshots_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            MODULE.expected_files(root)[0].unlink()
            with self.assertRaisesRegex(MODULE.ValidationError, "missing screenshots"):
                MODULE.validate_set(root, self.candidate)

    def test_unexpected_screenshots_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            (root / "en-US" / "08-extra.png").write_bytes(png())
            with self.assertRaisesRegex(MODULE.ValidationError, "unexpected screenshots"):
                MODULE.validate_set(root, self.candidate)

    def test_corrupt_chunk_crc_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            target = MODULE.expected_files(root)[0]
            corrupted = bytearray(target.read_bytes())
            corrupted[-1] ^= 1
            target.write_bytes(corrupted)
            with self.assertRaisesRegex(MODULE.ValidationError, "invalid CRC"):
                MODULE.validate_set(root, self.candidate)

    def test_candidate_commit_must_be_exact_sha(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            with self.assertRaisesRegex(MODULE.ValidationError, "Git SHA"):
                MODULE.validate_set(root, "main")


if __name__ == "__main__":
    unittest.main()
