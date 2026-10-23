#!/usr/bin/env python3
"""Rebuild isolated native inputs and compare, never refresh, the vendored files."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import subprocess
import sys
import time


NATIVE = "localPackages/Arti"
FRAMEWORK = f"{NATIVE}/Frameworks/arti.xcframework"
HEADER = f"{NATIVE}/Frameworks/include/arti.h"
INPUTS = {
    f"{NATIVE}/{name}" for name in (
        "Cargo.lock", "Cargo.toml", "build-ios.sh", "normalize-archive.py",
        "arti-bitchat/Cargo.toml", "arti-bitchat/cbindgen.toml",
        "arti-bitchat/src/connections.rs", "arti-bitchat/src/controller.rs",
        "arti-bitchat/src/isolation.rs",
        "arti-bitchat/src/lib.rs", "arti-bitchat/src/lifecycle.rs",
        "arti-bitchat/src/socks.rs",
    )
}
ARTIFACTS = {f"{FRAMEWORK}/Info.plist"} | {
    f"{FRAMEWORK}/{slice_name}/{name}"
    for slice_name in ("ios-arm64", "ios-arm64_x86_64-simulator", "macos-arm64_x86_64")
    for name in ("Headers/arti.h", "libarti_bitchat.a")
}
TARGETS = (
    "aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios",
    "aarch64-apple-darwin", "x86_64-apple-darwin",
)
DEFAULT_TIMEOUT_SECONDS = 115 * 60  # Leave cleanup time within the 120-minute job.
INITIAL_FREE = 12 * 1024**3
MINIMUM_FREE = 11 * 1024**3 // 2


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def checked_path(root, relative):
    parts = PurePosixPath(relative)
    if parts.is_absolute() or ".." in parts.parts or str(parts) != relative:
        raise ValueError("Noncanonical manifest path")
    current = root
    for component in parts.parts:
        current = current / component
        if current.is_symlink():
            raise ValueError(f"Symlink refused: {relative}")
    if not current.is_file():
        raise ValueError(f"Missing regular file: {relative}")
    return current


def parse_manifest(text, required):
    entries = {}
    for checksum, relative in re.findall(r"^([0-9a-f]{64})  (.+)$", text, re.MULTILINE):
        if relative in entries:
            raise ValueError("Duplicate manifest path")
        entries[relative] = checksum
    if entries.keys() != required:
        raise ValueError("Manifest must contain exactly the reviewed input and artifact sets")
    return entries


def verify_files(root, expected):
    actual = {name: digest(checked_path(root, name)) for name in sorted(expected)}
    if actual != expected:
        changed = [name for name in actual if actual[name] != expected[name]]
        raise ValueError("Hash mismatch: " + ", ".join(changed))
    return actual


def verify_tree(root, relative, expected):
    directory = root / relative
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Missing regular artifact directory")
    actual_paths = set()
    for current, directories, files in os.walk(directory, followlinks=False):
        for name in directories + files:
            path = Path(current) / name
            if path.is_symlink():
                raise ValueError("Symlink in artifact tree")
        actual_paths.update((Path(current) / name).relative_to(root).as_posix() for name in files)
    if actual_paths != expected.keys():
        raise ValueError("Artifact file set differs from the reviewed manifest")
    return verify_files(root, expected)


def output(command, cwd, env=None):
    return subprocess.check_output(command, cwd=cwd, env=env, text=True).strip()


def require_space(path, minimum):
    if shutil.disk_usage(path).free < minimum:
        raise RuntimeError("Native rebuild free-space floor reached")


def stop_child(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass  # It exited after poll; wait below still reaps it.
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def run_owned(command, cwd, env, deadline, volume):
    require_space(volume, MINIMUM_FREE)
    if time.monotonic() >= deadline:
        raise RuntimeError("Native rebuild deadline reached")
    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                               start_new_session=True)
    try:
        while True:
            require_space(volume, MINIMUM_FREE)
            if time.monotonic() >= deadline:
                raise RuntimeError("Native rebuild deadline reached")
            try:
                code = process.wait(timeout=2)
                if code:
                    raise RuntimeError(f"Native rebuild command failed with exit {code}")
                require_space(volume, MINIMUM_FREE)
                return
            except subprocess.TimeoutExpired:
                continue
    finally:
        stop_child(process)


def check_checkout(checkout, commit):
    if output(["git", "rev-parse", "HEAD"], checkout) != commit:
        raise ValueError("Checkout commit changed")
    if output(["git", "status", "--porcelain", "--untracked-files=no"], checkout):
        raise ValueError("Tracked checkout must remain unchanged")


def rebuild_timeout_seconds(explicit=None):
    if explicit is not None:
        value = int(explicit)
    else:
        raw = os.environ.get("ARTI_CLEAN_REBUILD_TIMEOUT_SECONDS", "").strip()
        value = int(raw) if raw else DEFAULT_TIMEOUT_SECONDS
    if value <= 0:
        raise ValueError("Native rebuild timeout must be positive")
    return value


def rebuild(checkout, work, report, timeout=None):
    deadline = time.monotonic() + rebuild_timeout_seconds(timeout)
    commit = output(["git", "rev-parse", "HEAD"], checkout)
    check_checkout(checkout, commit)
    document = checked_path(checkout, "docs/ARTI-BINARY-PROVENANCE.md")
    manifest = parse_manifest(document.read_text(), INPUTS | ARTIFACTS)
    inputs = {name: manifest[name] for name in INPUTS}
    artifacts = {name: manifest[name] for name in ARTIFACTS}
    tracked_inputs = set(output([
        "git", "ls-files", "--", f"{NATIVE}/Cargo.lock", f"{NATIVE}/Cargo.toml",
        f"{NATIVE}/build-ios.sh", f"{NATIVE}/normalize-archive.py", f"{NATIVE}/arti-bitchat",
    ], checkout).splitlines())
    if tracked_inputs != INPUTS:
        raise ValueError("Tracked native source set differs from the twelve reviewed inputs")
    verify_files(checkout, inputs)
    verify_tree(checkout, FRAMEWORK, artifacts)
    exported_header = digest(checked_path(checkout, HEADER))
    if any(artifacts[name] != exported_header for name in artifacts if name.endswith("/arti.h")):
        raise ValueError("Generated-header reference differs from the vendored headers")
    require_space(work.parent, INITIAL_FREE)
    if report.exists() or report.is_symlink():
        raise ValueError("Result path must be fresh")
    work.mkdir()  # Refuse even an empty preexisting workspace or restored cache.
    source = work / "source"
    for name in sorted(INPUTS):
        destination = source / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(checked_path(checkout, name), destination)
    package = source / NATIVE
    if (package / "target").exists() or (package / "Frameworks").exists():
        raise ValueError("Build source must not contain outputs or cached targets")
    cargo_home, rustup_home, temporary = (work / name for name in ("cargo", "rustup", "tmp"))
    for directory in (cargo_home, rustup_home, temporary):
        directory.mkdir()
    env = os.environ.copy()
    # No inherited compiler/SDK overrides or user caches enter this invocation.
    for name in list(env):
        if name.startswith(("CARGO_", "RUST", "CC_", "CXX_")) or name in (
            "CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "SDKROOT", "SCCACHE_DIR",
            "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET",
            "BASH_ENV", "ENV", "AR", "RANLIB", "BINDGEN_EXTRA_CLANG_ARGS",
        ):
            env.pop(name)
    env.update({
        "CARGO_HOME": str(cargo_home), "RUSTUP_HOME": str(rustup_home),
        "CARGO_BUILD_JOBS": "1",
        "RUSTUP_TOOLCHAIN": "1.96.0", "RUST_TOOLCHAIN": "1.96.0",
        "RUSTC_VERSION": "1.96.0", "CBINDGEN_VERSION": "0.29.4",
        "BUILD_JOBS": "1", "KEEP_BUILD_CACHE": "0", "TMPDIR": str(temporary),
        "DEVELOPER_DIR": "/Applications/Xcode_27.app/Contents/Developer",
        "PATH": str(cargo_home / "bin") + os.pathsep + os.environ["PATH"],
    })
    xcode = output(["xcodebuild", "-version"], source, env)
    if xcode != "Xcode 27.0\nBuild version 27A266a":
        raise ValueError("Exact audited Xcode build is unavailable")
    sdks = {name: output(["xcrun", "--sdk", name, "--show-sdk-version"], source, env)
            for name in ("macosx", "iphoneos", "iphonesimulator")}
    if set(sdks.values()) != {"27.0"}:
        raise ValueError("Exact audited SDK versions are unavailable")
    rustup = shutil.which("rustup")
    rustup_version = output([rustup, "--version"], source, env) if rustup else ""
    if not rustup_version.startswith("rustup 1.29.0 "):
        raise ValueError("Audited rustup bootstrap version is unavailable")
    run_owned([rustup, "toolchain", "install", "1.96.0", "--profile", "minimal", "--no-self-update"],
              source, env, deadline, work)
    rustc = output([rustup, "run", "1.96.0", "rustc", "--version"], source, env)
    cargo = output([rustup, "run", "1.96.0", "cargo", "--version"], source, env)
    if rustc != "rustc 1.96.0 (ac68faa20 2026-05-25)" or cargo != "cargo 1.96.0 (30a34c682 2026-05-25)":
        raise ValueError("Exact audited Rust/Cargo versions are unavailable")
    run_owned([rustup, "target", "add", "--toolchain", "1.96.0", *TARGETS],
              source, env, deadline, work)
    run_owned([rustup, "run", "1.96.0", "cargo", "install", "cbindgen", "--version", "0.29.4", "--locked", "--jobs", "1"],
              source, env, deadline, work)
    cbindgen = cargo_home / "bin/cbindgen"
    if output([str(cbindgen), "--version"], source, env) != "cbindgen 0.29.4":
        raise ValueError("Exact freshly installed cbindgen is unavailable")
    # The unchanged recipe prepends this directory; refuse host cbindgen shadowing.
    resolved = output(["bash", "-c", 'export PATH="$HOME/.cargo/bin:$PATH"; command -v cbindgen'], source, env)
    if Path(resolved) != cbindgen:
        raise ValueError("Recipe would use cbindgen outside the isolated installation")
    verify_files(source, inputs)
    run_owned(["bash", "build-ios.sh"], package, env, deadline, work)
    actual_inputs = verify_files(source, inputs)
    actual_artifacts = verify_tree(source, FRAMEWORK, artifacts)
    actual_header = digest(checked_path(source, HEADER))
    if actual_header != exported_header:
        raise ValueError("Fresh generated exported header differs")
    verify_files(checkout, inputs)
    verify_tree(checkout, FRAMEWORK, artifacts)
    if digest(checked_path(checkout, HEADER)) != exported_header:
        raise ValueError("Checkout exported header changed")
    check_checkout(checkout, commit)
    result = {
        "result": "match", "commit": commit, "source_manifest_sha256": digest(document),
        "tools": {"rustc": rustc, "cargo": cargo, "rustup": rustup_version,
                  "cbindgen": "0.29.4", "xcode": xcode},
        "sdks": sdks, "targets": list(TARGETS), "fresh_target": True,
        "inputs": actual_inputs, "expected_artifacts": artifacts,
        "actual_artifacts": actual_artifacts, "generated_header_sha256": actual_header,
    }
    with report.open("x") as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print("Fresh five-target rebuild matches all seven artifacts and the exported header.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    def interrupted(_signal, _frame):
        raise InterruptedError("Native rebuild interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        rebuild(args.checkout.resolve(), args.work.absolute(), args.report.absolute())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
