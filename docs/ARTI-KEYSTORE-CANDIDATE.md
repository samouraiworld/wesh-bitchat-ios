# Explicit keystore policy — imported candidate

The reviewed candidate is compiled and imported from source `90d34202`, A/B run
`40194292340`. The complete receipt is
[`provenance/ios-keystore-disabled-2026-10-25.json`](provenance/ios-keystore-disabled-2026-10-25.json).
The current provenance hashes describe this candidate; the existing clean-rebuild
and app gates must now validate the imported pair. The distributed TestFlight
107 library remains unchanged and is preserved by its separate delivery record.

The candidate enables `arti-client/keymgr` only to expose the official storage
setter, then requires `BoolOrAuto::Explicit(false)` and an effectively disabled
keystore before bootstrap. An implicit or enabled setting fails closed, without
fallback. Four inert tests cover no directory creation, preservation of a
synthetic unusable keystore path, rejection of Auto and rejection of true. They
never call bootstrap or use real keys.

The feature adds only `tor-hsclient 0.38.0` transitively. The metadata probe derives a lock
only in scratch and rejects removal or checksum/version/source changes of any
existing package. Five target graphs and all additions must be reviewed before
importing that lock and building. The probe forbids activating the client onion
API, onion-service publishing, relay mode, x509 generation, CLI key management,
experimental client APIs or alternate keystores. Generic `hsv3-service` and RSA
code may remain linked; neither their absence nor closure of RustSec is claimed.

The initial source-only branch could not pass the historical native input and
old-binary comparison gates. No gate was relaxed. After metadata and additions
review, the complete candidate passed two fresh isolated five-target builds,
without restored target caches, using unchanged Rust 1.96.0, cbindgen 0.29.4,
Xcode 27.0 (27A266a), SDK 27.0 and the existing packaging recipe. Build A and B
agreed on all seven xcframework files and the standalone C header, all source
and lock hashes, all five architectures and exactly seven C exports. Incomplete
matrices, changed headers, private paths or mismatches fail; no partial import.

The complete xcframework/header and audited source/artifact manifests are now
imported together. Run every historical provenance, clean-build,
native-contract and app gate against that final source/binary pair. A new iOS
candidate, its distribution identity and its RSA decision remain separate from
Android's four hashes and from TestFlight 107's physical test attestation.

The A/B job is explicitly opt-in after lock review. It produces candidate
artifacts only; it cannot upload to a Store, publish a release, merge a PR or
silently replace the checked-in library.
