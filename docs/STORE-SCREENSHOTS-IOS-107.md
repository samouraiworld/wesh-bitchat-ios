# iOS 1.0.0 (107) store screenshots

The `Wesh Store Screenshots` scheme renders fourteen deterministic App Store
screenshots: seven scenes in English and French. All people, messages, times and
QR artwork are synthetic. The QR artwork is intentionally non-scannable.

The scheme is not a distribution target. Its `Screenshot` configuration inherits
Release optimization and UI resources, but is restricted to `iphonesimulator`,
cannot sign, cannot install into an archive and uses the dedicated
`org.samouraiworld.wesh.ios.screenshots` bundle identifier. Only this configuration
defines `WESH_SCREENSHOT_CAPTURE`. The ordinary Release entry point, runtime,
Bluetooth, Tor, persistence and notification services are not constructed.

## Reproduce

Use an available `iPhone 16 Pro Max` simulator. The capture script selects by
device name, fixes the status bar, builds the simulator-only scheme, captures the
seven scenes in each locale and validates the resulting PNGs.

```sh
scripts/capture_store_screenshots.sh /absolute/empty/output/directory
```

`WESH_SCREENSHOT_SKIP_BUILD=1` may be used only after the same DerivedData
Screenshot product has already passed a successful build; the default always
resolves and builds from source.

The accepted set is exactly 14 PNG files at 1320×2868. Simulator-injected
text, EXIF and timestamp chunks are removed byte-for-byte without re-encoding
the pixels. The validator then rejects any remaining sensitive metadata,
unexpected files and missing scenes, and writes `manifest.json` with a SHA-256
for every image plus the exact committed renderer source used for capture.

## Release boundary gates

After independently building Release and Screenshot products:

```sh
python3 scripts/check_screenshot_capture_boundary.py . \
  --release-product /path/to/Release-iphonesimulator/Wesh.app \
  --screenshot-product /path/to/Screenshot-iphonesimulator/WeshScreenshots.app

python3 scripts/check_release_localizations.py . \
  --product /path/to/Release-iphonesimulator/Wesh.app
```

The first gate requires the fixture sentinel in the Screenshot executable and
rejects it anywhere in the Release application. The second gate verifies that
the exact Release product exposes only Base, English and French localizations.
