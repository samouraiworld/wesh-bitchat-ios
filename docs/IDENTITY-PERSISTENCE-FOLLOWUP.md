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

## Noise identity availability and recovery (historical source 9303959f)

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

## Journaled Noise identity recovery (new source)

New first-use identities write a local Keychain journal before either legacy
private-key item. Its layout is exactly 73 bytes: `WESHNOIS`, version byte 1,
32 Noise private-key bytes and 32 signing private-key bytes. The journal is
read back unchanged before any legacy write. Both legacy items must then be
explicitly absent or exactly equal to the journal; only missing items are
written. Both exact private values must be read back before public keys,
fingerprints, signatures or sessions become available. No secret values are
logged. The account uses the existing application-owned Keychain service and
accessibility class; no new service, entitlement or cloud copy is introduced.

A later process can finish the exact journaled pair after interruption before
or between legacy writes. Both confirmed legacy values authorize best-effort
journal cleanup. A cleanup failure may leave a matching journal without
blocking that confirmed identity. A malformed/unknown journal, a divergent
legacy value, or an orphaned legacy half without a journal is preserved and
never repaired by inventing a key or overwriting existing bytes. Valid legacy
pairs without a journal retain their keys and load without migration writes.
Unconfirmed RAM candidates are retried unchanged before journal confirmation.

The core exposes five reasons: available, storage unavailable, persistence
unconfirmed, recovery required and invalidated. They carry no key material.
The Wesh recovery presentation uses these reasons and offers an explicit
storage retry. Foreground/manual recovery respects the current request to run
services, including an explicit stop while storage work is in flight, and
panic suspension. A retry never performs a destructive reset. Existing
unrecoverable legacy data stays preserved; no new erase/reset action or claim
of restoring an unknown missing key is added to that panel.

Panic invalidates the context and pending RAM pair before deletion, attempts
the journal and both legacy deletions even if one fails, and returns the
combined result. BLE retains the invalidated service when identity cleanup
fails so a surviving journal cannot resurrect the old identity on that reset
path. The application-level pending-panic transaction remains responsible for
its broader Keychain/media cleanup gates.

The journal is local recovery data, not an atomic multi-item Keychain
transaction or interprocess compare-and-swap. Success/readback does not
establish physical power-loss, lock/update, reinstall or hardware behavior.
Noise/wire formats and existing valid cryptographic identities are unchanged.
All new fault/restart/panic tests use mock storage and synthetic identities;
no real Keychain access, physical phone or interactive accessibility result is
claimed. Earlier validation and RC5 artifacts above remain historical evidence
for their respective source revisions.

New-source targeted validation: **156/156 passed** (144 Swift Testing +12
XCTest), zero failures/skips/expected failures, Xcode exit 0 and xcresult Passed.
This includes all 13 added journal tests and the 9 added transport/presentation
recovery tests. The initial build failed before any test ran because of a
duplicate observed-property declaration; that declaration was corrected before
the frozen passing build. Its log and result bundle remain separate evidence.
No test was disabled; verbose failure diagnostic collection was disabled.

The complete **unfiltered collection passed 2410/2410** (2178 Swift Testing
+232 XCTest), zero failures/skips/expected failures, Xcode exit 0 and xcresult
Passed. The 156 targeted cases are included in that total. Compared with the
historical 2388 collection, 22 cases were added; the existing interrupted-first-use
test now checks exact journal recovery after service recreation. Full testing
used `test-without-building` with no only/skip arguments and the same compiled
products as the passing targeted build. All 14 changed Swift-file SHA256 values,
the changed-source inventory, and all 3 compiled-product SHA256 values still
match afterward. The 39 inherited runtime warnings all originate in off-tree
`ViewSmokeTests`; they do not establish live accessibility behavior.

