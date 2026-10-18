from pathlib import Path
import plistlib
import re
import unittest
import xml.etree.ElementTree as ET


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class ShareExtensionRetirementTests(unittest.TestCase):
    """The V1 app has no OS share entry point; legacy payload erasure remains available."""

    @staticmethod
    def runtime_method(name: str) -> str:
        source = (REPOSITORY_ROOT / "bitchat/App/AppRuntime.swift").read_text(encoding="utf-8")
        match = re.search(r"^    func " + re.escape(name) + r"\(", source, re.MULTILINE)
        if match is None:
            raise AssertionError(f"Expected app lifecycle entrypoint {name} is missing")
        # These existing lifecycle methods have balanced closure braces; stop at
        # the method's closing brace rather than scanning neighboring helpers.
        opening = source.index("{", match.start())
        depth = 1
        cursor = opening + 1
        while depth and cursor < len(source):
            depth += (source[cursor] == "{") - (source[cursor] == "}")
            cursor += 1
        if depth:
            raise AssertionError(f"Unterminated app lifecycle entrypoint {name}")
        return source[opening:cursor]

    def test_launch_has_no_retired_share_import_entrypoint(self) -> None:
        body = self.runtime_method("start")
        self.assertIn("NetworkActivationService.shared.start()", body)
        self.assertNotIn("checkForSharedContent", body)
        self.assertNotIn("sharedContentImportModel", body)

    def test_resume_has_no_retired_share_import_entrypoint(self) -> None:
        for method in ("handleDidBecomeActiveNotification", "handleMacDidBecomeActiveNotification", "handleScenePhaseChange"):
            with self.subTest(entrypoint=method):
                body = self.runtime_method(method)
                self.assertIn("handleDidBecomeActive()", body)
                self.assertNotIn("checkForSharedContent", body)
                self.assertNotIn("sharedContentImportModel", body)

    def test_wesh_share_url_cannot_route_to_the_retired_importer(self) -> None:
        body = self.runtime_method("handleOpenURL")
        self.assertNotIn("checkForSharedContent", body)
        self.assertNotIn("sharedContentImportModel", body)
        self.assertNotRegex(body, r'url\.host\s*==\s*"share"')

    def test_app_exposes_no_legacy_share_review_or_draft_import_surface(self) -> None:
        root_view = (REPOSITORY_ROOT / "bitchat/Views/Wesh/WeshRootView.swift").read_text(encoding="utf-8")
        app = (REPOSITORY_ROOT / "bitchat/BitchatApp.swift").read_text(encoding="utf-8")
        self.assertIn("ComposerDraftStore", root_view, "Normal draft editing must remain")
        for retired in ("WeshSharedContentReview", "WeshSharedContentSheet", "SharedContentImportModel", "sharedContentID"):
            self.assertNotIn(retired, root_view)
        self.assertNotIn("sharedContentImportModel", app)

    def test_project_contains_no_share_extension_target_or_product(self) -> None:
        project = (REPOSITORY_ROOT / "bitchat.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertTrue(
            'productType = "com.apple.product-type.application";' in project,
            "The project must still contain the app targets",
        )
        self.assertFalse("bitchatShareExtension" in project, "The project retains a share-extension reference")
        self.assertFalse(
            'productType = "com.apple.product-type.app-extension";' in project,
            "The project retains an app-extension target",
        )

    def test_ios_scheme_builds_no_share_extension(self) -> None:
        scheme = ET.parse(
            REPOSITORY_ROOT / "bitchat.xcodeproj/xcshareddata/xcschemes/bitchat (iOS).xcscheme"
        )
        references = scheme.findall(".//BuildableReference")
        self.assertTrue(any(reference.get("BlueprintName") == "bitchat_iOS" for reference in references))
        for reference in references:
            self.assertNotEqual("bitchatShareExtension", reference.get("BlueprintName"))
            self.assertFalse(reference.get("BuildableName", "").endswith(".appex"))

    def test_share_extension_sources_are_absent(self) -> None:
        self.assertFalse((REPOSITORY_ROOT / "bitchatShareExtension").exists())

    def test_only_wesh_url_scheme_is_registered(self) -> None:
        with (REPOSITORY_ROOT / "bitchat/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        schemes = [
            scheme
            for url_type in info.get("CFBundleURLTypes", [])
            for scheme in url_type.get("CFBundleURLSchemes", [])
        ]
        self.assertEqual(["wesh"], schemes)

    def test_app_group_access_remains_declared_for_legacy_payload_erasure(self) -> None:
        with (REPOSITORY_ROOT / "bitchat/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertEqual("$(APP_GROUP_ID)", info["AppGroupID"])
        for relative_path in ("bitchat/bitchat.entitlements", "bitchat/bitchat-macOS.entitlements"):
            with self.subTest(entitlements=relative_path):
                with (REPOSITORY_ROOT / relative_path).open("rb") as source:
                    entitlements = plistlib.load(source)
                self.assertIn("$(APP_GROUP_ID)", entitlements["com.apple.security.application-groups"])


if __name__ == "__main__":
    unittest.main()
