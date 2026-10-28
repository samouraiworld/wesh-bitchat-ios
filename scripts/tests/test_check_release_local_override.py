import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_release_local_override as checker

REPO_ROOT = Path(__file__).resolve().parents[2]

PBXPROJ = """\
\t\tAAAA /* Debug configuration for PBXNativeTarget "bitchat_iOS" */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReferenceRelativePath = Debug.xcconfig;
\t\t\tbuildSettings = {{
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\tBBBB /* Release configuration for PBXNativeTarget "bitchat_iOS" */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReferenceRelativePath = {release_base};
\t\t\tbuildSettings = {{
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""


class CheckReleaseLocalOverrideTests(unittest.TestCase):
    def make_repo(self, release="", release_base="Release.xcconfig", extra=None):
        root = Path(tempfile.mkdtemp())
        configs = root / "Configs"
        configs.mkdir()
        (configs / "Release.xcconfig").write_text(release + "\nMARKETING_VERSION = 1.0.1\n", encoding="utf-8")
        (configs / "Debug.xcconfig").write_text(
            '#include "Release.xcconfig"\n#include? "Local.xcconfig"\n', encoding="utf-8"
        )
        for name, text in (extra or {}).items():
            (configs / name).write_text(text, encoding="utf-8")
        (root / "bitchat.xcodeproj").mkdir()
        (root / "bitchat.xcodeproj" / "project.pbxproj").write_text(
            PBXPROJ.format(release_base=release_base), encoding="utf-8"
        )
        return root

    def test_the_repository_release_build_ignores_local_overrides(self) -> None:
        self.assertEqual(checker.find_violations(REPO_ROOT), [])

    def test_debug_may_include_the_local_override(self) -> None:
        self.assertEqual(checker.find_violations(self.make_repo()), [])

    def test_release_xcconfig_must_not_include_the_local_override(self) -> None:
        for include in ('#include? "Local.xcconfig"', '#include "Local.xcconfig"', '  #include?  "./Local.xcconfig"'):
            with self.subTest(include=include):
                self.assertEqual(len(checker.find_violations(self.make_repo(release=include))), 1)

    def test_a_commented_include_is_ignored(self) -> None:
        self.assertEqual(checker.find_violations(self.make_repo(release='// #include? "Local.xcconfig"')), [])

    def test_indirect_includes_are_followed(self) -> None:
        root = self.make_repo(
            release='#include "Shared.xcconfig"',
            extra={"Shared.xcconfig": '#include? "Local.xcconfig"\n'},
        )
        self.assertEqual(len(checker.find_violations(root)), 1)

    def test_release_configurations_must_be_based_on_release_xcconfig(self) -> None:
        for base in ("Debug.xcconfig", "Local.xcconfig"):
            with self.subTest(base=base):
                self.assertEqual(len(checker.find_violations(self.make_repo(release_base=base))), 1)

    def test_resolved_release_settings_must_not_carry_the_probe(self) -> None:
        root = self.make_repo()
        clean = "    PRODUCT_BUNDLE_IDENTIFIER = org.samouraiworld.wesh.ios\n"
        self.assertEqual(checker.find_violations(root, clean), [])
        leaked = f"    {checker.PROBE_SETTING} = {checker.PROBE_VALUE}\n"
        self.assertEqual(len(checker.find_violations(root, leaked)), 1)
        leaked = f"    PRODUCT_BUNDLE_IDENTIFIER = {checker.PROBE_VALUE}\n"
        self.assertEqual(len(checker.find_violations(root, leaked)), 1)

    def test_the_probe_file_overrides_the_settings_it_watches(self) -> None:
        probe = checker.probe_xcconfig()
        self.assertIn(f"{checker.PROBE_SETTING} = {checker.PROBE_VALUE}", probe)
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER = {checker.PROBE_VALUE}", probe)

    def test_main_exit_codes(self) -> None:
        self.assertEqual(checker.main([str(self.make_repo())]), 0)
        self.assertEqual(checker.main([str(self.make_repo(release='#include? "Local.xcconfig"'))]), 1)


if __name__ == "__main__":
    unittest.main()
