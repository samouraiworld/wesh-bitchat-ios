# iOS validation baseline — 13 October 2026

This fork is a validation experiment for Wesh (temporary project name: Weshalor). It preserves BitChat's shipping code while we evaluate its native Bluetooth implementation; it does not decide a production architecture migration.

- Upstream: https://github.com/permissionlesstech/bitchat
- Experiment: https://github.com/samouraiworld/wesh-bitchat-ios
- Pinned upstream SHA: `5e9287fae1e5fea80ca741d4ea669829dc16f144`
- Branch: `chore/validation-foundations`
- Compatibility dependency: `samouraiworld/swift-secp256k1` pinned to `0a1a9f9031b6f86f92eb9b66ef8a6882af531e6f` (upstream 0.21.1 plus compiler disambiguation and regression vectors).
- Patch review: https://github.com/samouraiworld/swift-secp256k1/pull/1
- Toolchain tested: Xcode 27.0 (`27A266a`), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Apple Silicon host.
- Deployment floor: iOS 16.0 (`Configs/Release.xcconfig`, `Package.swift`); macOS support remains upstream scope.

## Results

The original clean upstream baseline failed under the installed toolchain. The narrow compatibility fix now clears full app compilation; signing, installation and physical radio validation remain separate gates.

| Check | Result | Meaning |
| --- | --- | --- |
| Original unsigned upstream simulator build | FAIL, exit 65 | Unmodified `swift-secp256k1` 0.21.1 had an ambiguous `words` lookup at `P256K/UInt256.swift:215` under Swift 6.4 |
| Published dependency fix, full existing suite | PASS | 12 XCTest integer tests, 8 library tests and 37 tests in 10 cryptography suites; ECDSA, Schnorr and ECDH included |
| Final-pin unsigned Debug generic simulator app build | PASS | Full app/share extension; arm64 and x86_64 simulator compilation |
| Unsigned Debug generic iOS-device app build | PASS | Full arm64 device app/share extension at final dependency pin; an unsigned app cannot yet be installed on the iPhone |
| Selected existing iOS simulator app suites | PASS | 146 tests in 9 suites: Nostr/frozen Android private-envelope fixtures, Noise, DM E2E, outbox, read receipts and delivery states |
| Existing BitFoundation SwiftPM suite | PASS | 184 tests in 14 suites |
| Existing BitLogger SwiftPM suite | PASS | 13 tests in one suite |
| Simulator availability | PASS with simulator-service access | iOS 18.6 and iOS 26.5 runtimes available; selected app tests used iPhone 17/iOS 26.5 |
| Physical device inventory | No physical devices listed | Founder has an iPhone 15 and a Samsung Android; OS/Android model and pairing remain to record |
| Physical Bluetooth, background, mixed-platform delivery | NOT RUN | Requires signed devices; simulator tests cannot establish radio reliability |

The fix preserves upstream 0.21.1, its cryptographic algorithms and its three vendored submodule SHAs. `trailingZeroBitCount` explicitly constructs the same `SIMDWrapper<Vector>(wrappedValue: vector)` returned by the existing `words` getter; it does not change the arithmetic or word order. Added 256-bit zero/max and word-boundary vectors. One existing Schnorr test constructs the same UTF-8 bytes with `Array(literal.utf8)` to avoid a second Swift 6.4 accessor ambiguity. No BitChat crypto/routing/branding source was changed. Both the Xcode project and tracked SwiftPM manifest/lockfile consume an exact published Git revision, with fresh remote resolution verified.

The 146 selected app tests ran on dependency commit `4be3a9373b55bdcf62cb4c810241bc9eb99bb290`; the final `0a1a9f9` adds only the dependency's test-input disambiguation. Production dependency source is identical between those commits. Both complete app builds subsequently passed on the final pin. This is targeted app verification, not a claim that every upstream app test was run.

Earlier environment-only attempts are preserved in local logs: custom Xcode package-cache options yielded an empty package graph, and dependency dev-tool artifact resolution exhausted disk before compilation. Standard Xcode resolution recovered the graph; clearing only generated validation caches recovered enough disk for the completed checks. These failures are distinct from the original dependency compiler error. Large disposable build caches were removed after preserving logs, xcresults and app artifacts.

## Reproduce

Run from the fork root. Network access is needed on a cold dependency cache. Build products and raw evidence use ignored `.validation/`; raw logs contain host paths and remain local. Use a fresh result bundle path for each run because Xcode refuses to overwrite one.

