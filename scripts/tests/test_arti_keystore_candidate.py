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

    def test_complete_pair_matches_without_granting_distribution(self):
        result = candidate.compare_candidates(self.first, self.second)
        self.assertEqual(result["status"], "complete-candidates-match")
        self.assertFalse(result["distributionApproved"])

    def test_partial_target_is_rejected(self):
        self.mutate_receipt(lambda receipt: receipt["targets"].pop())
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            candidate.compare_candidates(self.first, self.second)

    def test_bytes_changed_after_receipt_are_rejected(self):
        name = next(name for name in candidate.ARTIFACTS if name.endswith(".a"))
        (self.second / name).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Hash mismatch"):
            candidate.compare_candidates(self.first, self.second)

    def test_changed_source_identity_is_rejected_even_with_equal_binaries(self):
        self.mutate_receipt(lambda receipt: receipt.update(sourceCommit="c" * 40))
        with self.assertRaisesRegex(ValueError, "sourceCommit"):
            candidate.compare_candidates(self.first, self.second)

    def test_unexpected_export_is_rejected(self):
        self.mutate_receipt(lambda receipt: receipt["exports"]["ios-arm64"]["arm64"].append("_arti_unreviewed"))
        with self.assertRaisesRegex(ValueError, "exports"):
            candidate.compare_candidates(self.first, self.second)

    def test_partial_architecture_is_rejected(self):
        self.mutate_receipt(lambda receipt: receipt["architectures"]["ios-arm64_x86_64-simulator"].remove("x86_64"))
        with self.assertRaisesRegex(ValueError, "architectures"):
            candidate.compare_candidates(self.first, self.second)


if __name__ == "__main__":
    unittest.main()
