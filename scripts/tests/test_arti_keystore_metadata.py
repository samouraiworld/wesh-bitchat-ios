import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("keystore_metadata", ROOT / "scripts/probe_arti_keystore_metadata.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def package(name="existing", version="1.0.0", checksum="a"):
    return f'[[package]]\nname = "{name}"\nversion = "{version}"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "{checksum}"\n'.encode()


class KeystoreMetadataTests(unittest.TestCase):
    def test_metadata_paths_are_neutralized_and_private_paths_fail_closed(self):
        source = {"id": "path+file:///home/runner/work/_temp/probe/candidate#0.1.0", "nested": ["/home/runner/cargo/registry"]}
        clean = probe.sanitized_metadata(source, [("/home/runner/work/_temp/probe", "/usr/src/probe"), ("/home/runner/cargo", "/usr/local/cargo")])
        self.assertEqual(clean["id"], "path+file:///usr/src/probe/candidate#0.1.0")
        self.assertEqual(clean["nested"], ["/usr/local/cargo/registry"])
        with self.assertRaisesRegex(ValueError, "Private host path"):
            probe.sanitized_metadata({"path": "/Users/example/private-source"}, [])

    def test_additions_preserve_every_existing_identity_and_checksum(self):
        old = package()
        added = probe.additions_only(old, old + package("new"))
        self.assertEqual([item["name"] for item in added], ["new"])

    def test_removal_version_source_or_checksum_drift_is_rejected(self):
        old = package()
        variants = [package("replacement"), package(version="1.0.1"), package(checksum="b"),
                    package().replace(b"registry+https", b"git+https")]
        for changed in variants:
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "removed or changed"):
                probe.additions_only(old, changed)

    def test_duplicate_package_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            probe.inventory(package() + package())

    def test_client_boundary_keeps_generic_hsv3_service_visible(self):
        features = {"arti-client": ["keymgr"], "tor-keymgr": ["keymgr"],
                    "tor-hsclient": ["keymgr"], "tor-llcrypto": ["hsv3-service"]}
        probe.require_client_boundary(features)

    def test_service_relay_or_unsupported_client_surface_is_rejected(self):
        for name, feature in (("arti-client", "onion-service-service"), ("arti-client", "onion-service-client"),
                              ("tor-proto", "relay"), ("tor-cert", "x509"), ("tor-llcrypto", "relay")):
            features = {"arti-client": ["keymgr"], "tor-keymgr": ["keymgr"]}
            features.setdefault(name, []).append(feature)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Unexpected"):
                probe.require_client_boundary(features)
        with self.assertRaisesRegex(ValueError, "service package"):
            probe.require_client_boundary({"arti-client": ["keymgr"], "tor-keymgr": ["keymgr"], "tor-hsservice": []})


if __name__ == "__main__":
    unittest.main()
