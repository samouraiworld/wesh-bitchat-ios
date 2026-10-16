import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_release_tor_enforced as checker

REPO_ROOT = Path(__file__).resolve().parents[2]

PBXPROJ = """\
\t\tAAAA /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG {debug}";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\tBBBB /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "{release}";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""


class CheckReleaseTorEnforcedTests(unittest.TestCase):
    def make_repo(self, release_xcconfig="", included="", debug_flag="", release_flag="", manifest=""):
        root = Path(tempfile.mkdtemp())
        (root / "Configs").mkdir()
        (root / "Configs" / "Release.xcconfig").write_text(
            release_xcconfig + '\n#include? "Local.xcconfig"\n', encoding="utf-8"
        )
        if included:
            (root / "Configs" / "Local.xcconfig").write_text(included, encoding="utf-8")
        (root / "bitchat.xcodeproj").mkdir()
        (root / "bitchat.xcodeproj" / "project.pbxproj").write_text(
            PBXPROJ.format(debug=debug_flag, release=release_flag), encoding="utf-8"
        )
        (root / "Package.swift").write_text(manifest, encoding="utf-8")
        return root

    def test_the_repository_release_build_enforces_tor(self) -> None:
        self.assertEqual(checker.find_violations(REPO_ROOT), [])

    def test_clean_configuration_passes(self) -> None:
        root = self.make_repo(debug_flag=checker.FLAG)
        self.assertEqual(checker.find_violations(root), [])

    def test_release_xcconfig_and_its_includes_are_checked(self) -> None:
        root = self.make_repo(release_xcconfig=f"SWIFT_ACTIVE_COMPILATION_CONDITIONS = {checker.FLAG}")
        self.assertEqual(len(checker.find_violations(root)), 1)
        root = self.make_repo(included=f"OTHER_SWIFT_FLAGS = -D{checker.FLAG}")
        self.assertEqual(len(checker.find_violations(root)), 1)
        root = self.make_repo(release_xcconfig=f"// never set {checker.FLAG} here")
        self.assertEqual(checker.find_violations(root), [])

    def test_release_build_configuration_in_the_project_is_checked(self) -> None:
        root = self.make_repo(release_flag=checker.FLAG)
        self.assertEqual(len(checker.find_violations(root)), 1)

    def test_package_manifest_define_must_be_debug_only(self) -> None:
        root = self.make_repo(manifest=f'swiftSettings: [.define("{checker.FLAG}")]\n')
        self.assertEqual(len(checker.find_violations(root)), 1)
        root = self.make_repo(
            manifest=f'swiftSettings: [.define("{checker.FLAG}", .when(configuration: .debug))]\n'
        )
        self.assertEqual(checker.find_violations(root), [])

    def test_resolved_release_build_settings_are_checked(self) -> None:
        root = self.make_repo()
        clean = "    SWIFT_ACTIVE_COMPILATION_CONDITIONS = \n    OTHER_SWIFT_FLAGS =  -D COCOAPODS\n"
        self.assertEqual(checker.find_violations(root, clean), [])
        leaked = f"    SWIFT_ACTIVE_COMPILATION_CONDITIONS = {checker.FLAG}\n"
        self.assertEqual(len(checker.find_violations(root, leaked)), 1)

    def test_main_exit_codes(self) -> None:
        self.assertEqual(checker.main([str(self.make_repo())]), 0)
        self.assertEqual(checker.main([str(self.make_repo(release_flag=checker.FLAG))]), 1)


if __name__ == "__main__":
    unittest.main()
