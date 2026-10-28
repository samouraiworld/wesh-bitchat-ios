#!/usr/bin/env python3
"""Keep the iOS export-compliance keys consistent with what Wesh embeds.

Wesh ships standard encryption beyond Apple's operating system (Noise with
X25519 and ChaCha20-Poly1305, Ed25519, secp256k1, the Arti Tor client). Apple
asks for a French encryption declaration when such an app is offered in
France, and issues a compliance code once it approves that document.

So the bundle may either:
  - omit ITSAppUsesNonExemptEncryption, leaving the questionnaire to App
    Store Connect for each build; or
  - set it to YES together with the ITSEncryptionExportComplianceCode that
    Apple issued (a YES without a code is refused at upload).

Setting it to NO would answer "no documentation needed" on every build and
skip the French declaration, so it is refused here, as is a code without YES.
The answer lives in bitchat/Info.plist only: INFOPLIST_KEY_ITS* build settings
(project or Configs/*.xcconfig, Local.xcconfig included) are refused.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError

USES_KEY = "ITSAppUsesNonExemptEncryption"
CODE_KEY = "ITSEncryptionExportComplianceCode"


def info_plist_violations(root: Path) -> list[str]:
    path = root / "bitchat" / "Info.plist"
    try:
        info = plistlib.loads(path.read_bytes())
    except OSError as error:
        return [f"cannot read {path.relative_to(root)}: {error}"]
    except (plistlib.InvalidFileException, ExpatError, ValueError) as error:
        return [f"{path.relative_to(root)} is not a readable property list: {error}"]
    if not isinstance(info, dict):
        return [f"{path.relative_to(root)} is not a readable property list: top level is not a dictionary"]

    relative = path.relative_to(root)
    uses = info.get(USES_KEY)
    code = info.get(CODE_KEY)
    has_code = isinstance(code, str) and code.strip() != ""
    if uses is None:
        return [f"{relative} sets {CODE_KEY} without {USES_KEY} = YES"] if CODE_KEY in info else []
    if uses is not True:
        return [f"{relative} declares {USES_KEY} = {uses!r}; Wesh embeds non-exempt standard encryption"]
    if not has_code:
        return [f"{relative} sets {USES_KEY} = YES without the {CODE_KEY} Apple issues"]
    return []


def pbxproj_violations(root: Path) -> list[str]:
    path = root / "bitchat.xcodeproj" / "project.pbxproj"
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8")
    return [
        f"{path.relative_to(root)} sets INFOPLIST_KEY_{key}; keep the answer in bitchat/Info.plist"
        for key in (USES_KEY, CODE_KEY)
        if f"INFOPLIST_KEY_{key}" in text
    ]


def xcconfig_violations(root: Path) -> list[str]:
    """Build settings can generate the same Info.plist keys; Local.xcconfig included."""
    found: list[str] = []
    for path in sorted((root / "Configs").glob("*.xcconfig")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r"\bINFOPLIST_KEY_ITS", line.split("//", 1)[0]):
                found.append(f"{path.relative_to(root)}:{number} sets an INFOPLIST_KEY_ITS* setting; "
                             "keep the answer in bitchat/Info.plist")
    return found


def find_violations(root: Path) -> list[str]:
    return info_plist_violations(root) + pbxproj_violations(root) + xcconfig_violations(root)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root", nargs="?", default=".", type=Path)
    args = parser.parse_args(argv)

    violations = find_violations(args.root.resolve())
    for violation in violations:
        print(f"error: {violation}", file=sys.stderr)
    if violations:
        return 1
    print("OK: export-compliance keys match the encryption Wesh embeds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
