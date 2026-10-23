# Arti Binary Provenance

This repo vendors a prebuilt Arti static-library xcframework at:

`localPackages/Arti/Frameworks/arti.xcframework`

SwiftPM links it through `localPackages/Arti/Package.swift` as the binary target named `arti`. Treat changes to this artifact like dependency updates: review the Rust sources, lockfile, build script, produced headers, and artifact hashes together.

## Source Inputs

- Rust workspace: `localPackages/Arti/Cargo.toml`
- Crate: `localPackages/Arti/arti-bitchat`
- Dependency lockfile: `localPackages/Arti/Cargo.lock`
- Build script: `localPackages/Arti/build-ios.sh`
- Exported C header: `localPackages/Arti/Frameworks/include/arti.h`

The crate declares `rust-version = "1.90"` and uses `arti-client` / `tor-rtcompat` `0.38` with minimal Tokio/Rustls features. The current lockfile requires Rust 1.90 or newer. The build script currently targets:

- `aarch64-apple-ios`
- `aarch64-apple-ios-sim`
- `x86_64-apple-ios`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

It builds release static libraries with size-oriented flags (`opt-level=z`, fat LTO, one codegen unit, `panic=abort`, stripped symbols). Packaging copies each Cargo archive into a fresh staging directory, strips and normalizes only that copy with `xcrun libtool -static -D`, then uses `xcodebuild -create-xcframework`. Cargo outputs remain unchanged; strip failures stop the recipe.

## Regenerating The Artifact

From the repo root:

```sh
cd localPackages/Arti
rustup toolchain install 1.96.0
rustup target add --toolchain 1.96.0 aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
rustup run 1.96.0 cargo install cbindgen --version 0.29.4 --locked
./build-ios.sh
```

`build-ios.sh` defaults to the audited `1.96.0` toolchain and refuses a rustc
version other than `1.96.0`; it likewise requires cbindgen `0.29.4`. Set
`RUST_TOOLCHAIN`, `RUSTC_VERSION`, or `CBINDGEN_VERSION` explicitly only when
intentionally updating the binary provenance and hashes below.

Tools can also be isolated in an ignored task directory by setting `RUSTUP_HOME` and `CARGO_HOME`, and adding the pinned cbindgen binary to `PATH`. No global toolchain-default change is required. The script fixes its Cargo target directory to the local `target/` used for packaging; `BUILD_JOBS` overrides the default of one job. On a constrained build volume, set `KEEP_BUILD_CACHE=0`: after each successful target, only its regenerable intermediate directories are deleted. The final archive and shared host build cache remain available.

After rebuilding, verify that:

- `Cargo.lock` changes are intentional and reviewed.
- `Frameworks/include/arti.h` still matches the exported FFI functions used by `TorManager`.
- `Frameworks/arti.xcframework` contains iOS device arm64, universal iOS simulator arm64+x86_64, and universal macOS arm64+x86_64 slices.
- The main app still passes iOS tests and the macOS build.

## Audited Rebuild

The October 2026 artifact below was rebuilt from the reviewed source and lockfile with:

```text
rustc 1.96.0 (ac68faa20 2026-05-25)
cargo 1.96.0 (30a34c682 2026-05-25)
rustup 1.29.2 (d8c92c676 2026-10-21)
cbindgen 0.29.4
Xcode 27.0
Build version 27A266a
```

The earlier July audit found Rust 1.86.0 unable to build this graph because `typed-index-collections@3.4.0` requires Rust 1.90.0 or newer. The refreshed selected graph still declares a maximum dependency MSRV of 1.90.0; the validated rebuild uses the pinned 1.96.0 toolchain.

The 24 October CI refresh accepts rustup 1.29.2, the bootstrap shipped by the pinned GitHub Actions image. This security release updates the bootstrap certificate-validation dependencies; the compiled Rust 1.96.0 toolchain, Cargo, cbindgen, Xcode and SDK pins remain unchanged, and the clean rebuild still compares every generated artifact byte-for-byte.

The 18 October refresh uses `--locked`, one Cargo job, the same shipping release flags and neutral Rust/C source-path maps. It compiled all five targets and packaged their iOS device, universal simulator and universal macOS libraries. The preceding partial attempt stopped after three targets when macOS rejected a build-time macro; that incomplete attempt is not a validated artifact.

