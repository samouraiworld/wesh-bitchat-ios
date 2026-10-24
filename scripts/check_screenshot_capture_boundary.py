#!/usr/bin/env python3
"""Prove Screenshot fixtures are simulator-only and absent from the Release product."""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

FLAG = "WESH_SCREENSHOT_CAPTURE"
SENTINEL = b"WESH_SCREENSHOT_FIXTURE_SENTINEL_V1"
SCREENSHOT_SUFFIX = ".screenshots"
FORBIDDEN_FIXTURE_APIS = (
    "AppRuntime(",
    "BLEService",
    "CoreBluetooth",
    "NetworkActivationService",
    "NostrRelayManager",
    "URLSession",
)


def source_violations(root: Path) -> list[str]:
    violations: list[str] = []
    release = (root / "Configs" / "Release.xcconfig").read_text(encoding="utf-8")
    screenshot = (root / "Configs" / "Screenshot.xcconfig").read_text(encoding="utf-8")
    project = (root / "bitchat.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
    fixture = (root / "bitchat" / "ScreenshotCapture" / "ScreenshotCaptureRootView.swift").read_text(encoding="utf-8")
    scheme = (root / "bitchat.xcodeproj" / "xcshareddata" / "xcschemes" / "Wesh Store Screenshots.xcscheme").read_text(encoding="utf-8")
    capture = (root / "scripts" / "capture_store_screenshots.sh").read_text(encoding="utf-8")

    if FLAG in release:
        violations.append(f"Configs/Release.xcconfig contains {FLAG}")
    required_config = (
        '#include "Release.xcconfig"',
        f"SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) {FLAG}",
        "SUPPORTED_PLATFORMS = iphonesimulator",
        "SDKROOT = iphonesimulator",
        "CODE_SIGNING_ALLOWED = NO",
        f"PRODUCT_BUNDLE_IDENTIFIER = org.samouraiworld.wesh.ios{SCREENSHOT_SUFFIX}",
    )
    for value in required_config:
        if value not in screenshot:
            violations.append(f"Configs/Screenshot.xcconfig missing {value!r}")
    if "baseConfigurationReferenceRelativePath = Release.xcconfig;" not in project:
        violations.append("Release target no longer references Release.xcconfig")
    if "baseConfigurationReferenceRelativePath = Screenshot.xcconfig;" not in project:
        violations.append("Screenshot target configuration is missing")
    if 'buildConfiguration="Screenshot"' not in scheme or 'buildForArchiving="NO"' not in scheme:
        violations.append("Screenshot scheme is not bound to its non-archive configuration")
    stripped = fixture.strip()
    if not stripped.startswith(f"#if {FLAG} && os(iOS)") or not stripped.endswith("#endif"):
        violations.append("fixture source is not fully enclosed by its compile-time flag")
    for token in FORBIDDEN_FIXTURE_APIS:
        if token in fixture:
            violations.append(f"fixture source references service API {token!r}")
    if re.search(r"\b[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\b", capture, re.IGNORECASE):
        violations.append("capture script contains a simulator UDID instead of selecting by name")
    return violations


def inspect_product(product: Path, screenshot: bool) -> list[str]:
    violations: list[str] = []
    info_path = product / "Info.plist"
    if product.suffix != ".app" or not info_path.is_file():
        return [f"not an application product: {product}"]
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    bundle_id = info.get("CFBundleIdentifier", "")
    executable_name = info.get("CFBundleExecutable", "")
    executable = product / executable_name
    if not executable.is_file():
        return [f"missing executable {executable_name!r} in {product}"]
    executable_bytes = executable.read_bytes()
    product_contains_sentinel = any(
        SENTINEL in path.read_bytes() for path in product.rglob("*") if path.is_file()
    )
    if screenshot:
        if not bundle_id.endswith(SCREENSHOT_SUFFIX):
            violations.append(f"Screenshot bundle ID lacks {SCREENSHOT_SUFFIX}: {bundle_id}")
        if SENTINEL not in executable_bytes:
            violations.append("Screenshot executable does not contain fixture sentinel")
    else:
        if bundle_id.endswith(SCREENSHOT_SUFFIX):
            violations.append(f"Release bundle ID unexpectedly uses screenshot suffix: {bundle_id}")
        if product_contains_sentinel:
            violations.append("Release product contains Screenshot fixture sentinel")
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=".", type=Path)
    parser.add_argument("--release-product", type=Path)
    parser.add_argument("--screenshot-product", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()

    try:
        violations = source_violations(root)
        if args.release_product:
            violations += inspect_product(args.release_product.resolve(), screenshot=False)
        if args.screenshot_product:
            violations += inspect_product(args.screenshot_product.resolve(), screenshot=True)
    except (OSError, plistlib.InvalidFileException) as error:
        violations = [str(error)]
    for violation in violations:
        print(f"error: {violation}", file=sys.stderr)
    if violations:
        return 1
    print("OK: Screenshot capture is simulator-only and Release excludes its fixtures and flag")
    return 0


if __name__ == "__main__":
    sys.exit(main())
