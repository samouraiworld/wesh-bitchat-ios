import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_screenshot_capture_boundary", ROOT / "scripts" / "check_screenshot_capture_boundary.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ScreenshotCaptureBoundaryTests(unittest.TestCase):
    def product(self, root: Path, bundle_id: str, executable: bytes) -> Path:
        app = root / "Fixture.app"
        app.mkdir()
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Fixture"}, handle)
        (app / "Fixture").write_bytes(executable)
        return app

    def test_repository_source_boundary_is_complete(self) -> None:
        self.assertEqual(MODULE.source_violations(ROOT), [])

    def test_release_product_rejects_fixture_sentinel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self.product(Path(directory), "org.samouraiworld.wesh.ios", MODULE.SENTINEL)
            self.assertIn("Release product contains Screenshot fixture sentinel", MODULE.inspect_product(app, screenshot=False))

    def test_release_product_without_fixture_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self.product(Path(directory), "org.samouraiworld.wesh.ios", b"release executable")
            self.assertEqual(MODULE.inspect_product(app, screenshot=False), [])

    def test_screenshot_product_requires_suffix_and_sentinel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self.product(Path(directory), "org.samouraiworld.wesh.ios.screenshots", MODULE.SENTINEL)
            self.assertEqual(MODULE.inspect_product(app, screenshot=True), [])


if __name__ == "__main__":
    unittest.main()
