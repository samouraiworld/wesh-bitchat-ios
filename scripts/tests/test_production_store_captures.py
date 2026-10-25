import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_store_screenshot_tooling import png

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("validate_production_store_captures", ROOT / "scripts" / "validate_production_store_captures.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ProductionStoreCaptureTests(unittest.TestCase):
    def test_hashed_sources_use_exact_tracked_filename_case(self) -> None:
        tracked = set(subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"]).decode().split("\0"))
        self.assertEqual(set(MODULE.SOURCE_FILES) - tracked, set())

    def create_set(self, root: Path) -> None:
        image = png()
        for path in MODULE.expected_files(root):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(image)

    def test_manifest_records_render_sources_without_claiming_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            manifest = MODULE.validate_set(root, "a" * 40, ROOT)
            self.assertEqual(len(manifest["screenshots"]), 10)
            self.assertEqual(manifest["renderSourceCommit"], "a" * 40)
            self.assertEqual(manifest["candidateBinding"]["status"], "unbound")
            self.assertEqual(manifest["visualReview"], "pending")
            self.assertNotIn("candidateVersion", manifest)
            self.assertNotIn("candidateSourceCommit", manifest)
            self.assertEqual(len(manifest["productionSources"]), len(MODULE.SOURCE_FILES))
            self.assertTrue(all(len(item["sha256"]) == 64 for item in manifest["productionSources"]))

    def test_previous_recreated_scenes_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            (root / "en-US" / "01-home-peers.png").write_bytes(png())
            with self.assertRaisesRegex(MODULE.ValidationError, "unexpected screenshots"):
                MODULE.validate_set(root, "a" * 40, ROOT)

    def test_missing_scene_and_invalid_commit_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_set(root)
            with self.assertRaisesRegex(MODULE.ValidationError, "Git SHA"):
                MODULE.validate_set(root, "main", ROOT)
            MODULE.expected_files(root)[0].unlink()
            with self.assertRaisesRegex(MODULE.ValidationError, "missing screenshots"):
                MODULE.validate_set(root, "a" * 40, ROOT)

    def test_capture_composes_production_views_and_native_navigation_only(self) -> None:
        source = (ROOT / "bitchat/ScreenshotCapture/ScreenshotCaptureRootView.swift").read_text()
        for component in ("PaveOnboardingFlow(", "PaveSettingsScreen(", "PaveConnexionSheet(", "PaveAboutScreen(", "WeshTabsPresentation("):
            self.assertIn(component, source)
        for forbidden in (".font(", "Text(", "Image(", "TabView(", ".statusBarHidden(", ".task", ".onAppear", ".shared", "@AppStorage", "UserDefaults", "WeshQRTrust", "WeshSealedStore", "ChatViewModel("):
            self.assertNotIn(forbidden, source)
        self.assertIn("PaveInternetModeStub(internetStatus: .off)", source)
        self.assertIn(".allowsHitTesting(false)", source)
        self.assertIn(".navigationDestination(isPresented: $showingAbout)", source)
        self.assertIn(".sheet(isPresented: $showingConnection)", source)
        production = (ROOT / "bitchat/Views/Wesh/WeshRootView.swift").read_text()
        self.assertIn("WeshTabsPresentation(selection: $selectedTab", production)
        self.assertNotIn("TabView(selection:", production)

    def test_scene_names_match_capture_script_and_validator(self) -> None:
        source = (ROOT / "bitchat/ScreenshotCapture/ScreenshotCaptureRootView.swift").read_text()
        capture = (ROOT / "scripts/capture_store_screenshots.sh").read_text()
        for scene in MODULE.SCENES:
            self.assertIn('"' + scene + '"', source)
            self.assertIn("  " + scene + "\n", capture)
        self.assertNotIn("StoreAssets/iOS/107", capture)
        self.assertIn("--render-commit", capture)


if __name__ == "__main__":
    unittest.main()
