from pathlib import Path
import plistlib
import unittest
import xml.etree.ElementTree as ET


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class ShareExtensionRetirementTests(unittest.TestCase):
    """The V1 app has no OS share entry point; legacy payload erasure remains available."""

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
