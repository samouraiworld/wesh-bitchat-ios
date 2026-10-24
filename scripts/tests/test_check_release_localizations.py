import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_release_localizations as checker

REPO_ROOT = Path(__file__).resolve().parents[2]


class CheckReleaseLocalizationsTests(unittest.TestCase):
    def make_repo(self, locales=("en", "fr"), regions=("Base", "en", "fr")) -> Path:
        root = Path(tempfile.mkdtemp())
        app = root / "bitchat"
        app.mkdir()
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "greeting": {
                    "localizations": {
                        locale: {"stringUnit": {"state": "translated", "value": locale}}
                        for locale in locales
                    }
                }
            },
            "version": "1.0",
        }
        (app / "Localizable.xcstrings").write_text(json.dumps(catalog), encoding="utf-8")
        for locale in ("en", "fr"):
            (app / f"{locale}.lproj").mkdir()
        project = root / "bitchat.xcodeproj"
        project.mkdir()
        region_lines = "\n".join(f"\t\t\t\t{region}," for region in regions)
        (project / "project.pbxproj").write_text(
            f"\t\t\tknownRegions = (\n{region_lines}\n\t\t\t);\n",
            encoding="utf-8",
        )
        return root

    def test_repository_sources_expose_only_en_and_fr(self) -> None:
        self.assertEqual(checker.source_violations(REPO_ROOT), [])

    def test_source_gate_rejects_catalog_and_project_locale_drift(self) -> None:
        root = self.make_repo(locales=("en", "fr", "de"), regions=("Base", "en", "fr", "de"))
        violations = checker.source_violations(root)
        self.assertTrue(any("unsupported locales de" in problem for problem in violations))
        self.assertTrue(any("knownRegions" in problem for problem in violations))

    def test_app_product_gate_accepts_en_fr_and_optional_base(self) -> None:
        app = Path(tempfile.mkdtemp()) / "Wesh.app"
        app.mkdir()
        for locale in ("Base", "en", "fr"):
            (app / f"{locale}.lproj").mkdir()
        self.assertEqual(checker.product_violations(app), [])

    def test_ipa_product_gate_rejects_an_exported_legacy_locale(self) -> None:
        ipa = Path(tempfile.mkdtemp()) / "Wesh.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            for locale in ("en", "fr", "de"):
                archive.writestr(f"Payload/Wesh.app/{locale}.lproj/Localizable.strings", "")
        violations = checker.product_violations(ipa)
        self.assertEqual(violations, ["product contains unsupported locales de"])


if __name__ == "__main__":
    unittest.main()
