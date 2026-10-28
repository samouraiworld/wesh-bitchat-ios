import plistlib
import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_export_compliance_keys as checker

REPO_ROOT = Path(__file__).resolve().parents[2]


class CheckExportComplianceKeysTests(unittest.TestCase):
    def make_repo(self, plist_keys=None, pbxproj="", xcconfigs=None):
        root = Path(tempfile.mkdtemp())
        (root / "bitchat").mkdir()
        keys = {"CFBundleName": "Wesh", **(plist_keys or {})}
        (root / "bitchat" / "Info.plist").write_bytes(plistlib.dumps(keys))
        (root / "bitchat.xcodeproj").mkdir()
        (root / "bitchat.xcodeproj" / "project.pbxproj").write_text(pbxproj, encoding="utf-8")
        (root / "Configs").mkdir()
        for name, text in (xcconfigs or {"Release.xcconfig": "MARKETING_VERSION = 1.0.1\n"}).items():
            (root / "Configs" / name).write_text(text, encoding="utf-8")
        return root

    def test_the_repository_keeps_a_truthful_export_answer(self) -> None:
        self.assertEqual(checker.find_violations(REPO_ROOT), [])

    def test_absent_keys_leave_the_answer_to_app_store_connect(self) -> None:
        self.assertEqual(checker.find_violations(self.make_repo()), [])

    def test_declaring_no_non_exempt_encryption_is_refused(self) -> None:
        root = self.make_repo({checker.USES_KEY: False})
        self.assertEqual(len(checker.find_violations(root)), 1)

    def test_yes_needs_the_code_apple_issues(self) -> None:
        self.assertEqual(len(checker.find_violations(self.make_repo({checker.USES_KEY: True}))), 1)
        root = self.make_repo({checker.USES_KEY: True, checker.CODE_KEY: "  "})
        self.assertEqual(len(checker.find_violations(root)), 1)
        root = self.make_repo({checker.USES_KEY: True, checker.CODE_KEY: "a1b2c3d4-0000-0000-0000-000000000000"})
        self.assertEqual(checker.find_violations(root), [])

    def test_a_code_without_yes_is_refused(self) -> None:
        root = self.make_repo({checker.CODE_KEY: "a1b2c3d4"})
        self.assertEqual(len(checker.find_violations(root)), 1)

    def test_the_answer_cannot_hide_in_generated_info_plist_settings(self) -> None:
        root = self.make_repo(pbxproj="\t\t\t\tINFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;\n")
        self.assertEqual(len(checker.find_violations(root)), 1)

    def test_the_answer_cannot_hide_in_an_xcconfig(self) -> None:
        for name in ("Release.xcconfig", "Local.xcconfig"):
            with self.subTest(name=name):
                root = self.make_repo(xcconfigs={name: "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO\n"})
                self.assertEqual(len(checker.find_violations(root)), 1)
        root = self.make_repo(xcconfigs={"Release.xcconfig": "// INFOPLIST_KEY_ITSEncryptionExportComplianceCode = x\n"})
        self.assertEqual(checker.find_violations(root), [])

    def test_a_malformed_info_plist_is_reported_clearly(self) -> None:
        root = self.make_repo()
        (root / "bitchat" / "Info.plist").write_text("<plist><dict><key>", encoding="utf-8")
        violations = checker.find_violations(root)
        self.assertEqual(len(violations), 1)
        self.assertIn("bitchat/Info.plist is not a readable property list", violations[0])
        self.assertEqual(checker.main([str(root)]), 1)

    def test_main_exit_codes(self) -> None:
        self.assertEqual(checker.main([str(self.make_repo())]), 0)
        self.assertEqual(checker.main([str(self.make_repo({checker.USES_KEY: False}))]), 1)


if __name__ == "__main__":
    unittest.main()
