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

## Noise identity availability and recovery

The next source removes Noise's temporary-key and malformed-key replacement
fallbacks. Both legacy private-key items must be readable and valid before the
service publishes either public key, a fingerprint, signing, courier/prekey
operations, or a session manager. An unavailable service has no identity context;
its core getters return nil and local-identity operations fail closed. The
compatibility Transport getters expose empty absence values, which callers
validate before QR enrollment, Wesh sending, radio startup or packet handoff.
No fingerprint is derived from empty bytes and no empty-key announcement is sent.

A new pair is generated only when both legacy items are explicitly absent.
Both writes require success and both exact private values must be read back
before publication. An interrupted save retains the exact unpublished pair in
RAM for retry, writes only a still-missing item, and refuses divergent stored
bytes or any read error. Loading and retry are serialized across service
instances in this process. Once ready, the immutable keys and manager stay
paired; foreground recovery does not rotate an active identity. Panic invalidates
the context and pending pair before deletion and forbids retry on that instance.

This retains the two-item legacy schema and its limitations: a process death
between first-use writes can leave an orphaned half. A new process preserves
that half and remains unavailable until explicit recovery restores the original
pair; it never invents the missing key. There is no transaction across items,
no cross-process Keychain compare-and-swap, and no new recovery UI or automatic
migration. Existing valid identity and wire/cryptographic formats are unchanged.

Foreground/start retries protected storage before BLE activation. Deferred
startup resumes only while service use is still requested; an explicit stop or
panic suspension stays stopped. Bluetooth restoration/state callbacks and
packet handoffs also require identity availability. All new fault tests use
mock storage and synthetic identities. No real Keychain, physical-device,
VoiceOver, BLE interoperability or delivery qualification is implied.

The current Wesh UI disables sending while Noise is unavailable, but reports
Bluetooth as unknown rather than displaying a dedicated Noise-storage recovery
reason. A dedicated recovery screen/retry control remains future work. The
availability and foreground/start retry behavior above is implemented; no
interactive or physical recovery qualification is claimed.

Reviewed-source targeted validation: **189/189 passed** (177 Swift Testing +12
XCTest), zero failures/skips/expected failures, Xcode exit0 and xcresult Passed.
The frozen sources include the final panic-completion lifecycle correction;
initial targeted141 and later180 passing runs precede those final fixes and
remain separate intermediate evidence. The initial rekey-fallback collection
literal compile error executed no tests and is preserved separately.

Twenty-four added test cases relative to the previous full collection cover
Noise storage/availability (16 cases replacing four previous cases: net+12),
callers/radio/QR/courier and start/stop/panic boundaries (12 additional cases).
The complete passing targeted set is included in the unfiltered collection;
counts must never be added together. Evidence remains ignored under
`.validation/noise-persistence-record.json` and
`.validation/noise-persistence-targeted-reviewed.xcresult`.

Final reviewed-source **unfiltered full validation: 2388/2388 passed** (2156
Swift Testing +232 XCTest), zero failures/skips/expected failures, Xcode exit0
and xcresult Passed. No only/skip arguments were supplied. The 189 targeted
cases are included in that total. All26 frozen Swift-file SHA256 values and
all three compiled-product SHA256 values (app executable, debug dylib and test
bundle executable) still match after the run. The39 inherited off-tree
ViewSmokeTests Environment/State warnings remain; no live accessibility result
is claimed. Full evidence: `.validation/noise-persistence-full.xcresult`,
its summary/log and `.validation/noise-persistence-record.json`.

Independent artifact recheck confirmed the old RC5 ZIP and IPA against their
manifest and all119 archived files unchanged; evidence is
`.validation/noise-gatt-rc5-artifact-recheck.json`. This new source was neither
archived nor exported and is absent from those older distribution artifacts.
No version change, upload or distribution was performed.

The dedicated test simulator was already Shutdown when shutdown was requested;
`simctl list devices booted` confirmed no booted simulator. No data was wiped.
