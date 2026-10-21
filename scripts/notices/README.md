# Offline third-party notices

The app's Licences screen reads the three files in
`bitchat/Views/Wesh/Pave/Notices` and the existing Archivo OFL resource. No
license text is downloaded at runtime.

`third_party_notices.py` inventories the normal-dependency closure of
`arti-bitchat` for all five packaged Apple targets. It excludes build/dev
edges and proc-macro targets. Cargo's resolved default features are retained;
the inventory can therefore include code removed by release optimization.
It is a source-based notice collection, not a claim about exact linked code,
binary reproducibility, or completion of every redistribution obligation.

Generation verifies each cached `.crate` against its `Cargo.lock` checksum.
It preserves license/notice files, including nested ring notices, verbatim.
Identical texts share one SHA-256 section in `Arti-NOTICES.txt`. The JSON
inventory maps each component and original filename to that text and its
primary source URL. Each component also links its immutable source archive.

Some crate archives omit their workspace's license files. `supplements.json`
binds those primary texts to the archive's `.cargo_vcs_info.json` revision.
The `primary` directory stores the exact fetched files under their SHA-256
names. Workspace manifests supply scope evidence for shared root licenses.

`void` 1.0.2 predates archive VCS metadata. Its release commit is matched to
the locked archive's README, manifest, and sole source file byte for byte.
The README and manifest explicitly say MIT and name Jonathan Reem; they
supply no separate copyright notice. The collection preserves those primary
statements and the unchanged permission/warranty portion of the canonical
MIT text, with no substituted year or copyright holder. This qualification
remains explicit in the inventory for redistribution review.

The secp256k1 notice preserves both the Swift wrapper's MIT license at the
revision pinned by `Package.swift` and its linked core submodule's COPYING
file. Their source revisions and URLs appear above the unchanged texts.

## Check

```sh
python3 scripts/third_party_notices.py check
python3 -m unittest discover -s scripts/tests -p test_third_party_notices.py
```

A changed native manifest/lock, missing component or text, stale hash, or
unresolved primary material fails the check. Legal source qualifications are
listed separately; a mechanically complete collection is not legal sign-off.

## Regenerate after dependency changes

Obtain metadata in `localPackages/Arti` for each of these targets with
`cargo metadata --offline --locked --format-version 1 --filter-platform TARGET`:

- `aarch64-apple-ios`
- `aarch64-apple-ios-sim`
- `x86_64-apple-ios`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

Save each output outside the repository, then pass all five files as repeated
`--metadata TARGET=JSON` arguments to
`python3 scripts/third_party_notices.py generate`. Use `--cache` if Cargo's
registry cache is outside its default location. This command only reads
metadata and cached archives; it does not run Cargo, compile, or fetch.
Review any newly missing primary material before accepting regenerated files.
Do not replace missing terms with a guessed license or copyright statement.