Rust 1.96 can emit a stripped build-time macro dylib with a misaligned LINKEDIT string pool on macOS 27 ([upstream issue](https://github.com/rust-lang/rust/issues/157750)). A metadata-only probe reproduced that loader error. The workspace now sets `profile.release.build-override.strip = "none"`; shipping static libraries retain `strip = "symbols"` and the existing target flags. The constrained-volume recipe also preserves the shared host macro cache instead of relying on this Cargo version's incorrectly scoped target cleanup.

The initial recipe stripped its Cargo outputs in place. Packaging now strips fresh staging copies and leaves all five raw Cargo archives unchanged. Repeating that corrected stage exposed four unused TOC string-alignment bytes in one simulator slice. The final recipe validates archive/member/symbol-reference extents and zeros only the unreferenced 0–7-byte TOC alignment tail. Object payloads, referenced symbols, relocations, archive headers and fat offsets remain unchanged. Ten synthetic preservation/corruption contracts pass.

The preceding domain-only parser refresh compiled all five targets before adding the padding-only normalization step. Two packaging passes over those retained raw inputs were identical. That result is local packaging stability, not independent cross-host or clean-host reproducibility.

This lifecycle refresh recompiles all five targets with the complete reviewed recipe, including padding normalization. Each native session now owns its runtime, client, listener, bootstrap task and accepted handlers. Stop closes admission, requests cancellation, joins owned work and drops the complete runtime before reporting success. A missed teardown deadline or unconfirmed cleanup remains latched until process restart; it cannot publish Ready or admit a new session. Generation checks fence stale status and cleanup. Swift also owns and cancels readiness/liveness tasks, and each connection probe serializes transport startup, cancellation and continuation completion.

The generated header documents the conservative shutdown status while retaining all seven C function declarations. The locked dependency graph and shipping release flags are unchanged. Source-path tests pass four bootstrap cases, two handler-ownership cases, thirteen controller cases and thirteen SOCKS cases. The Swift ownership regressions were reproduced before the fix; the preceding lifecycle library passed 20 Swift package cases and 30 targeted application cases. Full exact-head CI remains required for the updated library.

An initial 200 ms acknowledgment budget proved insufficient for active cleanup while correctly retaining the closed failure latch. The native wait is now bounded at two seconds, with immediate admission closure and the same full-runtime destruction barrier. A genuine timeout still latches permanently. The precise operation responsible for the measured cleanup tail was not identified. Swift's separate stop poll starts after the native call; this change does not establish a total failed-call duration below five seconds.

All five targets were freshly compiled with this final source and recipe. Architecture, seven-function FFI, generated-header and private-path checks pass. Repeating complete packaging over the immutable compiled inputs produces the same seven hashes; all five raw archives and eleven reviewed source inputs remain unchanged. This is local packaging stability, not independent clean-host reproducibility.

A child linked to the final arm64 macOS library passed bootstrap-stop, double-start and four start/stop races, plus cold and warm active shutdown using the same private Tor state. All nine observed stops acknowledged only with stopped status, zero progress and a refused listener. Both accepted handshake sockets closed; active acknowledgments measured approximately 291 ms cold and 235 ms warm, followed by 1.5-second no-late-readiness checks. Every child was reaped before its temporary state was removed. These are bounded native lifecycle observations, not independent packet-quiescence measurements or iOS-device qualification.

Exact-head CI, integrated OFF/panic behavior, packet captures, physical-device gates and unresolved native dependency review remain required. No public-release verdict follows from these local checks.

The 21 October SOCKS refresh changes only the listener, as Android #28 did. The proxy now accepts nothing but the RFC 1929 username/password set for each start: no-auth clients get "no acceptable method" and a wrong login is refused before any request is read, and credentials never print. `arti_start` takes the port and the login from the caller, which picks a new random port in 10000–32767 and new 128-bit credentials for each start. Each destination host gets its own isolation token, so streams to two relays never share a circuit. The C API keeps seven functions; only `arti_start` gains the two credential parameters, and -6 reports an invalid login. `Cargo.lock` and the release flags are unchanged. All five targets were rebuilt with `BUILD_JOBS=3 KEEP_BUILD_CACHE=0` and the same pinned rustc 1.96.0 and cbindgen 0.29.4. 37 crate tests and 22 Swift package tests pass, including a URLSession login against a fake proxy.

## Audited Source And Recipe Hashes

These hashes bind the reviewed source and recipe to this build record. CI compares the complete tracked Arti crate, lockfile and recipe set; changing a source without refreshing this record fails the gate. This consistency check complements binary review and does not independently prove a compilation.

```text
da9154d833011a9c8ccb05e4ba57c396375f0dced155e3369861831359f66aa5  localPackages/Arti/Cargo.lock
9a79b3f9717e29b705bc42e7b889d2fad8d537e141a0df7151e0fee3eacdae3b  localPackages/Arti/Cargo.toml
77099504353b19d9e20f08685a004fda52a20f69d0c2f7068cc5f709d5fb5793  localPackages/Arti/arti-bitchat/Cargo.toml
f96c53d5c449a37739dcb8c2f513fbff2aa7b5ea1c0b9d4963108aa25696be0b  localPackages/Arti/arti-bitchat/cbindgen.toml
dfd4262666f5555b85c93f88a256f11ed16fdc119a3367c93bfb916416711df4  localPackages/Arti/arti-bitchat/src/connections.rs
9a7afba1ce0baf6724d85c4c0fe71c86e48d0515d527f11abdf9e945c34e0269  localPackages/Arti/arti-bitchat/src/controller.rs
0430dc1e3983df03cc9f6ef65098fa34918d7ac29701a65152bb7989e50214ae  localPackages/Arti/arti-bitchat/src/isolation.rs
87092d7f0b888b33acfb5aaf80f18c2aecf107f9cfef467150b12132e84aacee  localPackages/Arti/arti-bitchat/src/lib.rs
f70f1f32efcac8cc8ec8e272686a5d1877c8e3bfd4f93eeee0e72e14a15bb912  localPackages/Arti/arti-bitchat/src/lifecycle.rs
9ced36c42318abd8910984fb12e10f3d2b70af59ec382aceea2c7f26689e8174  localPackages/Arti/arti-bitchat/src/socks.rs
a7eeae2a6c7d9afd2a288a2f8c106e50e3d6a66e6f28eb12eacb1e4d349c59e3  localPackages/Arti/build-ios.sh
6e440299177e019d88825ec0a78a36664a6a764e67f0ae130e120f88bc60d3f1  localPackages/Arti/normalize-archive.py
```

## Current Artifact Hashes

Input `Cargo.lock` SHA-256: `da9154d833011a9c8ccb05e4ba57c396375f0dced155e3369861831359f66aa5`. The source, lockfile, build recipe, header, and vendored libraries must be reviewed together.

Run this from the repo root to verify the checked-in artifact:

```sh
find localPackages/Arti/Frameworks/arti.xcframework -maxdepth 3 -type f -print0 | sort -z | xargs -0 shasum -a 256
```

Current hashes:

```text
cac99db408280bbef15cae8ce64c8ccdbf2e8863c205168d59f83fe8ab680f94  localPackages/Arti/Frameworks/arti.xcframework/Info.plist
aeecab4c48d6aedb7cc7479606f7671a418d4cb6eeec642cf0a46f06a3aebf6c  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/Headers/arti.h
aa3c7ae2ecbde84ba5f0918a723452547bdc858225566b46a27c0075f242ed58  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/libarti_bitchat.a
aeecab4c48d6aedb7cc7479606f7671a418d4cb6eeec642cf0a46f06a3aebf6c  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/Headers/arti.h
07397ba815890faee373cd91cb0e905fd4fa097add2cd5b3c10b25ed42d570f9  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/libarti_bitchat.a
aeecab4c48d6aedb7cc7479606f7671a418d4cb6eeec642cf0a46f06a3aebf6c  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/Headers/arti.h
c5c9827454723d1da5d3f81d7d36c83bd372666a8562bafd78c4070182c44c85  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/libarti_bitchat.a
```

## Review Checklist

- Record `rustc --version`, `cargo --version`, `cbindgen --version`, and `xcodebuild -version` in the PR when refreshing the binary.
- Include the hash output above after any binary change.
- If a rebuild changes only xcframework/library bytes, record the new hashes and app validation evidence in the PR.
- Keep `target/`, `.build/`, and `.swiftpm/` out of source control.
- Do not accept an xcframework-only update without matching source, lockfile, or build-script evidence explaining where it came from.

## Native dependency review (October 2026)

The Arti 0.38 client and exported C API are retained. The reviewed lockfile updates
Rustls to **0.23.46** and rustls-webpki to **0.103.15**, together with compatible
security patches for bytes, crossbeam-epoch, time, event-listener, keccak,
memmap2, both rand branches, and spin. time-core, time-macros, and num-conv follow
the selected time patch; event-listener no longer requires concurrent-queue.
The selected iOS dependency graph's highest declared MSRV remains Rust 1.90.

RustSec references:

- [Rustls handshake boundary correction](https://rustsec.org/advisories/RUSTSEC-2026-0285.html)
- [Rustls session Debug redaction](https://rustsec.org/advisories/RUSTSEC-2026-0346.html)
- [Rustls ECH rejection ordering](https://rustsec.org/advisories/RUSTSEC-2026-0347.html)
- [Rustls Brotli allocation bounds](https://rustsec.org/advisories/RUSTSEC-2026-0348.html)
- [Rustls key-share prediction](https://rustsec.org/advisories/RUSTSEC-2026-0349.html)
- [WebPKI CRL parsing correction](https://rustsec.org/advisories/RUSTSEC-2026-0104.html)

These advisories have different version and configuration conditions. In
particular, Rustls 0.23.36 was outside the ECH advisory's affected version range;
the selected Rustls features are `log`, `logging`, `ring`, `std`, and `tls12`.
A version audit alone does not establish exploitation in the native app.

The final reviewed lockfile still reports **RUSTSEC-2023-0071** for `rsa 0.9.10`
(no patched version published), plus maintenance notices for `bincode`, `paste`,
and `proc-macro-error2`. No audit entries are ignored. RSA is present in the
selected Arti graph. The local wrapper exposes client startup, shutdown,
bootstrap status, and dormancy controls, and starts a stock `TorClient` with a
SOCKS proxy; it does not expose an RSA private-key operation. Arti's low-level
library nevertheless contains RSA key-generation/signing APIs as well as public
signature verification. This scoped review does not prove private operations
unreachable through every transitive path. Internet startup disabled in Wesh
is not evidence that RSA or Arti is absent from the package.

See [the remaining RSA advisory](https://rustsec.org/advisories/RUSTSEC-2023-0071.html).
The candidate remains subject to explicit security qualification of this
unresolved dependency and the maintenance notices; successful app tests or
local export do not resolve that gate.
