# RC5 local validation — Wesh 0.1.0 (6)

Subsequent source development: [Nostr identity persistence follow-up](IDENTITY-PERSISTENCE-FOLLOWUP.md). This patch is separate from the RC5 artifacts and results below.

The candidate uses frozen source
`140030a19965ee7dd2fa0bfb3b0988359e32d697` on `feat/wesh-native-ui`, in
[draft PR #2](https://github.com/samouraiworld/wesh-bitchat-ios/pull/2).
Subsequent documentation commits are not a new binary source revision.

## Changes and verification

The launcher icon now uses a neutral polished-silver W on an opaque pure-black
canvas. The existing shape is retained. Debug and Release use the same artwork;
the editable SVG and native Swift renderer are documented in
[WESH-APP-ICON.md](WESH-APP-ICON.md). All 22 generated PNG slots have the correct
sizes, opaque pixels, neutral RGB channels, and pure-black corners. A repeat
render produced identical bytes. The actual bundled simulator icons and Apple
PNG-optimized Release/archive/IPA icons were decoded and checked separately.
No messaging source or Arti library changed from the previous source revision.

The full iOS collection passed **2,333 / 2,333** cases: **2,114 Swift Testing and
219 XCTest**, with zero failures, skips, or expected failures. The four synthetic
signed-QR fixture tests are included in that count. No test-selection filters
were used. An initial build-and-test attempt compiled but stalled before any
case in CoreSimulator's app-launch request; its owned process was interrupted
(exit 75). A separate complete `test-without-building` run of the frozen products
then returned Xcode exit 0 and xcresult `Passed`. Both attempts were preserved.
The test destination was iPhone 16 Pro with iOS 18.6, separate from manual QA.

The full run retains **39 inherited ViewSmokeTests warnings** about reading
SwiftUI environment/state outside a live view tree (18 AppTheme, 20 ColorScheme,
1 State). They did not fail tests and do not establish actual view updates,
VoiceOver focus, or spoken output.

The universal simulator app and share extension are version/build **0.1.0 (6)**,
contain arm64 and x86_64 executables, and pass strict ad hoc signature checks.
The Development device archive contains arm64 app/extension executables with
matching versions, profiles, entitlements, App Groups, and dSYM UUIDs. All 119
archive files remained unchanged after export and testing. The simulator ZIP
and exported IPA also retained their original hashes after testing. The separate
RC4 archive's 119 files were rechecked unchanged.

Xcode's authorized automatic signing completed a **local-only App Store export**.
Both IPA bundles pass strict signature checks with Apple Distribution authority;
the signing leaf certificates are current and included in the corresponding
App Store profiles. The profiles contain no device list, `get-task-allow` is
false, app/group entitlements match, and executable UUIDs match the archive's
dSYMs. The app and extension display the name Wesh. No XCTest bundle or shared
synthetic QR fixture is packaged in any of the three candidate products.

Local export used `destination=export`, `uploadSymbols=false`, and
`manageAppVersionAndBuildNumber=false`. **No Apple server validation, upload,
TestFlight invitation, or release was performed.** A successful export proves
this artifact's signing, not permanent availability of a future local identity.

## Local evidence locations

These files are deliberately ignored, with no signing assets or raw logs in Git:

- `.validation/artifacts/wesh-rc5-manifest.json`
- `.validation/artifacts/wesh-pilot-rc5-simulator/bitchat.app`
- `.validation/artifacts/wesh-pilot-rc5-simulator.zip`
- `.validation/artifacts/wesh-pilot-rc5.xcarchive`
- `.validation/artifacts/wesh-pilot-rc5-app-store/bitchat.ipa`
- `.validation/wesh-rc5-full-tests-retry.xcresult`
- `.validation/rc5/` for command records, source/artifact inventories, and proofs.

## Qualification still open

Interactive RC5 QA was paused because CUA application selection exceeded its
requested timeout (204 seconds for a 30-second request, after an earlier call
was interrupted at 812 seconds). No alternative GUI method or security-setting
change was used. RC5 VoiceOver speech, rotor, gestures/focus progression, and
Safari/share-extension interaction therefore remain unverified. RC4 visual smoke
and RC3 share smoke remain historical evidence for those candidates only.
The dedicated test simulator and Wesh VoiceOver QA were confirmed shut down at
the end; no QA data was erased or populated with synthetic contacts/messages.

The unchanged native Arti dependency still includes the unresolved
**RUSTSEC-2023-0071** RSA advisory and maintenance notices documented in
[ARTI-BINARY-PROVENANCE.md](ARTI-BINARY-PROVENANCE.md). No live Tor/TLS bootstrap,
real-radio exchange, reciprocal QR scan, background/battery test, or physical
mixed iPhone/Android session is established by these local tests. Distribution
and encryption-compliance gates remain separate from signing/build success.