New evidence remains ignored under `.validation/noise-recovery-record.json`,
`.validation/noise-recovery-targeted-final.xcresult` and
`.validation/noise-recovery-full.xcresult`, with their logs and summaries.
A fresh RC5 preservation check confirmed the old ZIP and IPA hashes and the
exact 119-file archived inventory unchanged:
`.validation/noise-recovery-rc5-artifact-recheck.json`. The journal/recovery
source is absent from those older distribution artifacts. No archive, export,
version bump, upload or distribution was performed.

The dedicated test simulator was already Shutdown when shutdown was requested;
the subsequent inventory confirmed no booted simulator. No data was wiped.

## Local composer drafts after 9808aa4b (2026-10-15)

The Wesh runtime now explicitly enables an encrypted draft repository after a
confirmed Noise identity is available. Public mesh drafts and private drafts
addressed by an explicit complete 32-byte Noise key may persist. Geohash and
short-peer/fingerprint fallback destinations stay in RAM. The cache includes the
SHA256 owner fingerprint of the local Noise public key; a different identity
cannot restore or overwrite the old owner's cache. No draft is sent or imported
automatically. Tests leave the default singleton in memory and inject temporary
files and mock Keychain dependencies for persistence.

The local file is Application Support/composer-drafts/wesh-v1.enc, protected
until first unlock and excluded from backup. It uses existing ChaChaPoly with
AAD `wesh.composer-drafts.v1` and a separate random 32-byte Keychain key named
`composerDraftEncryptionKey.v1` in the existing local identity service. This is
local storage only: no cryptographic primitive, identity or wire format changes.
The authenticated plaintext is strict binary: eight-byte magic `WESHDRFT`,
version byte 1, 32-byte owner, UInt16 record count, then destination byte (0 mesh,
1 full private key), optional 32-byte private key, UInt64 epoch milliseconds,
UInt32 UTF8 byte count and text bytes. Integers are big endian. Unknown versions,
duplicates, invalid destinations, timestamps, UTF8, trailing bytes or owner
mismatches are rejected. There are at most 64 durable records, 8000 characters
and 32000 UTF8 bytes per record, and a bounded 2100000-byte encrypted file read
(up to the limit plus one before rejection).

Only confirmed absence of both key and cache permits creating a key. Permission
and read errors, malformed keys, missing-key/orphaned files and authentication
failures preserve existing bytes and block replacement. Writes require the
previous ciphertext and Keychain value to match the loaded baseline, atomic
file replacement and exact readback. These checks are conservative in-process
recovery safeguards, not an interprocess transaction or a power-loss guarantee.

RAM access stays synchronous. Load, Keychain/file IO and debounced writes run on
a serial utility queue. Startup empty composer state does not save an empty
draft. Edits and explicit share imports made while loading override only their
own destination; bounded tombstones preserve explicit clears. Admission refuses
new pending destinations when its bounded intent map is full. TextField edits
are admitted within both limits before changing displayed text; refusal keeps
the previous text and explains that the edit was not accepted. Legacy RAM calls
retain their character truncation behavior but a truncated entry is never
reported as a durable copy of its original text. Delayed restoration requires
the same destination, generation and untouched revision. Submission requires a
matching RAM snapshot; successful send clears only that unchanged snapshot.
Shared import consumes the exact reviewed envelope under its existing lock only
after draft admission, so refusal retains the offer and allows retry.

French UI distinguishes session-only, identity unavailable, loading, pending,
confirmed, suspended and storage/recovery errors. “Enregistré” follows confirmed
readback; the last keystroke remains pending until then. Retry and foreground
reload merge pending edits with validated stored drafts. Background/termination
flush is best effort, not a promise that termination waits for completion.

Panic increments the generation, rejects old callbacks, clears RAM and drains
old IO before global Keychain deletion. The synchronous security barrier can
briefly make Main wait; actual IO remains on the utility queue, which never
waits for Main. Global recovery attempts both media and draft file cleanup even
if either fails, retains its marker until cleanup succeeds, and confirms draft
file absence. Startup marker replay runs before draft persistence configuration.
A failed panic leaves the repository suspended; only confirmed global success
allows the new identity to load again. Old write/load completions cannot restore
an earlier generation.

