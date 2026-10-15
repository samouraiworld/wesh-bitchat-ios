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

## Identity-cache and writer follow-up

The next development source preserves unreadable/malformed identity caches and
refuses persistent mutations until a confirmed load. Key generation requires
both key and cache to be explicitly absent. Failed writes remain pending in
RAM; trust and blocking decisions stay conservative until exact readback.
Foreground activation retries load/write before private decisions and refreshes
peers after recovery. Wesh send/import, QR enrollment, legacy-media fallback
and block/unblock reporting use availability and pending-write state. A panic
wipe invalidates the cached encryption key before further persistence.

The simple, detailed and custom-service Keychain writers now update existing
items, add only after itemNotFound and retry a duplicate creation with one
bounded update. They do not delete before writing. This follows Apple's
[update query and attributes pattern](https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items).
Existing access groups, non-synchronizing policy and accessibility are retained.
This closes the application-level delete/add loss window; it is not a
transaction across several items or managers, a power-loss guarantee, or a
physical unlock/update qualification. Unit faults use injected operations and
mock storage only; they never read or mutate the real Keychain.

The earlier legacy-writer limitation above describes the previous source.
Concurrent get-or-create, Noise identity fallback, process-death draft loss,
upstream geohash success feedback and physical accessibility remain separate
work. Refused mutations before a successful cache load must be requested
again; malformed/orphaned data is preserved, not silently recovered or erased.

Latest complete validation: **2364/2364 passed** (2134 Swift Testing +230
XCTest), zero failures/skips/expected failures, no only/skip filters, Xcode
exit0 and xcresult Passed. The **145/145 targeted cases are included**, not
added. Twenty-four new behavior tests cover the manager11, writer6 and caller7
boundaries. All15 frozen Swift hashes match the compiled products and the
post-test sources. The39 inherited off-tree runtime warnings remain, with no
live focus or speech qualification.

Intermediate attempts remain separate: a runner stopped before any cases,
a lifecycle visibility compile error, and a failed test fixture that wrongly
assumed empty JSON was an invalid legacy schema. The fixture was corrected to
an invalid field type; that failed runner did not finalize and was terminated.
The corrected targeted/full results above are the passing reference. Verbose
diagnostic collection was disabled on those runs; no test was disabled.

Evidence is ignored: `.validation/identity-cache-persistence-record.json`,
`.validation/identity-cache-persistence-targeted-verified.xcresult` and
`.validation/identity-cache-persistence-full.xcresult`. The test simulator is
shut down without wiping data; no physical-device, archive or export result.
