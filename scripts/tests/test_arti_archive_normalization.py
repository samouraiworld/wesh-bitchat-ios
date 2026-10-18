"""Synthetic contracts for BSD archive TOC alignment normalization."""

import importlib.util
from pathlib import Path
import stat
import struct
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "localPackages/Arti/normalize-archive.py"
SPEC = importlib.util.spec_from_file_location("arti_archive_normalization", SCRIPT)
normalizer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(normalizer)


def member(name, content):
    encoded = name.encode()
    name_size = (len(encoded) + 7) // 8 * 8
    payload = encoded.ljust(name_size, b"\0") + content
    header = (f"#1/{name_size}".ljust(16) + "0".ljust(12) + "0".ljust(6) +
              "0".ljust(6) + "644".ljust(8) + str(len(payload)).ljust(10) + "`\n").encode()
    return header + payload + (b"\n" if len(payload) % 2 else b"")


def archive(tail=b"ABCD", name="__.SYMDEF SORTED", symbol=b"_fn\0"):
    # One referenced symbol needs 4 bytes; the string area rounds up to 8.
    strings = symbol + tail
    placeholder = struct.pack("<III", 8, 0, 0) + struct.pack("<I", len(strings)) + strings
    toc = member(name, placeholder)
    object_offset = 8 + len(toc)
    toc = member(name, struct.pack("<III", 8, 0, object_offset) +
                 struct.pack("<I", len(strings)) + strings)
    object_bytes = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x01000007, 3, 1, 0, 0, 0, 0) + b"synthetic-code"
    data = b"!<arch>\n" + toc + member("fixture.o", object_bytes)
    payload_start = 8 + 60 + 16
    return data, payload_start, object_offset, object_bytes


def fat(slices, wide=False, endian=">"):
    magic = {(">", False): b"\xca\xfe\xba\xbe", ("<", False): b"\xbe\xba\xfe\xca",
             (">", True): b"\xca\xfe\xba\xbf", ("<", True): b"\xbf\xba\xfe\xca"}[endian, wide]
    entry_size = 32 if wide else 20
    offset = (8 + len(slices) * entry_size + 7) // 8 * 8
    entries, payload, locations = [], b"", []
    for index, data in enumerate(slices):
        locations.append(offset)
        values = (0x01000007 + index, 3, offset, len(data), 3)
        entries.append(struct.pack(endian + ("IIQQII" if wide else "IIIII"),
                                   *values, *([0] if wide else [])))
        padded = data + b"\0" * (-len(data) % 8)
        payload += padded
        offset += len(padded)
    header = magic + struct.pack(endian + "I", len(slices)) + b"".join(entries)
    return header.ljust(locations[0], b"\0") + payload, locations


