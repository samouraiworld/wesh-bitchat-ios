#!/usr/bin/env python3
"""Resolve an isolated keystore candidate without updating checkout files or old gates."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

from verify_arti_clean_rebuild import INPUTS, NATIVE, TARGETS, checked_path, digest

BASELINE_COMMIT = "e9567dff391a2c7c2b8d5ddbd0c41365a5d9403e"
LOCK = f"{NATIVE}/Cargo.lock"
MANIFEST = f"{NATIVE}/arti-bitchat/Cargo.toml"


def inventory(data):
    packages = tomllib.loads(data.decode())["package"]
    result = {}
    for package in packages:
        identity = (package["name"], package["version"], package.get("source", "workspace"))
        if identity in result:
            raise ValueError("Duplicate package identity")
        result[identity] = package.get("checksum")
    return result


def additions_only(before, after):
    old, new = inventory(before), inventory(after)
    for identity, checksum in old.items():
        if identity not in new or new[identity] != checksum:
            raise ValueError(f"Existing package removed or changed: {identity}")
    return [{"name": name, "version": version, "source": source, "checksum": new[(name, version, source)]}
            for name, version, source in sorted(new.keys() - old.keys())]


def selected_features(metadata):
    names = {package["id"]: package["name"] for package in metadata["packages"]}
    return {names[node["id"]]: sorted(node["features"]) for node in metadata["resolve"]["nodes"]
            if names[node["id"]].startswith(("arti-", "tor-"))
            or names[node["id"]] in ("rsa", "rustls", "rustls-webpki", "ssh-key")}


def require_client_boundary(features):
    if "keymgr" not in features.get("arti-client", []):
        raise ValueError("arti-client/keymgr setter is unavailable")
    if "keymgr" not in features.get("tor-keymgr", []):
        raise ValueError("Expected transitive keymgr feature is missing")
    if "tor-hsservice" in features:
        raise ValueError("Unexpected onion service package")
    forbidden = {
        "arti-client": {"onion-service-service", "onion-service-client", "onion-service-cli-extra", "experimental-api", "ctor-keystore", "ephemeral-keystore"},
        "tor-proto": {"relay"}, "tor-llcrypto": {"relay"}, "tor-cert": {"x509"},
    }
    for package, disallowed in forbidden.items():
        unexpected = set(features.get(package, [])) & disallowed
        if unexpected:
            raise ValueError(f"Unexpected surface {package}: {sorted(unexpected)}")


def command(arguments, cwd):
    return subprocess.check_output(arguments, cwd=cwd, timeout=240, text=True)


def sanitized_metadata(value, replacements):
    if isinstance(value, dict):
        return {name: sanitized_metadata(item, replacements) for name, item in value.items()}
    if isinstance(value, list):
        return [sanitized_metadata(item, replacements) for item in value]
    if isinstance(value, str):
        for source, destination in replacements:
            if source:
                value = value.replace(source, destination)
        if re.search(r"/(?:Users|home|Volumes)/|/private/(?:var|tmp)/|[A-Za-z]:\\Users\\", value):
            raise ValueError("Private host path refused in metadata evidence")
    return value


def probe(checkout, work, evidence):
    commit = command(["git", "rev-parse", "HEAD"], checkout).strip()
    if command(["git", "status", "--porcelain", "--untracked-files=no"], checkout).strip():
        raise ValueError("Tracked checkout must be clean")
    before_inputs = {name: digest(checked_path(checkout, name)) for name in sorted(INPUTS)}
    base_lock = subprocess.check_output(["git", "show", f"{BASELINE_COMMIT}:{LOCK}"], cwd=checkout)
    base_manifest = subprocess.check_output(["git", "show", f"{BASELINE_COMMIT}:{MANIFEST}"], cwd=checkout)
    work.mkdir()  # No restored source, target or mutable shared cache.
    evidence.mkdir()
    for variant in ("baseline", "candidate"):
        source = work / variant
        for name in sorted(INPUTS):
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(checked_path(checkout, name), target)
        if variant == "baseline":
            (source / LOCK).write_bytes(base_lock)
            (source / MANIFEST).write_bytes(base_manifest)
    candidate = work / "candidate"
    # Only the disposable copy may derive new lock entries. Every subsequent
    # metadata/test command is locked, and drift of any existing package is fatal.
    command(["cargo", "+1.96.0", "metadata", "--format-version", "1", "--manifest-path", str(candidate / NATIVE / "Cargo.toml"),
             "--filter-platform", TARGETS[0]], checkout)
    candidate_lock = (candidate / LOCK).read_bytes()
    additions = additions_only(base_lock, candidate_lock)
    results = {}
    for target in TARGETS:
        results[target] = {}
        for variant in ("baseline", "candidate"):
            source = work / variant
            raw = command(["cargo", "+1.96.0", "metadata", "--locked", "--format-version", "1",
                           "--manifest-path", str(source / NATIVE / "Cargo.toml"), "--filter-platform", target], checkout)
            metadata = json.loads(raw)
            features = selected_features(metadata)
            if variant == "candidate":
                require_client_boundary(features)
            results[target][variant] = features
            neutral = sanitized_metadata(metadata, [
                (str(work), "/usr/src/wesh-keystore-probe"),
                (str(checkout), "/usr/src/wesh-ios"),
                (os.environ.get("CARGO_HOME", ""), "/usr/local/cargo"),
            ])
            (evidence / f"{variant}-{target}-metadata.json").write_text(json.dumps(neutral, indent=2, sort_keys=True) + "\n")
        before, after = results[target]["baseline"], results[target]["candidate"]
        results[target]["featureDelta"] = {
            name: {"before": before.get(name, []), "after": after.get(name, [])}
            for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)
        }
    if candidate_lock != (candidate / LOCK).read_bytes():
        raise ValueError("Locked metadata changed the derived lockfile")
    after_inputs = {name: digest(checked_path(checkout, name)) for name in sorted(INPUTS)}
    if before_inputs != after_inputs:
        raise ValueError("Checkout inputs changed during probe")
    (evidence / "Cargo.lock").write_bytes(candidate_lock)
    receipt = {"status": "metadata-only", "candidateCommit": commit, "baselineCommit": BASELINE_COMMIT,
               "existingPackageIdentitiesAndChecksums": "unchanged", "addedPackages": additions,
               "candidateLockSHA256": hashlib.sha256(candidate_lock).hexdigest(),
               "metadataPaths": "neutralized; unexpected private host paths rejected",
               "sourceInputs": before_inputs, "targets": results,
               "nativeCompilation": "not run by metadata probe", "publicRelease": "not approved"}
    (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(f"PASS: metadata for five targets; {len(additions)} added packages; checkout unchanged")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    try:
        probe(args.checkout.resolve(), args.work.absolute(), args.evidence.absolute())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
