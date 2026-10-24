#!/usr/bin/env python3
"""Enforce the maintained EN/FR locale surface in sources and built products."""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

SOURCE_LOCALES = {"en", "fr"}
PRODUCT_LOCALES = SOURCE_LOCALES | {"Base"}


def _catalog_violations(root: Path) -> list[str]:
    violations: list[str] = []
    catalogs = sorted((root / "bitchat").rglob("*.xcstrings"))
    if not catalogs:
        return ["bitchat contains no string catalog"]

    for path in catalogs:
        relative = path.relative_to(root)
        try:
            catalog = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            violations.append(f"{relative} is not a readable string catalog: {error}")
            continue

        if catalog.get("sourceLanguage") != "en":
            violations.append(f"{relative} sourceLanguage must be en")

        present: set[str] = set()
        for key, entry in catalog.get("strings", {}).items():
            if not isinstance(entry, dict):
                continue
            localizations = entry.get("localizations", {})
            if not isinstance(localizations, dict):
                violations.append(f"{relative}: {key!r} has invalid localizations")
                continue
            locales = set(localizations)
            present.update(locales)
            unsupported = locales - SOURCE_LOCALES
            if unsupported:
                violations.append(
                    f"{relative}: {key!r} contains unsupported locales "
                    f"{', '.join(sorted(unsupported))}"
                )
            if entry.get("shouldTranslate") is not False:
                missing = SOURCE_LOCALES - locales
                if missing:
                    violations.append(
                        f"{relative}: {key!r} is missing maintained locales "
                        f"{', '.join(sorted(missing))}"
                    )

        if present != SOURCE_LOCALES:
            violations.append(
                f"{relative} locale set is {sorted(present)}, expected {sorted(SOURCE_LOCALES)}"
            )
    return violations


def _project_region_violations(root: Path) -> list[str]:
    path = root / "bitchat.xcodeproj" / "project.pbxproj"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        return [f"cannot read {path.relative_to(root)}: {error}"]

    match = re.search(r"\bknownRegions = \((.*?)\n\s*\);", text, re.DOTALL)
    if not match:
        return [f"{path.relative_to(root)} has no knownRegions block"]
    regions = {
        line.strip().rstrip(",").strip('"')
        for line in match.group(1).splitlines()
        if line.strip()
    }
    expected = SOURCE_LOCALES | {"Base"}
    if regions != expected:
        return [f"{path.relative_to(root)} knownRegions is {sorted(regions)}, expected {sorted(expected)}"]
    return []


def source_violations(root: Path) -> list[str]:
    violations = _catalog_violations(root) + _project_region_violations(root)
    localized_directories = {
        path.name.removesuffix(".lproj")
        for path in (root / "bitchat").glob("*.lproj")
        if path.is_dir()
    }
    if localized_directories != SOURCE_LOCALES:
        violations.append(
            "bitchat .lproj directories are "
            f"{sorted(localized_directories)}, expected {sorted(SOURCE_LOCALES)}"
        )
    return violations


def _app_locales(app: Path) -> set[str]:
    return {
        path.name.removesuffix(".lproj")
        for path in app.glob("*.lproj")
        if path.is_dir()
    }


def _ipa_locales(ipa: Path) -> tuple[set[str], list[str]]:
    with zipfile.ZipFile(ipa) as archive:
        app_roots: set[str] = set()
        locales: set[str] = set()
        for name in archive.namelist():
            match = re.match(r"Payload/([^/]+\.app)/([^/]+)\.lproj(?:/|$)", name)
            if match:
                app_roots.add(match.group(1))
                locales.add(match.group(2))
    problems = [] if len(app_roots) == 1 else [f"IPA contains {len(app_roots)} localized app roots"]
    return locales, problems


def product_violations(product: Path) -> list[str]:
    try:
        if product.suffix == ".ipa":
            locales, violations = _ipa_locales(product)
        else:
            app = product
            if product.suffix == ".xcarchive":
                apps = list((product / "Products" / "Applications").glob("*.app"))
                if len(apps) != 1:
                    return [f"archive contains {len(apps)} applications, expected 1"]
                app = apps[0]
            if app.suffix != ".app" or not app.is_dir():
                return [f"product is not an .app, .ipa or .xcarchive: {product}"]
            locales = _app_locales(app)
            violations = []
    except (OSError, zipfile.BadZipFile) as error:
        return [f"cannot inspect product {product}: {error}"]

    unsupported = locales - PRODUCT_LOCALES
    missing = SOURCE_LOCALES - locales
    if unsupported:
        violations.append(f"product contains unsupported locales {', '.join(sorted(unsupported))}")
    if missing:
        violations.append(f"product is missing maintained locales {', '.join(sorted(missing))}")
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=".", type=Path)
    parser.add_argument("--product", type=Path, help="optional .app, .ipa or .xcarchive to inspect")
    args = parser.parse_args(argv)

    violations = source_violations(args.root.resolve())
    if args.product:
        violations += product_violations(args.product.resolve())
    for violation in violations:
        print(f"error: {violation}", file=sys.stderr)
    if violations:
        return 1

    suffix = " and product" if args.product else ""
    print(f"OK: release sources{suffix} expose only maintained EN/FR localizations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
