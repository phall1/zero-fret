#!/usr/bin/env bash
#
# App Store screenshots: real captures of the app, each framed with a short
# headline in its own band above it.
#
#   Scripts/screenshots.sh            # iPhone 6.9" and iPad 13"
#   Scripts/screenshots.sh iphone     # just one
#
# Writes, per device:
#   AppStore/screenshots/<device>/capture/NN-name.png   the simulator's own pixels
#   AppStore/screenshots/<device>/NN-name.png           what gets uploaded
#   AppStore/screenshots/contact-<device>.png           the set at phone viewing size
#
# Every screen is the Debug build of the shipping UI, driven by the simulator's
# synthetic input held on one note (see SyntheticInput's pose) with the DEMO
# badge hidden. Sheets are opened by ZF_SHEET rather than by tapping, and
# settings are written with `defaults` before launch, so each capture is the
# real view in a known state. Captures are never resized into another device's
# shape; the frame scales them uniformly.
#
# The shot list — order, pose and copy — is SHOTS below. Change the copy there.
#
set -euo pipefail
cd "$(dirname "$0")/.."

PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

BUNDLE_ID=dev.phux.zerofret
ROOT=AppStore/screenshots
DERIVED=build/DerivedData-screenshots

# device key | simulator name | upload width | upload height
DEVICES=(
  "iphone|iPhone 17 Pro Max|1320|2868"
  "ipad|iPad Pro 13-inch (M5)|2064|2752"
)

# devices | file | midi | cents | sheet | headline | supporting line
# midi/cents pose the synthetic note; "-" for sheet means the tuner itself.
# The haptic shots are iPhone only: no iPad has a haptic engine, and the app
# disables Feel the Beat there (HapticSupport), so showing it would be false.
SHOTS=(
  "iphone,ipad|01-see-it-settle|40|0|-|See your string settle.|A guitar, bass & ukulele tuner with a different view."
  "iphone|02-feel-the-beat|40|-9|settings|Feel the Beat.|Turn it on in Settings for a tap in your hand on every beat."
  "iphone|03-tune-by-touch|45|-12|-|Tune by touch.|Pluck, then turn the peg. The taps slow as you get close."
  "iphone,ipad|04-too-slack|40|-22|-|Too slack? Tighten.|Every reading says which way to turn, in words."
  "iphone,ipad|05-your-tunings|45|0|tunings|Guitar. Bass. Ukulele. Yours.|Star the tunings you play, or build your own."
  "iphone,ipad|06-no-catch|45|16|-|No accounts. No ads.|Free for good. Audio never leaves your device."
)

udid() {
  xcrun simctl list devices available | awk -v name="$1" '
    index($0, "    " name " (") == 1 { match($0, /\([0-9A-F-]+\)/); print substr($0, RSTART + 1, RLENGTH - 2); exit }
  '
}

prepare() {
  local udid="$1"
  if ! xcrun simctl boot "$udid" 2>/dev/null; then :; fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcodebuild build \
    -project ZeroFret.xcodeproj -scheme ZeroFret \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet
  local app
  app=$(find "$DERIVED/Build/Products" -maxdepth 2 -name ZeroFret.app -path "*iphonesimulator*" | head -1)
  xcrun simctl install "$udid" "$app"
  xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged \
    --batteryLevel 100 --wifiBars 3 --cellularMode active --cellularBars 4 || true
  xcrun simctl ui "$udid" appearance dark || true

  # A known state: Feel the Beat on (the Settings shot shows it), A440, and a
  # few favorites so the tuning sheet shows what the feature is for.
  local d=(xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID")
  "${d[@]}" zf.beatHapticsEnabled -bool YES
  "${d[@]}" zf.hapticsEnabled -bool YES
  "${d[@]}" zf.referenceA -float 440
  "${d[@]}" zf.tuningID -string guitar.standard
  "${d[@]}" zf.favoritesOnly -bool YES
  "${d[@]}" zf.favoriteTunings -array guitar.standard guitar.dropD guitar.dadgad bass.four ukulele.standard
}

capture() {
  local udid="$1" out="$2" midi="$3" cents="$4" sheet="$5"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "$sheet" == "-" ]]; then sheet=""; fi
  SIMCTL_CHILD_ZF_POSE_MIDI="$midi" \
  SIMCTL_CHILD_ZF_POSE_CENTS="$cents" \
  SIMCTL_CHILD_ZF_HIDE_DEMO=1 \
  SIMCTL_CHILD_ZF_SHEET="$sheet" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  # Engine start, a detection window, the smoother settling and, for a
  # sheet, its 2.5 s delay plus the presentation animation.
  sleep 6
  xcrun simctl io "$udid" screenshot "$out" >/dev/null
}

only="${1:-}"
for device in "${DEVICES[@]}"; do
  IFS='|' read -r key name width height <<<"$device"
  [[ -n "$only" && "$only" != "$key" ]] && continue
  UDID=$(udid "$name")
  if [[ -z "$UDID" ]]; then
    echo "error: no simulator named \"$name\"" >&2
    exit 1
  fi
  echo "==> $key: $name ($UDID)"
  prepare "$UDID"

  mkdir -p "$ROOT/$key/capture"
  framed=()
  for shot in "${SHOTS[@]}"; do
    IFS='|' read -r devices file midi cents sheet headline subline <<<"$shot"
    [[ ",$devices," == *",$key,"* ]] || continue
    capture "$UDID" "$ROOT/$key/capture/$file.png" "$midi" "$cents" "$sheet"
    swift Scripts/storeframe.swift "$ROOT/$key/capture/$file.png" "$ROOT/$key/$file.png" \
      "$width" "$height" "$headline" "$subline"
    framed+=("$ROOT/$key/$file.png")
  done
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

  # About the height of an App Store card on a phone, so the headlines are
  # judged at the size people meet them.
  swift Scripts/contactsheet.swift "$ROOT/contact-$key.png" 640 "Zero Fret 1.1 — $name" "${framed[@]}"
done
