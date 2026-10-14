# Contributing to the Wesh iOS candidate

Work on a feature branch and open a pull request. Never commit to `main` or
`master`. The active implementation is `feat/wesh-native-ui` in
[draft PR #2](https://github.com/samouraiworld/wesh-bitchat-ios/pull/2), whose base is
`chore/validation-foundations`. The wider project work is tracked in
[Wesh PR #188](https://github.com/samouraiworld/wesh/pull/188).

## Candidate and evidence boundaries

Local **RC4, version 0.1.0 (5)**, uses source commit
`261e3f1f8c4f85ccc79ead55b582d1c23aef14df`. The universal simulator build and signed
Release device archive passed. The complete iOS test collection passed **2,329
tests** (2,114 Swift Testing tests and 215 XCTest tests), with no failures, skips,
or expected failures. No `-only-testing` or `-skip-testing` filter was applied.
This covers the tests compiled for the iOS simulator; macOS-only conditional code
and physical-device behavior are separate validation scopes.

The focused regression set also passed **228 tests** (173 Swift Testing tests
and 55 XCTest tests). It covers QR identity binding, blocking, drafts, sharing,
routing, delivery states, and network activation. Those 228 are a subset of the
2,329, not an additional count. The full run reported SwiftUI environment/state
access warnings in inherited `ViewSmokeTests`, with no test failures; those smoke
checks do not establish live view updates or accessibility behavior.

The RC4 App Store export attempt stopped because Xcode could not access an Apple
Distribution signing identity/account. Existing RC3 App Store profiles remain
compatible with the RC4 app and extension, but profiles alone cannot sign an IPA.
No RC4 IPA has been produced, uploaded, or validated by Apple's servers. Historical
RC3 artifacts remain associated with their original source commit.

Documentation-only commits after the candidate do not change its source identity.
Local archives, simulator packages, test results, signing details, and raw logs
belong in ignored `.validation/`; do not commit them or substitute an older IPA.

## Simulator build

Use Xcode 27.0 and an installed iOS simulator. Run commands from the repository
root. Resolve the committed package pins once on a fresh checkout:

```sh
mkdir -p .validation
xcodebuild -resolvePackageDependencies -project bitchat.xcodeproj \
  -scheme 'bitchat (iOS)' \
  -clonedSourcePackagesDirPath .validation/SourcePackages-wesh-ui

xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .validation/DerivedData-wesh-ui \
  -clonedSourcePackagesDirPath .validation/SourcePackages-wesh-ui \
  -disableAutomaticPackageResolution -jobs 2 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=NO build
```

The product is under
`.validation/DerivedData-wesh-ui/Build/Products/Debug-iphonesimulator/bitchat.app`.
An ordinary build after tests can retain an embedded test bundle in DerivedData;
inspect a separate staged distribution copy and exclude `.xctest` plugins before
sharing a simulator package. Preserve the app's share extension.

## Candidate regression suites

Choose a dedicated test simulator so tests do not disturb a manual QA session.
RC4 used `iPhone 16 Pro` with iOS 18.6. List available destinations with
`xcodebuild -showdestinations -project bitchat.xcodeproj -scheme 'bitchat (iOS)'`.
The following Bash/Zsh command selects the same suites; use a fresh result-bundle
path for each run:

```sh
suites=(
  WeshNativeUITests WeshDesignSystemTests ComposerDraftStoreTests
  ChatVerificationCoordinatorContextTests UnifiedPeerServiceTests
  SecureIdentityStateManagerTests VerificationServiceTests
  SharedContentHandoffTests MessageRouterTests MessageOutboxStoreTests
  NetworkActivationServiceTests NetworkReachabilityGateTests PrivateChatE2ETests
  ReadReceiptTests ChatViewModelDeliveryStatusTests
  ChatDeliveryCoordinatorContextTests ChatOutgoingCoordinatorContextTests
)
selection=()
for suite in "${suites[@]}"; do
  selection+=("-only-testing:bitchatTests_iOS/$suite")
done
xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -derivedDataPath .validation/DerivedData-wesh-ui \
  -clonedSourcePackagesDirPath .validation/SourcePackages-wesh-ui \
  -disableAutomaticPackageResolution -jobs 2 -parallel-testing-enabled NO \
  -resultBundlePath .validation/wesh-regression.xcresult \
  "${selection[@]}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- test
```

For the full iOS collection, use the same dedicated simulator and cache paths,
without test-selection arguments:

```sh
xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -derivedDataPath .validation/DerivedData-wesh-ui \
  -clonedSourcePackagesDirPath .validation/SourcePackages-wesh-ui \
  -disableAutomaticPackageResolution -jobs 2 -parallel-testing-enabled NO \
  -resultBundlePath .validation/wesh-full-regression.xcresult \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- test
```

## Device signing and local distribution

Copy `Configs/Local.xcconfig.example` to ignored `Configs/Local.xcconfig` and use
the team's authorized app and App Group identifiers. Keep signing credentials,
profiles, and team/device identifiers out of Git and public logs. App and share
extension must use matching version/build numbers and compatible entitlements.

A simulator package does not install on an iPhone. A device archive needs valid
device signing; an App Store export additionally needs accessible Distribution
signing assets. Export options for a local-only export must explicitly set
`method=app-store-connect`, `destination=export`, `uploadSymbols=false`, and
`manageAppVersionAndBuildNumber=false`. Portal access, asset renewal, server
validation, and uploads require their own authorized scope. Never bypass a locked
keychain or change security settings to make an export pass.

## Remaining qualification work

- The rebuilt Arti library still includes `rsa 0.9.10`, affected by
  **RUSTSEC-2023-0071**, with no published patched version. Maintenance notices for
  bincode, paste, and proc-macro-error2 also remain. Read the
  [native source, build recipe, hashes, and audit limits](ARTI-BINARY-PROVENANCE.md).
  Disabled Internet startup does not remove Arti/RSA or establish unreachability.
- Real iPhone/Android Bluetooth, mixed-peer messaging, background/force-quit,
  queued delivery, and airplane-mode/Bluetooth-on behavior still require physical
  testing. Simulator tests do not certify radio behavior or mutual QR scanning.
- Contrast/source checks and simulator visual inspection do not establish
  VoiceOver listening or gesture completion for every flow. Keep spoken output,
  focus/gesture results, and maximum text-size checks as separate QA evidence.
- Successful tests, archive creation, or a future local export do not close these
  security, accessibility, or hardware gates.
