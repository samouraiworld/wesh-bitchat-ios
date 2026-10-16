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

It builds release static libraries with size-oriented flags (`opt-level=z`, fat LTO, one codegen unit, `panic=abort`, stripped symbols), normalizes static-archive metadata with `xcrun libtool -static -D`, then packages them with `xcodebuild -create-xcframework`.

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

Tools can also be isolated in an ignored task directory by setting `RUSTUP_HOME` and `CARGO_HOME`, and adding the pinned cbindgen binary to `PATH`. No global toolchain-default change is required. The script fixes its Cargo target directory to the local `target/` used for packaging; `BUILD_JOBS` overrides the default of one job.

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
rustup 1.29.0 (28d1352db 2026-03-05)
cbindgen 0.29.4
Xcode 27.0
Build version 27A266a
```

The earlier July audit found Rust 1.86.0 unable to build this graph because `typed-index-collections@3.4.0` requires Rust 1.90.0 or newer. The refreshed selected graph still declares a maximum dependency MSRV of 1.90.0; the validated rebuild uses the pinned 1.96.0 toolchain.

The build uses `--locked`, one Cargo job by default, and neutral source-path maps for both Rust and C. It normalizes static-archive metadata and writes a stable xcframework `Info.plist`. All five architectures were compiled. A separate repeat of archive normalization and universal packaging produced the same library hashes; this is not a second clean compilation or an independent cross-host reproduction. The generated C header is byte-identical to the previous candidate, all seven expected FFI symbols are present, and the libraries and metadata passed the reviewed private-path-prefix scan.

## Current Artifact Hashes

Input `Cargo.lock` SHA-256: `da9154d833011a9c8ccb05e4ba57c396375f0dced155e3369861831359f66aa5`. The source, lockfile, build recipe, header, and vendored libraries must be reviewed together.

Run this from the repo root to verify the checked-in artifact:

```sh
find localPackages/Arti/Frameworks/arti.xcframework -maxdepth 3 -type f -print0 | sort -z | xargs -0 shasum -a 256
```

Current hashes:

```text
cac99db408280bbef15cae8ce64c8ccdbf2e8863c205168d59f83fe8ab680f94  localPackages/Arti/Frameworks/arti.xcframework/Info.plist
551655904834748c9dc36034fdbc9465e7533aef1e4a6514b4fcc75875b93058  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/Headers/arti.h
84caa16c0316f75a4e861db8e949ec1d2c1aa3ba2eeb282ded73580744da9e38  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/libarti_bitchat.a
551655904834748c9dc36034fdbc9465e7533aef1e4a6514b4fcc75875b93058  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/Headers/arti.h
a0579f3eabf14075f4bc503d5717d9b44854009cc1df2a391cbddff4a8eea24a  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/libarti_bitchat.a
551655904834748c9dc36034fdbc9465e7533aef1e4a6514b4fcc75875b93058  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/Headers/arti.h
275933c4431524ed6ca0ad812fbaccb066f07966d6ad7812292477aea7f5bd68  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/libarti_bitchat.a
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
