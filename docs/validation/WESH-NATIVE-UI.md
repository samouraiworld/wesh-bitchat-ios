# Native Wesh UI validation

This is a native SwiftUI experiment built on the validation branch, not a decision to migrate Wesh's production architecture. The pinned compatibility dependency and the upstream Noise/verification wire formats remain unchanged. This BitChat verification experiment does not claim Wesh RFC0012 compliance or proof of reciprocal verification.

## Implemented

- Native Discussions, Rendez-vous and Réglages tabs with semantic typography, system light/dark surfaces and labelled controls with at least 44-point explicit action targets.
- A public local Bluetooth channel, first-send disclosure, live message timeline and composer, queued/failed diffusion states, local mention mute and participant blocking through the existing stable-identity adapter.
- A separate private inbox enrolled through signed live-screen QR scans. Contacts persist locally. Private sending requires the requested full Noise key to match the actual authenticated session, QR enrollment and local verification; blocked identities cannot send.
- Explicit private text recipient routing, without slash-command interpretation or fallback to a different selected conversation/public channel. Private history is also pinned to its contact identity.
- A native camera scanner and QR presentation, strict existing v1 validation, symmetric five-minute freshness, identity-bound QR cache, and bounded 60-second pending challenges. The badge describes verification on this phone only. Each person scans the other phone before their own outgoing private texts are enabled.
- An optional application-level router policy pins the original recipient Noise key in the encrypted outbox and checks direct sends, reconnect retries and courier deposits. Old unpinned entries cannot transmit while this policy is enabled; upstream consumers with no policy retain their existing behavior.
- Internet relay activation, bridge and gateway are disabled before Wesh runtime startup. Public messages may still relay across Bluetooth phones; this does not guarantee geographic boundaries. Mutual-verification notifications and transitive vouch triggers are suppressed in Wesh mode.
- Local meeting title/place/date/note, explicit erasure, Bluetooth readiness and permission recovery, and truthful French/English Bluetooth/camera permission prompts. Meeting notes are not sent automatically.

## Verification

Final targeted simulator acceptance: **136 tests passed** (31 XCTest and 105 Swift Testing; 11 suites), including the existing private E2E, receipt, router and encrypted outbox tests. New vectors cover ambiguous/malformed QR fields, UTF-8 limits, shared canonical bytes, clock boundaries, local identity rotation, different already-verified recipient keys, QR/session mismatch, replayed response, pending-request replacement and pinned queued retries.

Final full unsigned generic simulator (arm64 and x86_64) and generic iOS-device builds passed on the finished source using the same task-local caches. Raw logs, result bundles, products and synthetic screenshots remain ignored under `.validation/`; no signing identities, physical-device identifiers, personal contacts or machine details are part of this report.

The final logs are `.validation/logs/wesh-ui-acceptance-tests.log`, `wesh-ui-device-final.log` and `wesh-ui-simulator-final.log`. Their associated `.xcresult` bundles use the same stems. Build products remain under `.validation/DerivedData-wesh-ui/Build/Products/`.

Physical mixed-platform Bluetooth, reciprocal QR scanning, background/restart behavior, radio range, camera availability and accessibility on hardware still need the real-device sprint. A simulator build/test pass cannot validate Bluetooth operation. The private gate deliberately requires a current authenticated session; a disconnected contact retains its history and draft but cannot send until it reconnects and passes the identity gate.

## Reproduce

Use the existing `bitchat (iOS)` scheme with `CODE_SIGNING_ALLOWED=NO`, `-derivedDataPath .validation/DerivedData-wesh-ui` and `-clonedSourcePackagesDirPath .validation/SourcePackages-wesh-ui`.

For builds, run `xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' -configuration Debug` with `-sdk iphonesimulator -destination 'generic/platform=iOS Simulator'` or `-sdk iphoneos -destination 'generic/platform=iOS'`, those cache/signing arguments, and `build`.

For targeted tests, use an available iPhone simulator destination, `-parallel-testing-enabled NO`, the same cache/signing arguments and `test`. Select `bitchatTests_iOS/` suites: WeshNativeUITests, VerificationServiceTests, ChatVerificationCoordinatorContextTests, ChatOutgoingCoordinatorContextTests, NetworkActivationServiceTests, NetworkReachabilityGateTests, ChatViewModelDeliveryStatusTests, PrivateChatE2ETests, ReadReceiptTests, MessageRouterTests and MessageOutboxStoreTests. Preserve logs locally; do not commit raw build or device outputs.
