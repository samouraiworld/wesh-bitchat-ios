# Contributing to the Wesh iOS candidate

Work on a feature branch and open a pull request. Never commit to `main` or
`master`. The active implementation is `feat/wesh-native-ui` in
[draft PR #2](https://github.com/samouraiworld/wesh-bitchat-ios/pull/2), whose base is
`chore/validation-foundations`. The wider project work is tracked in
[Wesh PR #188](https://github.com/samouraiworld/wesh/pull/188).

## Candidate and evidence boundaries

Local **RC5, version 0.1.0 (6)**, uses frozen source commit
`140030a19965ee7dd2fa0bfb3b0988359e32d697`. Its universal simulator package,
Release Development archive, and **locally exported App Store IPA** are verified.
App and extension have matching versions, compatible entitlements/profiles,
strict signatures, and archive dSYM UUIDs. The IPA is signed with Apple
Distribution certificates included in its App Store profiles; those certificates
are currently valid and `get-task-allow` is false. **No Apple server validation,
TestFlight upload, or invitation has taken place.**

The complete iOS simulator collection passed **2,333 tests**: **2,114 Swift
Testing tests and 219 XCTest tests**, with no failures, skips, or expected
failures. This includes the four immutable signed-QR interoperability tests;
do not add them again. No `-only-testing` or `-skip-testing` filter was applied.
An initial attempt compiled the test products but stalled in a CoreSimulator
launch request before running any case. That owned Xcode process was interrupted
and its evidence preserved. A complete `test-without-building` retry using the
same frozen products passed with Xcode exit 0 and xcresult `Passed`. The dedicated
iPhone 16 Pro / iOS 18.6 test simulator was confirmed shut down afterward; the
separate Wesh VoiceOver QA simulator was not booted or erased.

RC5 changes launcher artwork and build number; it does not change messaging,
cryptographic source, or the five-architecture Arti libraries rebuilt for RC4.
See the [icon source and rendering guide](WESH-APP-ICON.md) and the
[RC5 validation scope](RC5-VALIDATION.md). Documentation commits after the freeze
do not change artifact provenance. Local archives, packages, IPA files, signing
details, test results, and raw logs belong in ignored `.validation/`.

The synthetic signed QR fixture verifies signature acceptance, canonical encoding,
tamper rejection, and freshness boundaries. Its explicitly public seed must never
be used as a real identity. These API tests do not prove a live camera scan,
current Noise-session challenge, reciprocal verification, or radio exchange. The
packaged simulator app, archive, and IPA contain no XCTest plugins or that fixture.

The complete run reported **39 inherited SwiftUI environment/state access
warnings** in `ViewSmokeTests`, with no test failures. Off-tree smoke assertions
do not establish live updates or accessibility behavior. Interactive RC5
VoiceOver and Safari/share-extension QA remain open: CUA application selection
took 204 seconds despite a requested 30-second timeout, and an earlier call was
interrupted after 812 seconds. GUI work was paused without changing security
settings or using an alternative GUI automation method. This tool latency does
not diagnose the Apple account or the app.

### Historical candidates

RC4 **0.1.0 (5)** remains associated with source
`261e3f1f8c4f85ccc79ead55b582d1c23aef14df`, **2,329 passing iOS tests**, its
Development archive/universal simulator package, and its original inherited blue
launcher artwork. Its focused 228-test set is a subset of those 2,329. The four
signed-QR tests passed separately after the RC4 freeze. RC4 export attempts were
blocked; the successful RC5 export must not be described as an RC4 IPA. All 119
RC4 archive files were rechecked unchanged after RC5 validation.

RC4 visual smoke confirmed silver controls on black, empty Contacts/Discussions,
public-channel information, and Send disabled with unavailable Bluetooth.
VoiceOver showed an initial focus rectangle, without completing speech, rotor,
or gestures. The last interactive Safari/share-extension smoke remains RC3-only.
Do not attribute either historical GUI result to RC5.

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
