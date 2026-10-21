"""Offline notice inventory contracts; no compiler or network access."""
import importlib.util
import json
from pathlib import Path
import tempfile
import shutil
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("third_party_notices", ROOT / "scripts/third_party_notices.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)

def copy_contract_inputs(source, destination):
    for path in [notices.INVENTORY, notices.ARTI_TEXT, notices.SECP_TEXT,
                 notices.LOCK, notices.MANIFEST, Path('Package.swift')]:
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / path, target)
    return destination


class NoticeContracts(unittest.TestCase):
    def test_bundled_inventory_matches_pinned_sources_and_all_texts(self):
        notices.check(ROOT)

    def test_missing_component_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = copy_contract_inputs(ROOT, Path(folder))
            path = root / notices.INVENTORY
            value = json.loads(path.read_text())
            value["components"].pop()
            value["componentsSHA256"] = notices.digest(notices.json_bytes(value["components"]))
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "component|inventory"):
                notices.check(root)

    def test_stale_license_text_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = copy_contract_inputs(ROOT, Path(folder))
            path = root / notices.ARTI_TEXT
            path.write_text(path.read_text() + "modified")
            with self.assertRaisesRegex(ValueError, "hash|text"):
                notices.check(root)

    def test_missing_primary_material_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = copy_contract_inputs(ROOT, Path(folder))
            path = root / notices.INVENTORY
            value = json.loads(path.read_text())
            value["unresolved"] = ["synthetic-missing-license"]
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "unresolved|missing"):
                notices.check(root)

    def test_void_retains_the_primary_grant_without_inventing_a_copyright(self):
        inventory = json.loads((ROOT / notices.INVENTORY).read_text())
        component = next(p for p in inventory["components"] if p["name"] == "void")
        self.assertEqual(component["license"], "MIT")
        self.assertEqual(component["releaseCommit"], "ab2f4dbb7c95c144ccba2fa8afd11e155aa91133")
        self.assertEqual(len(component["notices"]), 3)
        self.assertTrue(any("void@1.0.2" in q for q in inventory["qualifications"]))
        text = (ROOT / notices.ARTI_TEXT).read_text()
        self.assertIn("Jonathan Reem", text)
        self.assertNotIn("Copyright (c) <year> <copyright holders>", text)

    def test_lock_change_requires_regeneration(self):
        with tempfile.TemporaryDirectory() as folder:
            root = copy_contract_inputs(ROOT, Path(folder))
            path = root / notices.LOCK
            path.write_text(path.read_text() + "\n# changed\n")
            with self.assertRaisesRegex(ValueError, "Cargo.lock changed"):
                notices.check(root)

    def test_a_tampered_cached_crate_cannot_supply_primary_texts(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder)
            archive = cache / "registry" / "synthetic-1.0.0.crate"
            archive.parent.mkdir()
            archive.write_bytes(b"modified archive")
            with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
                notices.archive_notices({"name": "synthetic", "version": "1.0.0"},
                                        "0" * 64, cache, {})

    def test_ring_preserves_every_upstream_notice(self):
        inventory = json.loads((ROOT / notices.INVENTORY).read_text())
        ring = next(p for p in inventory["components"] if p["name"] == "ring")
        self.assertEqual({n["path"] for n in ring["notices"]}, {
            "LICENSE", "LICENSE-BoringSSL", "LICENSE-other-bits",
            "src/polyfill/once_cell/LICENSE-APACHE", "src/polyfill/once_cell/LICENSE-MIT",
            "third_party/fiat/LICENSE",
        })

if __name__ == "__main__":
    unittest.main()
