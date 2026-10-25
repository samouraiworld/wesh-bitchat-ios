# iOS capture provenance

`iOS/107/` preserves the historical fourteen-image renderer output. Those scenes
were independently redrawn and are **not eligible for Store upload as faithful
captures of build 107**. Its legacy manifest and validator remain available only
for archive integrity; they do not confer fidelity approval.

The current Screenshot configuration mounts the actual production welcome,
Bluetooth introduction, settings, Internet OFF and about views. Settings and
about use the same navigation stacks and bottom tabs as the shipping root;
Internet OFF uses the native settings sheet. The inactive inbox is empty and
never constructed. A fixed synthetic nickname and in-memory Internet OFF state
replace runtime data. Callbacks do nothing, links are discarded and hit testing
is disabled. The sole mounted task is the erase control's in-memory hold tracker,
which exits immediately without a hold. No runtime, radio service, persistent
identity or network manager is constructed by the capture entry point.

On a clean, committed checkout, run:

```sh
bash scripts/capture_store_screenshots.sh
```

The script builds only the private simulator Screenshot configuration, captures
five scenes in English and French and writes to ignored
`.validation/production-store-captures/`. It records the renderer commit and
production source hashes in a schema 2 manifest. It always builds before capture;
an existing stale product cannot be selected through a skip-build switch.
The `Capture production store views` workflow runs the same process on a
disposable macOS runner with read-only permissions and no Store secrets.

These ten PNGs require visual review after CI. Their manifest deliberately leaves
the distribution candidate **unbound**. A separate reviewed record must bind a
frozen candidate to this render source and explain any source delta before assets
are named for build 108 or uploaded. No candidate version, device-test result or
public-release approval is inferred from successful rendering.

The Screenshot flag, bundle identifier and fixture sentinel remain forbidden in
Release. Existing CI checks both Release and Screenshot products. The source-only
tests do not replace these build checks or visual review.
