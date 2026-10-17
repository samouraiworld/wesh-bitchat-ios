#!/usr/bin/env python3
"""Fail if a Release build could define BITCHAT_DEV_ALLOW_CLEARNET.

That flag compiles Tor enforcement out of TorManager (direct network access).
It is a local development switch and must never reach a Release build.

Static checks (always):
  - Configs/Release.xcconfig, and every xcconfig it includes;
  - Release build configurations in bitchat.xcodeproj/project.pbxproj;
  - Package.swift manifests: a define is only allowed when restricted to
    the debug configuration on the same line.

Dynamic check (CI): `--build-settings FILE` (or `-` for stdin) reads the
output of `xcodebuild -showBuildSettings -configuration Release` and fails if
the flag appears in it.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FLAG = "BITCHAT_DEV_ALLOW_CLEARNET"
INCLUDE = re.compile(r'^\s*#include\??\s+"([^"]+)"', re.MULTILINE)


def _strip_xcconfig_comments(text: str) -> str:
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def xcconfig_violations(root: Path) -> list[str]:
    found: list[str] = []
    pending = [root / "Configs" / "Release.xcconfig"]
    seen: set[Path] = set()
    while pending:
        path = pending.pop()
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        text = path.read_text(encoding="utf-8")
        if FLAG in _strip_xcconfig_comments(text):
            found.append(f"{path.relative_to(root)} defines {FLAG}")
        for name in INCLUDE.findall(text):
            pending.append(path.parent / name)
    return found


def pbxproj_violations(root: Path) -> list[str]:
    path = root / "bitchat.xcodeproj" / "project.pbxproj"
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8")
    found: list[str] = []
    # Each XCBuildConfiguration: `ID /* Name */ = { isa = XCBuildConfiguration; ... name = Release; };`
    for match in re.finditer(r"isa = XCBuildConfiguration;(.*?)\n\t\t};", text, re.DOTALL):
        block = match.group(1)
        name = re.search(r"\bname = (\"?)([^\";]+)\1;", block)
        if name and name.group(2) == "Release" and FLAG in block:
            found.append(f"{path.relative_to(root)}: a Release build configuration defines {FLAG}")
    return found


def manifest_violations(root: Path) -> list[str]:
    found: list[str] = []
    for path in sorted(root.rglob("Package.swift")):
        if any(part in {".build", "checkouts", ".git"} for part in path.parts):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//", 1)[0]
            if FLAG in code and ".when(configuration: .debug)" not in code:
                found.append(f"{path.relative_to(root)}:{number} defines {FLAG} outside debug")
    return found


def build_settings_violations(text: str) -> list[str]:
    return [
        f"Release build settings define {FLAG}: {line.strip()}"
        for line in text.splitlines()
        if FLAG in line
    ]


def find_violations(root: Path, build_settings: str | None = None) -> list[str]:
    found = xcconfig_violations(root) + pbxproj_violations(root) + manifest_violations(root)
    if build_settings is not None:
        found += build_settings_violations(build_settings)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root", nargs="?", default=".", type=Path)
    parser.add_argument("--build-settings", help="xcodebuild -showBuildSettings output, or - for stdin")
    args = parser.parse_args(argv)

    settings = None
    if args.build_settings == "-":
        settings = sys.stdin.read()
        if not settings.strip():
            print("error: empty build settings on stdin", file=sys.stderr)
            return 2
    elif args.build_settings:
        settings = Path(args.build_settings).read_text(encoding="utf-8")

    violations = find_violations(args.root.resolve(), settings)
    for violation in violations:
        print(f"error: {violation}", file=sys.stderr)
    if violations:
        return 1
    print(f"OK: no Release build defines {FLAG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
