# iOS validation baseline — 13 October 2026

This fork is a validation experiment for Wesh (temporary project name: Weshalor). It preserves BitChat's shipping code while we evaluate its native Bluetooth implementation; it does not decide a production architecture migration.

- Upstream: https://github.com/permissionlesstech/bitchat
- Experiment: https://github.com/samouraiworld/wesh-bitchat-ios
- Pinned upstream SHA: `5e9287fae1e5fea80ca741d4ea669829dc16f144`
- Branch: `chore/validation-foundations`
- Toolchain tested: Xcode 27.0 (`27A266a`), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Apple Silicon host.
- Deployment floor: iOS 16.0 (`Configs/Release.xcconfig`, `Package.swift`); macOS support remains upstream scope.

## Results

| Check | Result | Meaning |
| --- | --- | --- |
| Public Swift dependency resolution using clean DerivedData | PASS | `swift-secp256k1` resolves to pinned 0.21.1; three local packages resolve |
| Unsigned Debug simulator app build, generic simulator destination | FAIL, exit 65 | `P256K/UInt256.swift:215`: ambiguous use of `words` under Swift 6.4 |
| Existing app SwiftPM messaging/Noise test selection | BLOCKED, exit 1 | Same dependency compilation failure; no selected app tests ran |
| Existing BitFoundation SwiftPM suite | PASS | 184 tests in 14 suites |
| Existing BitLogger SwiftPM suite | PASS | 13 tests in one suite |
| Simulator availability | PASS with access to simulator services | iOS 18.6 and iOS 26.5 runtimes available |
| Physical device inventory | No physical devices listed | Pair/unlock real test devices before field validation |
| Physical Bluetooth, background, mixed-platform delivery | NOT RUN | Requires signed devices; simulator tests cannot establish radio reliability |

The first build used custom package cache options and reported all package products missing. Explicit resolution in that configuration returned an empty package graph. Retrying standard Xcode dependency options with clean DerivedData resolved the graph. That first error is an environment/configuration diagnostic, not a confirmed upstream source defect. The subsequent compiler error is a reproducible compatibility blocker between the pinned upstream dependency and this installed toolchain. No crypto, routing, app configuration, or dependency source was changed to mask it.

Next: reproduce with an upstream-compatible Xcode 26 toolchain on another machine/CI; this host has only Xcode 27 installed. If that passes, pin the sprint toolchain. Otherwise prepare a narrowly reviewed upstream dependency compatibility fix and rerun the app build plus cryptography/interoperability suites before claiming the baseline works.

## Reproduce

Run from the fork root. Network access is needed on a cold dependency cache. Build products and evidence stay in ignored `.validation/`; raw logs contain host paths and must remain local.

```sh
xcodebuild -resolvePackageDependencies \
  -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -derivedDataPath .validation/DerivedData-pristine \
  -clonedSourcePackagesDirPath .validation/SourcePackages-pristine

xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .validation/DerivedData-pristine \
  -clonedSourcePackagesDirPath .validation/SourcePackages-pristine \
  -resultBundlePath .validation/ios-build-pristine.xcresult \
  CODE_SIGNING_ALLOWED=NO build
```

Choose a new result bundle path for each run; Xcode refuses to overwrite one. The build attempted both generic simulator architectures; the recorded compiler failure occurred compiling x86_64. SwiftPM separately reproduced it on arm64.

Exact app test command attempted:

```sh
TMPDIR="$PWD/.validation/tmp" \
CLANG_MODULE_CACHE_PATH="$PWD/.validation/SwiftModuleCache" \
swift test --scratch-path .validation/swift-build \
  --cache-path .validation/swift-cache \
  --config-path .validation/swift-config \
  --security-path .validation/swift-security --disable-sandbox \
  --filter 'NoiseTest|ReadReceiptTests|FragmentationTests|MessageOutboxStoreTests|Delivery'
```

The independent suite commands used the same Swift cache/config/security options and `--disable-sandbox`, plus `--package-path localPackages/BitFoundation --scratch-path .validation/BitFoundation-build` or `--package-path localPackages/BitLogger --scratch-path .validation/BitLogger-build`. Their environment set `TMPDIR="$PWD/.validation/tmp"`. Swift's package build sandbox was disabled for this local validation run; this flag does not bypass the host's tool permissions.

After the app compilation blocker clears, run the existing iOS suite:

```sh
xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath .validation/DerivedData-pristine \
  -clonedSourcePackagesDirPath .validation/SourcePackages-pristine \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

This simulator test command is a next step, not a completed check. Upstream disables parallel iOS test execution because integration fixtures share process-global stores.

## Local evidence index

All paths are relative to the fork root; evidence is excluded from version control.

- `.validation/logs/ios-build.log`: initial missing-package environment failure.
- `.validation/logs/pristine-resolution.log`: successful dependency resolution.
- `.validation/logs/ios-build-pristine.log` and `.validation/ios-build-pristine.xcresult`: definitive simulator compiler failure.
- `.validation/logs/swift-targeted-tests.log`: independent arm64 reproduction while compiling app tests.
- `.validation/logs/BitFoundation-tests.log`: passing protocol/model tests.
- `.validation/logs/BitLogger-tests.log`: passing logger sanitization tests.
- `.validation/SourcePackages-pristine/` and `.validation/DerivedData-pristine/`: dependency checkout and compiler artifacts.

Publish only sanitized summaries. Keep device identifiers, identities, keys, signed installation artifacts, screenshots with personal content, and raw logs out of public PRs.

## Real-device prerequisites

1. Clear the compiler blocker and record exact iOS and Android source SHAs/build variants. Freeze both for a comparable test session.
2. Start direct mixed-platform smoke testing with the founder’s one iPhone and one Android after recording their models/OS versions. Borrow at least one additional iPhone and Android for same-platform controls and mixed multi-hop checks, then expand to the proposed 8–12-device field matrix. Include an iOS 16 device to verify the declared floor rather than assuming the latest simulator proves it.
3. Pair/unlock the iPhones with Xcode, enable Developer Mode where required, and obtain a signing team with capabilities needed by the app and share extension. Copy `Configs/Local.xcconfig.example` to ignored `Configs/Local.xcconfig`; set your own team, unique bundle ID, and registered App Group. Do not use upstream signing identities or commit local signing settings.
4. Build the Debug device variant with the local configuration, install through Xcode, and confirm Bluetooth permission prompts. Device installation, signing, and radio tests were not performed in this run.
5. Use disposable tester identities and synthetic messages. Record pseudonymous handset labels, model/OS, battery level, permissions, app lifecycle, transport, message attempt number, observed receipt state, and timestamps in private evidence.
6. Disable cellular and Wi-Fi for offline scenarios. With airplane mode enabled, explicitly re-enable Bluetooth and verify its state in Settings on both platforms. Keep internet-enabled/Nostr scenarios separate so fallback cannot create a false Bluetooth pass.

## First field sequence

| Scenario | Steps and evidence |
| --- | --- |
| Direct mixed-platform DM | iOS → Android and Android → iOS, then same-platform control pairs. Send numbered short texts and one accented/emoji text. Measure discovery, send, recipient display and sender confirmation times. |
| Trusted-contact setup | Exercise the actual upstream contact verification flow available on each client; record whether equivalent trust is supported. Wesh's proposed QR UX is not implemented by this validation branch. |
| Queue/ACK semantics | Disconnect receiver before sending, reconnect, then compare visible state against recipient receipt. `sent` means left the sender; `delivered` requires recipient confirmation. An offline queued/courier state is not an ACK. A read receipt is a separate observation. |
| Background and locked device | Repeat with sender/receiver foreground, background and screen locked for 1, 5 and 15 minutes; observe delivery latency, notifications, retries and duplicated texts. Report each condition, not one combined success rate. |
| Force quit | Explicitly force quit each client in turn, attempt delivery, reopen and observe recovery. Treat this as a separate lifecycle case; do not promise delivery while iOS has suspended/terminated an app. |
| Reconnection and duplicates | Walk out of range or turn Bluetooth off, queue numbered attempts, restore the link; check no false confirmations, losses, reordering or duplicate display. |
| Multi-hop | Use A–B–C with A and C unable to reach directly. Verify a no-B negative control before calling a B-present success a relay result. Repeat with a mixed-platform relay and record geometry. |
| Energy and usability | Repeat realistic 30–60-minute foreground/locked use. Record battery change and whether a novice understands waiting, sent, delivered, failed and contact trust states. |

Build/test success is a prerequisite for this sequence; it is not field evidence. Until real-device measurements exist, Bluetooth range, background delivery and mixed-platform reliability remain unvalidated.