class ArchiveNormalizationTests(unittest.TestCase):
    def test_thin_changes_only_unreferenced_tail_and_preserves_objects_and_references(self):
        data, toc, object_offset, object_bytes = archive()
        output = normalizer.normalize_bytes(data)
        expected = bytearray(data)
        expected[toc + 20:toc + 24] = b"\0" * 4
        self.assertEqual(output, bytes(expected))
        self.assertEqual(output[object_offset:], data[object_offset:])
        self.assertIn(object_bytes, output)
        self.assertEqual(output[toc:toc + 20], data[toc:toc + 20])

    def test_idempotent_for_sorted_and_unsorted_toc(self):
        for name in ("__.SYMDEF", "__.SYMDEF SORTED"):
            data, _, _, _ = archive(name=name)
            once = normalizer.normalize_bytes(data)
            self.assertEqual(normalizer.normalize_bytes(once), once)

    def test_zero_through_seven_alignment_bytes_preserve_every_referenced_string(self):
        for symbol_size in range(2, 10):
            symbol = b"_" + b"x" * (symbol_size - 2) + b"\0"
            padding = b"P" * (-symbol_size % 8)
            data, toc, _, _ = archive(tail=padding, symbol=symbol)
            expected = bytearray(data)
            start = toc + 16 + symbol_size
            expected[start:start + len(padding)] = b"\0" * len(padding)
            with self.subTest(padding=len(padding)):
                self.assertEqual(normalizer.normalize_bytes(data), bytes(expected))

    def test_fat32_and_fat64_both_table_byte_orders_change_only_slice_tails(self):
        first, toc, _, _ = archive()
        second, _, _, _ = archive(tail=b"WXYZ")
        for wide in (False, True):
            for endian in ("<", ">"):
                data, locations = fat([first, second], wide, endian)
                expected = bytearray(data)
                for location in locations:
                    expected[location + toc + 20:location + toc + 24] = b"\0" * 4
                self.assertEqual(normalizer.normalize_bytes(data), bytes(expected))

    def test_rejects_bad_headers_sizes_references_and_strings(self):
        data, toc, object_offset, _ = archive()
        variants = {}
        def changed(label, offset, value):
            modified = bytearray(data)
            modified[offset:offset + len(value)] = value
            variants[label] = bytes(modified)
        changed("header terminator", 8 + 58, b"xx")
        changed("header size", 8 + 48, b"9999999999")
        changed("negative size", 8 + 48, b"-1        ")
        changed("ranlib size", toc, struct.pack("<I", 7))
        changed("object offset", toc + 8, struct.pack("<I", object_offset + 1))
        changed("string reference out of bounds", toc + 4, struct.pack("<I", 8))
        changed("string reference inside name", toc + 4, struct.pack("<I", 1))
        modified = bytearray(data)
        modified[toc + 4:toc + 8] = struct.pack("<I", 4)
        modified[toc + 16:toc + 24] = b"_x\0\0_z\0\0"
        variants["unreferenced preceding string"] = bytes(modified)
        changed("no symbol terminator", toc + 16, b"abcdefgh")
        changed("empty symbol", toc + 16, b"\0")
        changed("string extent", toc + 12, struct.pack("<I", 7))
        changed("object endianness", object_offset + 60 + 16, b"\xfe\xed\xfa\xcf")
        variants["truncated"] = data[:-1]
        variants["unsupported toc64"] = archive(name="__.SYMDEF_64")[0]
        for label, malformed in variants.items():
            with self.subTest(label=label), self.assertRaises(normalizer.ArchiveError):
                normalizer.normalize_bytes(malformed)

    def test_rejects_extra_unreferenced_string_block(self):
        data, toc, _, _ = archive(tail=b"extra-symbol\0")
        with self.assertRaises(normalizer.ArchiveError):
            normalizer.normalize_bytes(data)

    def test_rejects_corrupt_fat_extents_overlap_alignment_reserved_and_duplicates(self):
        thin, _, _, _ = archive()
        data, locations = fat([thin, thin], wide=True)
        variants = []
        for offset, format_, value in ((8 + 8, ">Q", len(data)),
                                       (8 + 32 + 8, ">Q", locations[0]),
                                       (8 + 24, ">I", 64), (8 + 28, ">I", 1),
                                       (8 + 32, ">I", 0x01000007)):
            modified = bytearray(data)
            struct.pack_into(format_, modified, offset, value)
            variants.append(bytes(modified))
        for malformed in variants:
            with self.assertRaises(normalizer.ArchiveError):
                normalizer.normalize_bytes(malformed)

    def test_invalid_second_slice_never_changes_first_slice_or_file(self):
        thin, _, _, _ = archive()
        malformed = thin[:-1]
        data, _ = fat([thin, malformed])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.a"
            path.write_bytes(data)
            with self.assertRaises(normalizer.ArchiveError):
                normalizer.normalize_file(path)
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_atomic_file_normalization_preserves_mode_and_idempotent_file(self):
        data, _, _, _ = archive()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.a"
            path.write_bytes(data)
            path.chmod(0o640)
            self.assertTrue(normalizer.normalize_file(path))
            self.assertEqual(path.read_bytes(), normalizer.normalize_bytes(data))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
            inode = path.stat().st_ino
            self.assertFalse(normalizer.normalize_file(path))
            self.assertEqual(path.stat().st_ino, inode)

    def test_symlink_is_rejected_without_mutating_target(self):
        data, _, _, _ = archive()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fixture.a"
            target.write_bytes(data)
            link = Path(directory) / "linked.a"
            link.symlink_to(target)
            with self.assertRaises(normalizer.ArchiveError):
                normalizer.normalize_file(link)
            self.assertEqual(target.read_bytes(), data)
            self.assertTrue(link.is_symlink())


if __name__ == "__main__":
    unittest.main()
