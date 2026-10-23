"""Small synthetic trees exercise the same strict comparison used by the rebuild."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "verify_arti_clean_rebuild.py"
SPEC = importlib.util.spec_from_file_location("arti_clean_rebuild", SCRIPT)
rebuild = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rebuild)


class CleanRebuildComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.expected = {}
        for name, content in {
            "bundle/Info.plist": b"synthetic-plist",
            "bundle/arm64/Headers/arti.h": b"synthetic-declarations",
            "bundle/arm64/libarti_bitchat.a": b"synthetic-library",
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            self.expected[name] = hashlib.sha256(content).hexdigest()

    def test_matching_tree_hashes_actual_bytes_and_does_not_modify_inputs(self):
        before = {name: (self.root / name).read_bytes() for name in self.expected}
        self.assertEqual(rebuild.verify_tree(self.root, "bundle", self.expected), self.expected)
        self.assertEqual({name: (self.root / name).read_bytes() for name in self.expected}, before)

    def test_changed_library_header_and_plist_each_fail_without_refresh(self):
        for name in self.expected:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b"changed")
                with self.assertRaisesRegex(ValueError, "Hash mismatch"):
                    rebuild.verify_tree(self.root, "bundle", self.expected)
                self.assertEqual(path.read_bytes(), original + b"changed")
                path.write_bytes(original)

    def test_missing_output_fails_even_when_other_hashes_match(self):
        (self.root / "bundle/Info.plist").unlink()
        with self.assertRaisesRegex(ValueError, "file set"):
            rebuild.verify_tree(self.root, "bundle", self.expected)

    def test_extra_output_fails_even_when_manifest_entries_match(self):
        (self.root / "bundle/unreviewed.a").write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "file set"):
            rebuild.verify_tree(self.root, "bundle", self.expected)

    def test_symlink_file_and_directory_are_not_accepted_as_matching_outputs(self):
        file = self.root / "bundle/Info.plist"
        file.unlink()
        target = self.root / "other-plist"
        target.write_bytes(b"synthetic-plist")
        file.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            rebuild.verify_tree(self.root, "bundle", self.expected)
        file.unlink()
        file.write_bytes(b"synthetic-plist")
        (self.root / "bundle/alias").symlink_to(self.root / "bundle/arm64", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            rebuild.verify_tree(self.root, "bundle", self.expected)

    def test_changed_source_or_lockfile_fails(self):
        lockfile = self.root / "Cargo.lock"
        lockfile.write_bytes(b"reviewed-lock")
        expected = {"Cargo.lock": hashlib.sha256(lockfile.read_bytes()).hexdigest()}
        self.assertEqual(rebuild.verify_files(self.root, expected), expected)
        lockfile.write_bytes(b"resolved-different-dependency")
        with self.assertRaisesRegex(ValueError, "Hash mismatch"):
            rebuild.verify_files(self.root, expected)

    def test_manifest_requires_complete_set_and_rejects_duplicates(self):
        text = "\n".join(f"{checksum}  {name}" for name, checksum in self.expected.items())
        self.assertEqual(rebuild.parse_manifest(text, set(self.expected)), self.expected)
        for invalid in (text.splitlines()[0], text + "\n" + text.splitlines()[0],
                        text + "\n" + "0" * 64 + "  extra"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                rebuild.parse_manifest(invalid, set(self.expected))

    def test_absolute_parent_and_noncanonical_paths_are_rejected(self):
        for name in ("/etc/passwd", "../outside", "bundle/../Info.plist", "bundle//Info.plist"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Noncanonical"):
                rebuild.checked_path(self.root, name)

    def test_intermediate_symlink_is_refused_by_source_comparison(self):
        (self.root / "alias").symlink_to(self.root / "bundle", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            rebuild.verify_files(self.root, {"alias/Info.plist": self.expected["bundle/Info.plist"]})

    def test_floor_is_hard_failure_without_cleanup_or_launch(self):
        with mock.patch.object(rebuild.shutil, "disk_usage", return_value=mock.Mock(free=0)), \
                mock.patch.object(rebuild.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(RuntimeError, "free-space"):
                rebuild.run_owned(["unused"], self.root, {}, float("inf"), self.root)
            launch.assert_not_called()

    def test_child_failure_propagates_instead_of_producing_success(self):
        process = mock.Mock()
        process.wait.return_value = 23
        process.poll.return_value = 23
        with mock.patch.object(rebuild, "require_space"), \
                mock.patch.object(rebuild.subprocess, "Popen", return_value=process):
            with self.assertRaisesRegex(RuntimeError, "exit 23"):
                rebuild.run_owned(["unused"], self.root, {}, float("inf"), self.root)

    def test_floor_drop_terminates_and_reaps_owned_command(self):
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        process.wait.return_value = -15
        with mock.patch.object(rebuild, "require_space", side_effect=[None, RuntimeError("floor")]), \
                mock.patch.object(rebuild.subprocess, "Popen", return_value=process), \
                mock.patch.object(rebuild.os, "killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "floor"):
                rebuild.run_owned(["unused"], self.root, {}, float("inf"), self.root)
            kill.assert_called_once_with(12345, rebuild.signal.SIGTERM)
            process.wait.assert_called_once_with(timeout=10)

    def test_deadline_refuses_launch_and_nonresponsive_child_is_killed_then_reaped(self):
        with mock.patch.object(rebuild, "require_space"), \
                mock.patch.object(rebuild.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(RuntimeError, "deadline"):
                rebuild.run_owned(["unused"], self.root, {}, 0, self.root)
            launch.assert_not_called()
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("unused", 10), -9]
        with mock.patch.object(rebuild.os, "killpg") as kill:
            rebuild.stop_child(process)
        self.assertEqual(kill.call_args_list, [mock.call(12345, rebuild.signal.SIGTERM),
                                             mock.call(12345, rebuild.signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=10), mock.call()])

    def test_rebuild_timeout_defaults_above_1800s_and_honors_env_override(self):
        self.assertGreaterEqual(rebuild.DEFAULT_TIMEOUT_SECONDS, 1800)
        with mock.patch.dict(rebuild.os.environ, {}, clear=False):
            rebuild.os.environ.pop("ARTI_CLEAN_REBUILD_TIMEOUT_SECONDS", None)
            self.assertEqual(rebuild.rebuild_timeout_seconds(), rebuild.DEFAULT_TIMEOUT_SECONDS)
        with mock.patch.dict(rebuild.os.environ, {"ARTI_CLEAN_REBUILD_TIMEOUT_SECONDS": "1800"}):
            self.assertEqual(rebuild.rebuild_timeout_seconds(), 1800)
        with self.assertRaisesRegex(ValueError, "positive"):
            rebuild.rebuild_timeout_seconds(0)

    def test_child_exiting_between_poll_and_signal_is_still_reaped(self):
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        process.wait.return_value = 0
        with mock.patch.object(rebuild.os, "killpg", side_effect=ProcessLookupError):
            rebuild.stop_child(process)
        process.wait.assert_called_once_with(timeout=10)

    def isolated_checkout(self):
        checkout = self.root / "checkout"
        checksums = {}
        for name in rebuild.INPUTS | rebuild.ARTIFACTS | {rebuild.HEADER}:
            path = checkout / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic-header" if name.endswith("/arti.h") else name.encode())
            checksums[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        document = checkout / "docs/ARTI-BINARY-PROVENANCE.md"
        document.parent.mkdir()
        document.write_text("\n".join(f"{checksums[name]}  {name}"
                                     for name in sorted(rebuild.INPUTS | rebuild.ARTIFACTS)))
        return checkout

    def synthetic_tool_output(self, command, _cwd, env=None):
        if command[:3] == ["git", "rev-parse", "HEAD"]:
            return "a" * 40
        if command[:2] == ["git", "status"]:
            return ""
        if command[:2] == ["git", "ls-files"]:
            return "\n".join(sorted(rebuild.INPUTS))
        if command == ["xcodebuild", "-version"]:
            return "Xcode 27.0\nBuild version 27A266a"
        if command[0] == "xcrun":
            return "27.0"
        if command[-1] == "--version":
            if command[0] == "/synthetic/rustup" and len(command) == 2:
                return "rustup 1.29.0 (28d1352db 2026-03-05)"
            if command[-2] == "rustc":
                return "rustc 1.96.0 (ac68faa20 2026-05-25)"
            if command[-2] == "cargo":
                return "cargo 1.96.0 (30a34c682 2026-05-25)"
            if command[0].endswith("/cbindgen"):
                return "cbindgen 0.29.4"
        if command[0] == "bash":
            return str(Path(env["CARGO_HOME"]) / "bin/cbindgen")
        self.fail(f"Unexpected tool invocation: {command}")

    def test_floor_deadline_and_command_failure_never_write_success_report(self):
        checkout = self.isolated_checkout()
        for reason in ("floor", "deadline", "command"):
            with self.subTest(reason=reason):
                work, report = self.root / reason, self.root / f"{reason}.json"
                with mock.patch.object(rebuild, "output", side_effect=self.synthetic_tool_output), \
                        mock.patch.object(rebuild.shutil, "which", return_value="/synthetic/rustup"), \
                        mock.patch.object(rebuild, "require_space", side_effect=RuntimeError(reason) if reason == "floor" else None), \
                        mock.patch.object(rebuild, "run_owned", side_effect=RuntimeError(reason)):
                    with self.assertRaisesRegex(RuntimeError, reason):
                        rebuild.rebuild(checkout, work, report)
                self.assertFalse(report.exists())

    def test_only_matching_completed_outputs_can_publish_actual_hashes(self):
        checkout = self.isolated_checkout()
        for matching in (False, True):
            with self.subTest(matching=matching):
                work = self.root / f"work-{matching}"
                report = self.root / f"result-{matching}.json"
                invocations = []
                def simulate_compiler(command, cwd, env, _deadline, _volume):
                    invocations.append(command)
                    self.assertEqual(env["CARGO_BUILD_JOBS"], "1")
                    if "cbindgen" in command:
                        self.assertEqual(command[-2:], ["--jobs", "1"])
                    if command == ["bash", "build-ios.sh"]:
                        self.assertFalse((cwd / "target").exists())
                        self.assertFalse((cwd / "Frameworks").exists())
                        for name in rebuild.ARTIFACTS | {rebuild.HEADER}:
                            destination = work / "source" / name
                            destination.parent.mkdir(parents=True, exist_ok=True)
                            destination.write_bytes((checkout / name).read_bytes())
                        if not matching:
                            library = next(name for name in rebuild.ARTIFACTS if name.endswith(".a"))
                            (work / "source" / library).write_bytes(b"different-library")
                with mock.patch.object(rebuild, "output", side_effect=self.synthetic_tool_output), \
                        mock.patch.object(rebuild.shutil, "which", return_value="/synthetic/rustup"), \
                        mock.patch.object(rebuild, "require_space"), \
                        mock.patch.object(rebuild, "run_owned", side_effect=simulate_compiler), \
                        mock.patch("builtins.print"):
                    if matching:
                        rebuild.rebuild(checkout, work, report)
                        result = json.loads(report.read_text())
                        self.assertEqual(result["tools"]["rustup"], "rustup 1.29.0 (28d1352db 2026-03-05)")
                        self.assertEqual(result["actual_artifacts"], {
                            name: hashlib.sha256((work / "source" / name).read_bytes()).hexdigest()
                            for name in rebuild.ARTIFACTS
                        })
                    else:
                        with self.assertRaisesRegex(ValueError, "Hash mismatch"):
                            rebuild.rebuild(checkout, work, report)
                        self.assertFalse(report.exists())
                self.assertIn(["bash", "build-ios.sh"], invocations)


if __name__ == "__main__":
    unittest.main()
