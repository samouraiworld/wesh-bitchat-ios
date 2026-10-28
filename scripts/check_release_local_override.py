#!/usr/bin/env python3
"""Fail if an untracked Configs/Local.xcconfig could change a Release build.

Local.xcconfig is a developer convenience (team, .dev bundle and App Group
identifiers). Only Debug may read it: a Release build, and so every archive
sent to App Store Connect, must resolve from tracked settings alone.

Static checks (always):
  - Configs/Release.xcconfig, and every xcconfig it includes, never include
    Local.xcconfig;
  - every Release build configuration in bitchat.xcodeproj is based on
    Release.xcconfig.

Dynamic check (CI): write the probe from `--write-probe PATH` to
Configs/Local.xcconfig, then pass the output of
`xcodebuild -showBuildSettings -configuration Release` to `--build-settings`
(`-` for stdin). The probe's values must not appear in it.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

LOCAL = "Local.xcconfig"
PROBE_SETTING = "WESH_LOCAL_OVERRIDE_PROBE"
PROBE_VALUE = "local.override.probe"
INCLUDE = re.compile(r'^\s*#include\??\s+"([^"]+)"', re.MULTILINE)


def _strip_xcconfig_comments(text: str) -> str:
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def probe_xcconfig() -> str:
    return (
        "// CI probe: a Release build must never read these values.\n"
        f"{PROBE_SETTING} = {PROBE_VALUE}\n"
        f"PRODUCT_BUNDLE_IDENTIFIER = {PROBE_VALUE}\n"
    )


def xcconfig_violations(root: Path) -> list[str]:
    found: list[str] = []
    pending = [root / "Configs" / "Release.xcconfig"]
    seen: set[Path] = set()
    while pending:
        path = pending.pop()
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        for name in INCLUDE.findall(_strip_xcconfig_comments(path.read_text(encoding="utf-8"))):
            if Path(name).name == LOCAL:
                found.append(f"{path.relative_to(root)} includes {LOCAL}")
            else:
                pending.append(path.parent / name)
    return found


def pbxproj_violations(root: Path) -> list[str]:
    path = root / "bitchat.xcodeproj" / "project.pbxproj"
    if not path.is_file():
        return [f"{path.relative_to(root)} is missing"]
    text = path.read_text(encoding="utf-8")
    found: list[str] = []
    for match in re.finditer(r"isa = XCBuildConfiguration;(.*?)\n\t\t};", text, re.DOTALL):
        block = match.group(1)
        name = re.search(r"\bname = (\"?)([^\";]+)\1;", block)
        base = re.search(r"\bbaseConfigurationReferenceRelativePath = (\"?)([^\";]+)\1;", block)
        if name and name.group(2) == "Release" and base and Path(base.group(2)).name != "Release.xcconfig":
            found.append(f"{path.relative_to(root)}: a Release configuration is based on {base.group(2)}")
    return found


def build_settings_violations(text: str) -> list[str]:
    return [
        f"Release build settings read {LOCAL}: {line.strip()}"
        for line in text.splitlines()
        if PROBE_SETTING in line or PROBE_VALUE in line
    ]


def find_violations(root: Path, build_settings: str | None = None) -> list[str]:
    found = xcconfig_violations(root) + pbxproj_violations(root)
    if build_settings is not None:
        found += build_settings_violations(build_settings)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root", nargs="?", default=".", type=Path)
    parser.add_argument("--build-settings", help="xcodebuild -showBuildSettings output, or - for stdin")
    parser.add_argument("--write-probe", type=Path, help="write the CI probe xcconfig to this path and exit")
    args = parser.parse_args(argv)

    if args.write_probe:
        args.write_probe.write_text(probe_xcconfig(), encoding="utf-8")
        return 0

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
    print(f"OK: no Release build reads {LOCAL}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
