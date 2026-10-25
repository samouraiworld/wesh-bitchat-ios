#!/usr/bin/env python3
"""Validate real-view captures without claiming a binding to a distributed candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

from validate_store_screenshots import (
    EXPECTED_HEIGHT, EXPECTED_WIDTH, LOCALES, ValidationError,
    inspect_png, strip_sensitive_metadata,
)

SCENES = ("01-welcome", "02-bluetooth", "03-settings", "04-internet-off", "05-about")
SOURCE_FILES = (
    "bitchat/BitchatApp.swift",
    "bitchat/ScreenshotCapture/ScreenshotCaptureRootView.swift",
    "bitchat/Views/Wesh/WeshRootView.swift",
    "bitchat/Views/Wesh/WeshDesignSystem.swift",
    "bitchat/Views/Wesh/WeshIdentity.swift",
    "bitchat/Views/Wesh/Pave/PaveFluo.swift",
    "bitchat/Views/Wesh/Pave/WeshTokens.swift",
    "bitchat/Views/Wesh/Pave/PaveOnboardingFlow.swift",
    "bitchat/Views/Wesh/Pave/PaveSettingsScreen.swift",
    "bitchat/Views/Wesh/Pave/PaveHoldToErase.swift",
    "bitchat/Views/Wesh/Pave/PaveConnexionSheet.swift",
    "bitchat/Views/Wesh/Pave/Pave.xcstrings",
    "Configs/Screenshot.xcconfig",
    "scripts/capture_store_screenshots.sh",
)


def expected_files(root: Path) -> list[Path]:
    return [root / locale / f"{scene}.png" for locale in LOCALES for scene in SCENES]


def validate_set(root: Path, render_commit: str, source_root: Path) -> dict[str, object]:
    if not re.fullmatch(r"[0-9a-f]{40}", render_commit):
        raise ValidationError("render commit must be an exact lowercase Git SHA")
    wanted = expected_files(root)
    missing = [str(path.relative_to(root)) for path in wanted if not path.is_file()]
    unexpected = sorted(set(root.rglob("*.png")) - set(wanted))
    if missing:
        raise ValidationError("missing screenshots: " + ", ".join(missing))
    if unexpected:
        raise ValidationError("unexpected screenshots: " + ", ".join(str(path.relative_to(root)) for path in unexpected))
    entries = []
    for path in wanted:
        info = inspect_png(path)
        if (info.width, info.height) != (EXPECTED_WIDTH, EXPECTED_HEIGHT):
            raise ValidationError(f"{path}: unexpected dimensions {info.width}x{info.height}")
        entries.append({
            "file": path.relative_to(root).as_posix(), "locale": path.parent.name,
            "scene": path.stem, "width": info.width, "height": info.height,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "pngChunks": list(info.chunks),
        })
    sources = [{"file": name, "sha256": hashlib.sha256((source_root / name).read_bytes()).hexdigest()}
               for name in SOURCE_FILES]
    return {
        "schemaVersion": 2, "platform": "iOS",
        "captureKind": "production-views-with-synthetic-data",
        "renderSourceCommit": render_commit,
        "candidateBinding": {"status": "unbound", "reason": "Requires frozen candidate and separate fidelity review"},
        "visualReview": "pending", "deviceClass": "iPhone 6.9-inch",
        "dimensions": {"width": EXPECTED_WIDTH, "height": EXPECTED_HEIGHT},
        "syntheticFixturesOnly": True,
        "networkAndBluetoothServices": "not constructed",
        "productionSources": sources, "screenshots": entries,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--render-commit", required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--strip-sensitive-metadata", action="store_true")
    parser.add_argument("--write-manifest", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.strip_sensitive_metadata:
            for path in expected_files(args.root.resolve()):
                strip_sensitive_metadata(path)
        manifest = validate_set(args.root.resolve(), args.render_commit, args.source_root.resolve())
        if args.write_manifest:
            (args.root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValidationError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("OK: 10 production-view PNGs validated; visual review and candidate binding pending")
    return 0


if __name__ == "__main__":
    sys.exit(main())