Final validation passed **104/104** targeted Swift Testing cases in eight suites,
including the 20 new repository/backend cases, two new handoff cases, legacy
composer/Wesh/panic coverage and the existing timing-hygiene gate. The complete
unfiltered collection then passed **2432/2432** (2200 Swift Testing +232 XCTest),
zero failures, skips or expected failures, Xcode exit 0 and xcresult Passed.
The 104 targeted cases are included in that collection. Full testing used
`test-without-building` with no only/skip filters and the same compiled products.
All 11 changed Swift SHA256 values, their inventory and all three compiled
product hashes matched afterward. The 39 inherited runtime warnings all come
from off-tree `ViewSmokeTests`; these are not interactive accessibility evidence.
No new compiler warning originates in the new draft backend/repository/test files.

Intermediate attempts are preserved separately: an initial build failed before
running tests on a MainActor isolation error; the corrected intermediate target
passed 101/101. The following build compiled but its runner launched zero cases;
it was interrupted and Xcode exited 75. The first unfiltered collection ran
2432 cases and reported one timing-hygiene failure because a new test helper
used a two-second deadline. That helper and its bounded semaphore waits now use
the repository's `TestConstants.settleTimeout`; the gate was neither disabled nor
exempted. The final passing targeted and full results above follow that change.

Evidence remains ignored under `.validation/composer-drafts-record.json`,
`.validation/composer-drafts-targeted-timing-fixed.xcresult`,
`.validation/composer-drafts-full-final.xcresult`, their logs/summaries,
source/product manifests and `.validation/composer-drafts-post-full-integrity.json`.
RC5 ZIP/IPA and the exact old 119-file archive inventory still match, confirmed
again in `.validation/composer-drafts-rc5-artifact-recheck-final.json`. No archive,
export, version bump, upload or distribution was performed. The dedicated
simulator was already Shutdown when shutdown was requested; its subsequent
inventory confirms no booted simulator. No simulator data was erased.

New persistence tests use only synthetic text/keys, isolated temporary files and
mock Keychain data. Restart coverage recreates repository/backend instances;
physical power-loss, device lock/unlock, reinstall/upgrade and phones remain
unqualified. The earlier identity/Noise results and RC5 distribution hashes
above remain historical evidence for their own sources.


## V1 private admission and media lifecycle follow-up

An enrolled private recipient is no longer sufficient for Wesh submission when
local transport is stopped, Bluetooth is unavailable or Noise recovery is
pending. Private admission now shares the public route's transport-availability
check while remaining independent of public-room disclosure consent. It also
requires the complete 32-byte Noise recipient key; a short alias cannot accept
and clear a draft that the lower private-message sender would refuse. Genuine
mock Noise sessions exercise the valid path before each negative regression.

Both Wesh text routes accept at most 2,000 UTF-8 bytes, matching Android. The
larger draft-storage limits remain unchanged: over-limit text is retained for
editing, with actionable French feedback before submission. ASCII, accented and
emoji boundaries are checked on public and private routes.

Private media preflight applies the existing 256-fragment peer limit to the
final encrypted packet as well as legacy file transfers. This prevents sending
a large encrypted train that the Android reassembler would discard. Lifecycle
checks stop and reject fragment work after transport stop/restart, including
pending requests carrying their submission generation; they no longer turn a
local refusal into completed progress. This is a local scheduling result, not
proof of GATT receipt or remote delivery. Large public media interoperability
remains unqualified; V1 Wesh composers expose text only.

The follow-up changes neither the wire format nor cryptographic construction.
Its synthetic regressions do not access the live Keychain or qualify phones,
background radio, power loss or accessibility. Current local evidence is under
`.validation/v1-readiness/`; preceding numerical results remain historical.
