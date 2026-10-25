#!/usr/bin/env python3
"""Build/compare complete isolated candidates; never refresh the checked-in xcframework."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

from verify_arti_clean_rebuild import (
    ARTIFACTS, DEFAULT_TIMEOUT_SECONDS, FRAMEWORK, HEADER, INITIAL_FREE,
    INPUTS, NATIVE, TARGETS, check_checkout, checked_path, digest,
    output, require_space, run_owned, verify_files, verify_tree,
)

EXPORTS = {"_arti_start", "_arti_stop", "_arti_is_running", "_arti_bootstrap_progress",
           "_arti_bootstrap_summary", "_arti_go_dormant", "_arti_wake"}
ARCHITECTURES = {"ios-arm64": {"arm64"}, "ios-arm64_x86_64-simulator": {"arm64", "x86_64"},
                 "macos-arm64_x86_64": {"arm64", "x86_64"}}


def compare_candidates(first, second):
    receipts = []
    for root in (first, second):
        receipt = json.loads(checked_path(root, "candidate.json").read_text())
        if receipt.get("status") != "complete-candidate" or receipt.get("targets") != list(TARGETS):
            raise ValueError("Incomplete five-target candidate")
        if set(receipt.get("artifacts", {})) != ARTIFACTS | {HEADER}:
            raise ValueError("Incomplete candidate artifact set")
        if set(receipt.get("inputs", {})) != INPUTS:
            raise ValueError("Incomplete candidate input set")
        if receipt.get("architectures") != {name: sorted(values) for name, values in ARCHITECTURES.items()}:
            raise ValueError("Incomplete candidate architectures")
        expected_exports = {name: {architecture: sorted(EXPORTS) for architecture in sorted(values)}
                            for name, values in ARCHITECTURES.items()}
        if receipt.get("exports") != expected_exports:
            raise ValueError("Unexpected candidate exports")
        verify_tree(root, FRAMEWORK, {name: receipt["artifacts"][name] for name in ARTIFACTS})
        verify_files(root, {HEADER: receipt["artifacts"][HEADER]})
        receipts.append(receipt)
    for key in ("sourceCommit", "inputs", "tools", "sdks", "targets", "artifacts", "exports", "architectures"):
        if receipts[0].get(key) != receipts[1].get(key):
            raise ValueError(f"Independent candidate mismatch: {key}")
    return {"status": "complete-candidates-match", "sourceCommit": receipts[0]["sourceCommit"],
            "inputs": receipts[0]["inputs"], "artifacts": receipts[0]["artifacts"],
            "targets": list(TARGETS), "distributionApproved": False}


def build_candidate(checkout, work, destination, expected_commit, expected_lock):
    if not re.fullmatch(r"[0-9a-f]{40}", expected_commit) or not re.fullmatch(r"[0-9a-f]{64}", expected_lock):
        raise ValueError("Exact reviewed source and lock hashes required")
    check_checkout(checkout, expected_commit)
    inputs = {name: digest(checked_path(checkout, name)) for name in sorted(INPUTS)}
    tracked = set(output(["git", "ls-files", "--", f"{NATIVE}/Cargo.lock", f"{NATIVE}/Cargo.toml",
                          f"{NATIVE}/build-ios.sh", f"{NATIVE}/normalize-archive.py", f"{NATIVE}/arti-bitchat"], checkout).splitlines())
    if tracked != INPUTS:
        raise ValueError("Tracked native source set differs from the reviewed twelve inputs")
    if inputs[f"{NATIVE}/Cargo.lock"] != expected_lock:
        raise ValueError("Candidate lock differs from reviewed metadata")
    header_hash = digest(checked_path(checkout, HEADER))
    old_artifacts = {name: digest(checked_path(checkout, name)) for name in sorted(ARTIFACTS)}
    require_space(work.parent, INITIAL_FREE)
    work.mkdir()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Candidate destination must be fresh")
    source = work / "source"
    for name in sorted(INPUTS):
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(checked_path(checkout, name), target)
    cargo_home, rustup_home, temporary = (work / name for name in ("cargo", "rustup", "tmp"))
    for directory in (cargo_home, rustup_home, temporary):
        directory.mkdir()
    env = os.environ.copy()
    for name in list(env):
        if name.startswith(("CARGO_", "RUST", "CC_", "CXX_")) or name in (
            "CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "SDKROOT", "SCCACHE_DIR",
            "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET", "BASH_ENV", "ENV",
            "AR", "RANLIB", "BINDGEN_EXTRA_CLANG_ARGS",
        ):
            env.pop(name)
    env.update({"CARGO_HOME": str(cargo_home), "RUSTUP_HOME": str(rustup_home),
                "CARGO_BUILD_JOBS": "1", "RUSTUP_TOOLCHAIN": "1.96.0", "RUST_TOOLCHAIN": "1.96.0",
                "RUSTC_VERSION": "1.96.0", "CBINDGEN_VERSION": "0.29.4", "BUILD_JOBS": "1",
                "KEEP_BUILD_CACHE": "0", "TMPDIR": str(temporary),
                "DEVELOPER_DIR": "/Applications/Xcode_27.app/Contents/Developer",
                "PATH": str(cargo_home / "bin") + os.pathsep + os.environ["PATH"]})
    deadline = time.monotonic() + DEFAULT_TIMEOUT_SECONDS
    xcode = output(["xcodebuild", "-version"], source, env)
    sdks = {name: output(["xcrun", "--sdk", name, "--show-sdk-version"], source, env)
            for name in ("macosx", "iphoneos", "iphonesimulator")}
    if xcode != "Xcode 27.0\nBuild version 27A266a" or set(sdks.values()) != {"27.0"}:
        raise ValueError("Exact audited Xcode/SDKs unavailable")
    rustup = shutil.which("rustup")
    rustup_version = output([rustup, "--version"], source, env) if rustup else ""
    if not rustup_version.startswith("rustup 1.29.2 "):
        raise ValueError("Exact audited rustup unavailable")
    run_owned([rustup, "toolchain", "install", "1.96.0", "--profile", "minimal", "--no-self-update"], source, env, deadline, work)
    rustc = output([rustup, "run", "1.96.0", "rustc", "--version"], source, env)
    cargo = output([rustup, "run", "1.96.0", "cargo", "--version"], source, env)
    if rustc != "rustc 1.96.0 (ac68faa20 2026-05-25)" or cargo != "cargo 1.96.0 (30a34c682 2026-05-25)":
        raise ValueError("Exact audited Rust/Cargo unavailable")
    run_owned([rustup, "target", "add", "--toolchain", "1.96.0", *TARGETS], source, env, deadline, work)
    run_owned([rustup, "run", "1.96.0", "cargo", "install", "cbindgen", "--version", "0.29.4", "--locked", "--jobs", "1"],
              source, env, deadline, work)
    cbindgen = cargo_home / "bin/cbindgen"
    if output([str(cbindgen), "--version"], source, env) != "cbindgen 0.29.4":
        raise ValueError("Exact freshly installed cbindgen unavailable")
    resolved = output(["bash", "-c", 'export PATH="$HOME/.cargo/bin:$PATH"; command -v cbindgen'], source, env)
    if Path(resolved) != cbindgen:
        raise ValueError("Recipe would use a cbindgen outside isolated installation")
    run_owned(["bash", "build-ios.sh"], source / NATIVE, env, deadline, work)
    verify_files(source, inputs)
    artifacts = {name: digest(checked_path(source, name)) for name in sorted(ARTIFACTS | {HEADER})}
    verify_tree(source, FRAMEWORK, {name: artifacts[name] for name in ARTIFACTS})
    if artifacts[HEADER] != header_hash or any(artifacts[name] != header_hash for name in ARTIFACTS if name.endswith("/arti.h")):
        raise ValueError("Candidate changes the reviewed C header")
    architecture_receipt, export_receipt = {}, {}
    for slice_name, expected in ARCHITECTURES.items():
        name = f"{FRAMEWORK}/{slice_name}/libarti_bitchat.a"
        library = checked_path(source, name)
        actual = set(output(["xcrun", "lipo", "-archs", str(library)], source, env).split())
        if actual != expected:
            raise ValueError(f"Incomplete architectures: {slice_name}")
        architecture_receipt[slice_name] = sorted(actual)
        export_receipt[slice_name] = {}
        for architecture in sorted(actual):
            symbols = output(["xcrun", "nm", "-arch", architecture, "-gU", str(library)], source, env)
            exported = set(re.findall(r"\b(_arti_[a-z_]+)\s*$", symbols, re.MULTILINE))
            if exported != EXPORTS:
                raise ValueError(f"Unexpected C exports: {slice_name}/{architecture}")
            export_receipt[slice_name][architecture] = sorted(exported)
    for name in ARTIFACTS | {HEADER}:
        if re.search(rb"/(?:Users|home|Volumes)/|/private/(?:var|tmp)/|[A-Za-z]:\\Users\\", checked_path(source, name).read_bytes()):
            raise ValueError(f"Private path in candidate: {name}")
    verify_files(checkout, inputs)
    verify_tree(checkout, FRAMEWORK, old_artifacts)
    check_checkout(checkout, expected_commit)
    destination.mkdir()
    for name in sorted(ARTIFACTS | {HEADER}):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(checked_path(source, name), target)
    receipt = {"status": "complete-candidate", "sourceCommit": expected_commit, "inputs": inputs,
               "tools": {"rustc": rustc, "cargo": cargo, "rustup": rustup_version, "cbindgen": "0.29.4", "xcode": xcode},
               "sdks": sdks, "targets": list(TARGETS), "artifacts": artifacts,
               "architectures": architecture_receipt, "exports": export_receipt, "distributionApproved": False}
    (destination / "candidate.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    build = subparsers.add_parser("build")
    for name in ("checkout", "work", "destination"):
        build.add_argument("--" + name, required=True, type=Path)
    build.add_argument("--expected-commit", required=True)
    build.add_argument("--expected-lock", required=True)
    compare = subparsers.add_parser("compare")
    compare.add_argument("first", type=Path)
    compare.add_argument("second", type=Path)
    compare.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    def interrupted(_signal, _frame):
        raise InterruptedError("Candidate build interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.mode == "build":
            build_candidate(args.checkout.resolve(), args.work.absolute(), args.destination.absolute(), args.expected_commit, args.expected_lock)
        else:
            result = compare_candidates(args.first.resolve(), args.second.resolve())
            with args.report.open("x") as stream:
                json.dump(result, stream, indent=2, sort_keys=True)
                stream.write("\n")
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