```sh
xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .validation/DerivedData-swift64 \
  -clonedSourcePackagesDirPath .validation/SourcePackages-swift64 \
  -resultBundlePath .validation/ios-build-final-pin.xcresult \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .validation/DerivedData-swift64 \
  -clonedSourcePackagesDirPath .validation/SourcePackages-swift64 \
  -resultBundlePath .validation/ios-device-build-swift64.xcresult \
  CODE_SIGNING_ALLOWED=NO build
```

Selected app test command:

```sh
xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath .validation/DerivedData-swift64 \
  -clonedSourcePackagesDirPath .validation/SourcePackages-swift64 \
  -resultBundlePath .validation/ios-tests-swift64.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:bitchatTests_iOS/NostrProtocolTests \
  -only-testing:bitchatTests_iOS/NoiseEncryptionTests \
  -only-testing:bitchatTests_iOS/NoiseProtocolTests \
  -only-testing:bitchatTests_iOS/NoiseCoverageTests \
  -only-testing:bitchatTests_iOS/NoiseEncryptionServiceTests \
  -only-testing:bitchatTests_iOS/ReadReceiptTests \
  -only-testing:bitchatTests_iOS/MessageOutboxStoreTests \
  -only-testing:bitchatTests_iOS/ChatViewModelDeliveryStatusTests \
  -only-testing:bitchatTests_iOS/PrivateChatE2ETests \
  CODE_SIGNING_ALLOWED=NO test
```

Upstream disables parallel iOS test execution because integration fixtures share process-global stores. This selection covers the crypto compatibility and first-DM/delivery foundation; broader CI remains a separate check.

From the compatibility dependency fork at the pinned revision, the passing full suite command was:

```sh
swift test --skip-update --scratch-path .validation/Build \
  --cache-path .validation/Cache --config-path .validation/Config \
  --security-path .validation/Security --disable-sandbox
```

The first run resolves upstream's development tools and requires additional disk/network; `--skip-update` was used after that successful resolution. Swift's package build sandbox was disabled for local validation, independently of the host's tool permissions. The earlier independent BitFoundation/BitLogger runs used analogous scratch/cache/config/security options with `--package-path localPackages/BitFoundation` or `localPackages/BitLogger`.

## Local evidence index

All paths are relative to the iOS fork root; evidence is excluded from version control.

- `.validation/logs/ios-build-pristine.log` and `.validation/ios-build-pristine.xcresult`: original unmodified dependency compiler failure.
- `.validation/logs/ios-build-final-pin.log` and `.validation/ios-build-final-pin.xcresult`: passing final-pin full simulator build.
- `.validation/logs/ios-device-build-swift64.log` and `.validation/ios-device-build-swift64.xcresult`: passing unsigned device build.
- `.validation/logs/ios-tests-swift64.log` and `.validation/ios-tests-swift64.xcresult`: passing 146 selected app tests.
- `.validation/logs/spm-pin-resolution.log`: tracked SwiftPM lockfile regenerated from final remote revision.
- `.validation/artifacts/iphoneos/bitchat.app` and `.validation/artifacts/simulator/bitchat.app`: preserved unsigned products.
- `.validation/logs/BitFoundation-tests.log` and `.validation/logs/BitLogger-tests.log`: passing independent baseline suites.
- Dependency fork's `.validation/logs/dependency-tests-swift64.log`: passing full dependency suite; earlier diagnostic logs remain alongside it.

Publish only sanitized summaries. Keep device identifiers, identities, keys, signed installation artifacts, screenshots with personal content, and raw logs out of public PRs. Disposable DerivedData and dependency-test caches were cleaned after verification; reproduce commands recreate them.

## Real-device prerequisites

1. The compiler blocker is cleared. Record exact iOS and Android source SHAs/build variants and the pinned compatibility revision; freeze both for a comparable test session.
2. Start direct mixed-platform smoke testing with the founder’s one iPhone and one Android after recording their models/OS versions. Borrow at least one additional iPhone and Android for same-platform controls and mixed multi-hop checks, then expand to the proposed 8–12-device field matrix. Include an iOS 16 device to verify the declared floor rather than assuming the latest simulator proves it.
3. Pair/unlock the iPhones with Xcode, enable Developer Mode where required, and obtain a signing team with capabilities needed by the app and share extension. Copy `Configs/Local.xcconfig.example` to ignored `Configs/Local.xcconfig`; set your own team, unique bundle ID, and registered App Group. Do not use upstream signing identities or commit local signing settings.
4. The unsigned Debug device variant compiles. Select the founder’s development team in Xcode and confirm its app, extension and App Group registration/profiles; a matching team was found locally, but no matching Wesh/BitChat provisioning profile was present. Do not guess provisioning identifiers or publish account metadata. Then build with signing, install through Xcode on the iPhone 15, and confirm Bluetooth permission prompts. Device installation, signing, and radio tests were not performed in this run.
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
