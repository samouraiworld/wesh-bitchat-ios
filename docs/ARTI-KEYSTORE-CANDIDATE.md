# Explicit keystore policy — candidate preparation

The distributed iOS native library is unchanged by these source edits. Its
existing provenance hashes and clean-rebuild gate remain authoritative for that
old binary. They must not be rewritten to pretend the new policy is already
compiled or distributed.

The candidate enables `arti-client/keymgr` only to expose the official storage
setter, then requires `BoolOrAuto::Explicit(false)` and an effectively disabled
keystore before bootstrap. An implicit or enabled setting fails closed, without
fallback. Four inert tests cover no directory creation, preservation of a
synthetic unusable keystore path, rejection of Auto and rejection of true. They
never call bootstrap or use real keys.

The feature can add `tor-hsclient` transitively. The metadata probe derives a lock
only in scratch and rejects removal or checksum/version/source changes of any
existing package. Five target graphs and all additions must be reviewed before
importing that lock and building. The probe forbids activating the client onion
API, onion-service publishing, relay mode, x509 generation, CLI key management,
experimental client APIs or alternate keystores. Generic `hsv3-service` and RSA
code may remain linked; neither their absence nor closure of RustSec is claimed.

The initial source branch intentionally cannot pass the historical native input
and old-binary comparison gates. No gate is relaxed. After metadata and additions
review, the complete candidate requires two fresh isolated five-target builds,
without restored target caches, using unchanged Rust 1.96.0, cbindgen 0.29.4,
Xcode 27.0 (27A266a), SDK 27.0 and the existing packaging recipe. Build A and B
must agree on all seven xcframework files and the standalone C header, all source
and lock hashes, all five architectures and exactly seven C exports. Incomplete
matrices, changed headers, private paths or mismatches fail; no partial import.

Only then import the complete xcframework/header and update the existing audited
source/artifact manifests together. Run every historical provenance, clean-build,
native-contract and app gate against that final source/binary pair. A new iOS
candidate, its distribution identity and its RSA decision remain separate from
Android's four hashes and from TestFlight 107's physical test attestation.

The proposed A/B job is explicitly opt-in after lock review. It produces candidate
artifacts only; it cannot upload to a Store, publish a release, merge a PR or
silently replace the checked-in library.
