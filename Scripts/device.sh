#!/usr/bin/env bash
#
# Build Zero Fret and run it on a connected iPhone.
#
#   Scripts/device.sh              # first available device
#   Scripts/device.sh <name|udid>  # a specific one
#
# The Simulator is deliberately not supported here: its microphone resamples and
# applies processing you cannot disable, so it produces plausible-looking wrong
# answers. In the Simulator the app feeds itself a generated signal instead and
# labels the readout DEMO.

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-}"

echo "==> devices"
xcrun devicectl list devices

if [[ -z "$TARGET" ]]; then
  TARGET=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/available|connected/ {print $3; exit}')
fi
[[ -n "$TARGET" ]] || {
  echo "error: no connected device. Plug the iPhone in, unlock it, and trust this Mac." >&2
  exit 1
}
echo "==> target $TARGET"

xcodebuild build \
  -project ZeroFret.xcodeproj \
  -scheme ZeroFret \
  -configuration Debug \
  -destination "id=$TARGET" \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates

APP=build/DerivedData/Build/Products/Debug-iphoneos/ZeroFret.app
xcrun devicectl device install app --device "$TARGET" "$APP"
xcrun devicectl device process launch --device "$TARGET" dev.phux.zerofret
