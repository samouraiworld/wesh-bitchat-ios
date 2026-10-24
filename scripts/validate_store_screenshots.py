#!/usr/bin/env python3
"""Validate the deterministic iOS App Store screenshot set and write its manifest."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
EXPECTED_WIDTH = 1320
EXPECTED_HEIGHT = 2868
LOCALES = ("en-US", "fr-FR")
SCENES = (
    "01-home-peers",
    "02-public-room",
    "03-synthetic-qr",
    "04-verified-private",
    "05-unverified-requests",
    "06-frozen-erase",
    "07-internet-disabled",
)
SENSITIVE_CHUNKS = {b"eXIf", b"iTXt", b"tEXt", b"tIME", b"zTXt"}


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class PNGInfo:
    width: int
    height: int
    chunks: tuple[str, ...]


def inspect_png(path: Path) -> PNGInfo:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValidationError(f"{path}: not a PNG")

    offset = len(PNG_SIGNATURE)
    width = height = None
    chunks: list[str] = []
    saw_iend = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValidationError(f"{path}: truncated PNG chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise ValidationError(f"{path}: truncated {chunk_type!r} chunk")
        chunks.append(chunk_type.decode("ascii", errors="replace"))
        payload = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : end])[0]
        actual_crc = binascii.crc32(chunk_type + payload) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValidationError(f"{path}: invalid CRC for {chunk_type!r}")
        if chunk_type in SENSITIVE_CHUNKS:
            raise ValidationError(f"{path}: sensitive metadata chunk {chunk_type.decode('ascii')}")
        if chunk_type == b"IHDR":
            if width is not None or length != 13:
                raise ValidationError(f"{path}: invalid IHDR")
            width, height = struct.unpack(">II", payload[:8])
        if chunk_type == b"IEND":
            if length != 0:
                raise ValidationError(f"{path}: invalid IEND")
            saw_iend = True
            if end != len(data):
                raise ValidationError(f"{path}: trailing bytes after IEND")
        offset = end

    if width is None or height is None or not saw_iend:
        raise ValidationError(f"{path}: incomplete PNG")
    return PNGInfo(width=width, height=height, chunks=tuple(chunks))


def strip_sensitive_metadata(path: Path) -> None:
    """Remove metadata chunks without decoding or re-encoding image pixels."""
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValidationError(f"{path}: not a PNG")

    output = bytearray(PNG_SIGNATURE)
    offset = len(PNG_SIGNATURE)
    saw_iend = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValidationError(f"{path}: truncated PNG chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise ValidationError(f"{path}: truncated {chunk_type!r} chunk")
        payload = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : end])[0]
        actual_crc = binascii.crc32(chunk_type + payload) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValidationError(f"{path}: invalid CRC for {chunk_type!r}")
        if chunk_type not in SENSITIVE_CHUNKS:
            output.extend(data[offset:end])
        if chunk_type == b"IEND":
            if length != 0:
                raise ValidationError(f"{path}: invalid IEND")
            saw_iend = True
            if end != len(data):
                raise ValidationError(f"{path}: trailing bytes after IEND")
        offset = end

    if not saw_iend:
        raise ValidationError(f"{path}: incomplete PNG")
    path.write_bytes(output)


def expected_files(root: Path) -> list[Path]:
    return [root / locale / f"{scene}.png" for locale in LOCALES for scene in SCENES]


def validate_set(root: Path, candidate_commit: str) -> dict[str, object]:
    if len(candidate_commit) != 40 or any(character not in "0123456789abcdef" for character in candidate_commit):
        raise ValidationError("candidate commit must be a lowercase 40-character Git SHA")

    expected = expected_files(root)
    missing = [path.relative_to(root).as_posix() for path in expected if not path.is_file()]
    actual = sorted(path.relative_to(root).as_posix() for path in root.rglob("*.png"))
    wanted = sorted(path.relative_to(root).as_posix() for path in expected)
    unexpected = sorted(set(actual) - set(wanted))
    if missing:
        raise ValidationError("missing screenshots: " + ", ".join(missing))
    if unexpected:
        raise ValidationError("unexpected screenshots: " + ", ".join(unexpected))

    entries: list[dict[str, object]] = []
    for path in expected:
        info = inspect_png(path)
        if (info.width, info.height) != (EXPECTED_WIDTH, EXPECTED_HEIGHT):
            raise ValidationError(
                f"{path}: dimensions {info.width}x{info.height}; "
                f"expected {EXPECTED_WIDTH}x{EXPECTED_HEIGHT}"
            )
        relative = path.relative_to(root).as_posix()
        entries.append(
            {
                "file": relative,
                "locale": path.parent.name,
                "scene": path.stem,
                "width": info.width,
                "height": info.height,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "pngChunks": list(info.chunks),
            }
        )

    return {
        "schemaVersion": 1,
        "platform": "iOS",
        "candidateVersion": "1.0.0 (107)",
        "candidateSourceCommit": candidate_commit,
        "deviceClass": "iPhone 6.9-inch",
        "dimensions": {"width": EXPECTED_WIDTH, "height": EXPECTED_HEIGHT},
        "syntheticFixturesOnly": True,
        "networkAndBluetoothServices": "not constructed",
        "screenshots": entries,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--strip-sensitive-metadata", action="store_true")
    parser.add_argument("--write-manifest", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.strip_sensitive_metadata:
            for path in expected_files(args.root.resolve()):
                strip_sensitive_metadata(path)
        manifest = validate_set(args.root.resolve(), args.candidate_commit)
    except (OSError, ValidationError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.write_manifest:
        path = args.root.resolve() / "manifest.json"
        path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"OK: validated 14 synthetic screenshots and wrote {path}")
    else:
        print("OK: validated 14 synthetic screenshots (1320x2868, no sensitive PNG metadata)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
