import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("keystore_candidate", ROOT / "scripts/build_arti_keystore_candidate.py")
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class CandidateComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.first = Path(self.temp.name) / "A"
        self.second = Path(self.temp.name) / "B"
        for root in (self.first, self.second):
            artifacts = {}
            for name in candidate.ARTIFACTS | {candidate.HEADER}:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
                artifacts[name] = candidate.digest(path)
            receipt = {"status": "complete-candidate", "sourceCommit": "a" * 40,
                       "inputs": {name: "b" * 64 for name in candidate.INPUTS},
                       "targets": list(candidate.TARGETS), "tools": {"rustc": "synthetic-identical"}, "sdks": {},
                       "artifacts": artifacts,
                       "architectures": {name: sorted(values) for name, values in candidate.ARCHITECTURES.items()},
                       "exports": {name: {architecture: sorted(candidate.EXPORTS) for architecture in values}
                                   for name, values in candidate.ARCHITECTURES.items()}}
            (root / "candidate.json").write_text(json.dumps(receipt))

    def mutate_receipt(self, change):
        path = self.second / "candidate.json"
        receipt = json.loads(path.read_text())
        change(receipt)
        path.write_text(json.dumps(receipt))

    def compare(self):
        return candidate.compare_candidates(self.first, self.second, "a" * 40, "b" * 64)

    def test_complete_pair_matches_without_granting_distribution(self):
        result = self.compare()
        self.assertEqual(result["status"], "complete-candidates-match")
        self.assertFalse(result["distributionApproved"])

    def test_partial_target_is_rejected(self):
        self.mutate_receipt(lambda receipt: receipt["targets"].pop())
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            self.compare()

    def test_bytes_changed_after_receipt_are_rejected(self):
        name = next(name for name in candidate.ARTIFACTS if name.endswith(".a"))
        (self.second / name).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Hash mismatch"):
            self.compare()

    def test_changed_source_identity_is_rejected_even_with_equal_binaries(self):
        self.mutate_receipt(lambda receipt: receipt.update(sourceCommit="c" * 40))
        with self.assertRaisesRegex(ValueError, "sourceCommit"):
            self.compare()

    def test_unexpected_export_is_rejected(self):
        self.mutate_receipt(lambda receipt: receipt["exports"]["ios-arm64"]["arm64"].append("_arti_unreviewed"))
        with self.assertRaisesRegex(ValueError, "exports"):
            self.compare()

    def test_partial_architecture_is_rejected(self):
        self.mutate_receipt(lambda receipt: receipt["architectures"]["ios-arm64_x86_64-simulator"].remove("x86_64"))
        with self.assertRaisesRegex(ValueError, "architectures"):
            self.compare()

    def test_equal_receipts_cannot_substitute_the_reviewed_commit_or_lock(self):
        for commit, lock in (("c" * 40, "b" * 64), ("a" * 40, "c" * 64)):
            with self.subTest(commit=commit, lock=lock), self.assertRaisesRegex(ValueError, "reviewed selector"):
                candidate.compare_candidates(self.first, self.second, commit, lock)

    def test_extra_files_directories_and_symlinks_are_rejected(self):
        extra = self.second / "extra.txt"
        extra.write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.compare()
        extra.unlink()
        extra.mkdir()
        with self.assertRaisesRegex(ValueError, "directory"):
            self.compare()
        extra.rmdir()
        extra.symlink_to(self.first / "candidate.json")
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.compare()

    def test_duplicate_json_keys_are_rejected(self):
        path = self.second / "candidate.json"
        path.write_text(path.read_text()[:-1] + ',"sourceCommit":"' + "a" * 40 + '"}')
        with self.assertRaisesRegex(ValueError, "Duplicate JSON"):
            self.compare()


if __name__ == "__main__":
    unittest.main()
