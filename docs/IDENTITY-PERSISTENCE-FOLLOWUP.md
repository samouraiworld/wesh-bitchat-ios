# Nostr identity persistence follow-up

This source change follows the locally exported RC5 candidate
`140030a1` (0.1.0 build 6). The RC5 IPA, archive and simulator ZIP retain their
own source and validation evidence; this patch is not present in those artifacts.
No new distribution candidate, signing result or upload is implied.

NostrIdentityBridge now creates a current identity or device seed only after
an explicit Keychain itemNotFound. A locked device, denied access,
authentication failure, other read error or malformed stored data produces an
error without replacement. New data must be read back unchanged before the
identity is returned or the seed is cached. Existing seeds are read without
rewriting them. The derivation and wire formats remain unchanged.

Seven isolated behavior tests cover read failures and retry, malformed data,
failed identity/seed writes, unavailable readback and durable first-use seed
reuse. They use mock storage and a synthetic cell constant, never device
location or the real Keychain.

This patch does not make the legacy Keychain save transactional or serialize
all concurrent bridge calls. Noise session fallback on storage errors,
identity-cache recovery, real lock/update behavior and RAM-only draft loss
after process termination remain separate work. No physical-device,
VoiceOver, BLE or remote-receipt qualification is claimed.

The RC5 artifacts were rehashed unchanged and its existing xcresult reread:
2333 passed, zero failures/skips/expected failures. This recheck is distinct
from the new-source tests. The new CUA attempt failed with ScreenCaptureKit
capture error -3811 after exceeding its requested timeout; no new gesture or
speech observation was obtained. Raw evidence remains local and ignored.

## New-source validation

Targeted collection: **26/26 passed** across three suites, including the
seven new regressions, zero failures/skips/expected failures. Initial assertion
compilation failure ran no tests and is preserved separately. The corrected
products then ran the **complete unfiltered collection: 2340/2340 passed**,
zero failures/skips/expected failures, Xcode exit 0 and xcresult Passed.
The targeted 26 are included in the complete collection and are not added to it.
No new archive, export or physical-device result was produced.

Evidence remains ignored: `.validation/nostr-identity-persistence-record.json`,
`.validation/nostr-identity-persistence-tests-fixed.xcresult` and
`.validation/nostr-identity-full-tests.xcresult`. Existing off-tree smoke-test
and build warnings do not establish live focus or speech behavior.
