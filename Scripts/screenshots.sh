#!/usr/bin/env bash
#
# Capture iPhone 6.5" App Store screenshots from the running app.
#
#   Scripts/screenshots.sh
#
# Portrait frames are the simulator's native 1284×2778. Landscape is 2778×1284.
# Nothing is resized. The pose arguments are simulator-only; see SyntheticInput.
#
set -euo pipefail
cd "$(dirname "$0")/.."

PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

BUNDLE_ID=dev.phux.zerofret
NAME=ZeroFret-6.5
OUT=AppStore/screenshots
DERIVED=build/DerivedData-screenshots
APP="$DERIVED/Build/Products/Debug-iphonesimulator/ZeroFret.app"

mkdir -p "$OUT"

udid() {
  xcrun simctl list devices available | awk -v name="$NAME" -F '[()]' '
    $0 ~ name && /Booted|Shutdown/ { print $2; exit }
  '
}

UDID=$(udid)
if [[ -z "$UDID" ]]; then
  echo "error: no simulator named $NAME. Create an iPhone 14 Plus (or 13/12 Pro Max) first." >&2
  exit 1
fi

echo "==> boot $UDID"
if ! xcrun simctl boot "$UDID" 2>/dev/null; then
  # A second simulator sometimes will not boot while another is already up.
  xcrun simctl shutdown all || true
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b

echo "==> build"
xcodebuild build \
  -project ZeroFret.xcodeproj \
  -scheme ZeroFret \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

echo "==> install"
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 || true

# simctl has no orientation command on this Xcode. Portrait is the slot Apple
# rejected. Landscape is a menu rotate after those frames exist.
capture() {
  local file="$1" midi="$2" cents="$3"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  SIMCTL_CHILD_ZF_POSE_MIDI="$midi" \
  SIMCTL_CHILD_ZF_POSE_CENTS="$cents" \
  SIMCTL_CHILD_ZF_HIDE_DEMO=1 \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  # Engine start plus a detection window. A held tone locks well inside this.
  sleep 5
  xcrun simctl io "$UDID" screenshot "$OUT/$file"
  echo "    $file"
}

echo "==> capture"
capture "01-in-tune-low-e.png" 40 0
capture "02-flat-low-e.png" 40 -22
capture "03-in-tune-high-e.png" 64 0
capture "04-sharp-a.png" 45 16

echo "==> dimensions"
fail=0
check() {
  local file="$1" want_w="$2" want_h="$3"
  local w h
  w=$(sips -g pixelWidth "$OUT/$file" | awk '/pixelWidth/ { print $2 }')
  h=$(sips -g pixelHeight "$OUT/$file" | awk '/pixelHeight/ { print $2 }')
  if [[ "$w" != "$want_w" || "$h" != "$want_h" ]]; then
    echo "error: $file is ${w}x${h}, want ${want_w}x${want_h}" >&2
    fail=1
  else
    echo "    $file ${w}x${h}"
  fi
}
check 01-in-tune-low-e.png 1284 2778
check 02-flat-low-e.png 1284 2778
check 03-in-tune-high-e.png 1284 2778
check 04-sharp-a.png 1284 2778
if [[ -f "$OUT/05-landscape-in-tune.png" ]]; then
  check 05-landscape-in-tune.png 2778 1284
fi

if [[ "$fail" != 0 ]]; then
  exit 1
fi
echo "==> $OUT"
