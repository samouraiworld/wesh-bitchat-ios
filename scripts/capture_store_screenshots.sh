#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
device_name="${WESH_SCREENSHOT_DEVICE_NAME:-iPhone 16 Pro Max}"
output="${1:-$root/StoreAssets/iOS/107}"
derived_data="${WESH_SCREENSHOT_DERIVED_DATA:-$root/.validation/DerivedData-store-screenshots-107}"
source_packages="${WESH_SCREENSHOT_SOURCE_PACKAGES:-$root/.validation/SourcePackages-store-screenshots-107}"
bundle_id="org.samouraiworld.wesh.ios.screenshots"
staging="$(mktemp -d "${TMPDIR:-/tmp}/wesh-ios-store-screenshots.XXXXXX")"

if [[ -e "$output" ]] && [[ -n "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "error: output directory is not empty: $output" >&2
  exit 1
fi

device_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
matches = [
    (runtime, device)
    for runtime, devices in data.get("devices", {}).items()
    for device in devices
    if device.get("name") == name and device.get("isAvailable", False)
]
if not matches:
    raise SystemExit(f"no available simulator named {name!r}")
preferred = next((device for runtime, device in matches if runtime.endswith("iOS-18-6")), matches[0][1])
print(preferred["udid"])
' "$device_name")"

was_booted="$(xcrun simctl list devices booted --json | python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
print("yes" if any(device.get("udid") == udid for devices in data.get("devices", {}).values() for device in devices) else "no")
' "$device_id")"

cleanup() {
  xcrun simctl terminate "$device_id" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$device_id" clear >/dev/null 2>&1 || true
  if [[ "$was_booted" == "no" ]]; then
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$staging"
}
trap cleanup EXIT

mkdir -p "$derived_data" "$source_packages" "$staging/en-US" "$staging/fr-FR"

if [[ "${WESH_SCREENSHOT_SKIP_BUILD:-0}" != "1" ]]; then
  xcodebuild -resolvePackageDependencies \
    -project "$root/bitchat.xcodeproj" \
    -scheme "Wesh Store Screenshots" \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$source_packages"

  xcodebuild \
    -project "$root/bitchat.xcodeproj" \
    -scheme "Wesh Store Screenshots" \
    -configuration Screenshot \
    -sdk iphonesimulator \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$source_packages" \
    -disableAutomaticPackageResolution \
    -jobs 2 \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

app="$derived_data/Build/Products/Screenshot-iphonesimulator/WeshScreenshots.app"
if [[ ! -d "$app" ]]; then
  echo "error: Screenshot app was not built at the expected path" >&2
  exit 1
fi

if [[ "$was_booted" == "no" ]]; then
  xcrun simctl boot "$device_id"
fi
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" "$app"
xcrun simctl status_bar "$device_id" override --time 09:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4

scenes=(
  01-home-peers
  02-public-room
  03-synthetic-qr
  04-verified-private
  05-unverified-requests
  06-frozen-erase
  07-internet-disabled
)

for locale in en-US fr-FR; do
  language="${locale%%-*}"
  for scene in "${scenes[@]}"; do
    SIMCTL_CHILD_WESH_SCREENSHOT_SCENE="$scene" \
    SIMCTL_CHILD_WESH_SCREENSHOT_LOCALE="$language" \
      xcrun simctl launch --terminate-running-process "$device_id" "$bundle_id" \
        -AppleLanguages "($language)" -AppleLocale "$locale" >/dev/null
    # A terminated/relaunched SwiftUI scene briefly reports a full-screen safe
    # area on newer simulator runtimes. Wait for the status bar and final safe
    # area before capturing so every locale has the same device chrome.
    sleep 2
    xcrun simctl io "$device_id" screenshot --type=png "$staging/$locale/$scene.png" >/dev/null
  done
done

candidate_commit="$(git -C "$root" rev-parse HEAD)"
python3 "$root/scripts/validate_store_screenshots.py" "$staging" \
  --candidate-commit "$candidate_commit" --strip-sensitive-metadata --write-manifest
python3 "$root/scripts/check_screenshot_capture_boundary.py" "$root" \
  --screenshot-product "$app"
mkdir -p "$output"
cp -R "$staging/." "$output"

echo "OK: captured and validated 14 synthetic screenshots for iOS 1.0.0 (107)"
