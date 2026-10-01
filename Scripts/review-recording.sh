#!/usr/bin/env bash
#
# Capture an App Review screen recording of Zero Fret.
#
#   Scripts/review-recording.sh              # phone if it is unlocked, else simulator
#   Scripts/review-recording.sh --simulator  # latest installed iOS runtime
#   Scripts/review-recording.sh --device     # connected iPhone; refuses a locked phone
#
# The file starts on the home screen (simulator) or the current screen (phone),
# then cold-launches the app and walks the typical flow: idle, flat, in tune,
# sharp, tuning sheet, settings, pin. A generated string is fed through the real
# detector so no instrument has to be in the room. That path is Debug-only.
# Release, which is what ships, does not compile it.
#
# Output:
#   AppStore/review/zero-fret-review-simulator.mp4
#   AppStore/review/zero-fret-review-device.mp4   (only if the phone can record)
#   AppStore/review/CAPTURE.txt
#
set -euo pipefail
cd "$(dirname "$0")/.."

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"
export PATH

BUNDLE_ID=dev.phux.zerofret
OUT_DIR=AppStore/review
# Simulator and device files are separate so a failed device capture cannot
# delete a recording that already exists.
SIM_OUT="$OUT_DIR/zero-fret-review-simulator.mp4"
DEVICE_OUT="$OUT_DIR/zero-fret-review-device.mp4"
CAPTURE="$OUT_DIR/CAPTURE.txt"
DERIVED=build/DerivedData-review
# ReviewTour.finished, plus launch and a short tail so the last shot is in the file.
HOLD_SECONDS=40

mkdir -p "$OUT_DIR" build

mode="${1:-auto}"

phone_udid() {
  xcrun devicectl list devices --json-output - 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for dev in data.get("result", {}).get("devices", []):
    props = dev.get("deviceProperties", {})
    hw = dev.get("hardwareProperties", {})
    conn = dev.get("connectionProperties", {})
    if hw.get("reality") != "physical" or hw.get("platform") != "iOS":
        continue
    if conn.get("tunnelState") not in ("connected", "available"):
        continue
    print(hw.get("udid") or dev.get("identifier", ""))
    print(hw.get("marketingName") or props.get("name") or "iPhone")
    print(props.get("osVersionNumber", ""))
    break
'
}

phone_is_unlocked() {
  local udid="$1"
  local err
  # A locked phone denies every launch with FBSOpenApplicationErrorDomain Locked.
  # Probing with SpringBoard does not open Safari if the phone is unlocked.
  err=$(xcrun devicectl device process launch --device "$udid" com.apple.springboard 2>&1 || true)
  if grep -q "Locked" <<<"$err"; then
    return 1
  fi
  return 0
}

latest_simulator() {
  # Newest available iPhone runtime, preferring an already-booted phone.
  xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
best = None
for runtime, devices in data.get("devices", {}).items():
    # runtime is a platform identifier; the version sits at the end, e.g. iOS-27-0
    # com.apple.CoreSimulator.SimRuntime.iOS-27-0 → 27.0
    version = runtime.rsplit(".", 1)[-1].split("-", 1)[-1].replace("-", ".")
    for dev in devices:
        if not dev.get("isAvailable", False):
            continue
        name = dev.get("name", "")
        if not name.startswith("iPhone"):
            continue
        booted = 1 if dev.get("state") == "Booted" else 0
        rank = (version, booted, name)
        if best is None or rank > best[0]:
            best = (rank, dev.get("udid"), name, version.replace("-", "."), "booted" if booted else "shutdown")
if not best:
    sys.exit("no iPhone simulator")
print(best[1])
print(best[2])
print(best[3])
print(best[4])
'
}

record_simulator() {
  local udid="$1" name="$2" version="$3" state="$4"
  local app="$DERIVED/Build/Products/Debug-iphonesimulator/ZeroFret.app"
  local log
  log=$(mktemp -t zerofret-record.XXXXXX)

  echo "==> simulator $name ($version, $state) $udid"
  if [[ "$state" != "booted" ]]; then
    xcrun simctl boot "$udid"
  fi
  xcrun simctl bootstatus "$udid" -b

  echo "==> build"
  xcodebuild build \
    -project ZeroFret.xcodeproj \
    -scheme ZeroFret \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

  echo "==> install"
  xcrun simctl install "$udid" "$app"
  xcrun simctl privacy "$udid" grant microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --batteryState charged \
    --batteryLevel 100 \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 || true
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

  # Home screen, so the file begins with the launch rather than mid-flow.
  # Needs Accessibility for System Events; a miss is not fatal — launch still
  # opens the app from whatever is showing.
  osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application "Simulator" to activate
delay 0.4
tell application "System Events"
  keystroke "h" using {command down, shift down}
end tell
APPLESCRIPT
  sleep 0.6

  echo "==> record"
  local raw="$OUT_DIR/.raw-simulator.mp4"
  rm -f "$raw"
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$raw" >"$log" 2>&1 &
  local rec_pid=$!
  local i
  for i in $(seq 1 80); do
    if grep -q "Recording started" "$log"; then
      break
    fi
    if ! kill -0 "$rec_pid" 2>/dev/null; then
      echo "error: simctl recordVideo exited early" >&2
      cat "$log" >&2
      exit 1
    fi
    sleep 0.1
  done
  sleep 1.2

  xcrun simctl launch "$udid" "$BUNDLE_ID" -zf-review-tour -zf-hide-demo >/dev/null
  sleep "$HOLD_SECONDS"

  kill -INT "$rec_pid" 2>/dev/null || true
  wait "$rec_pid" 2>/dev/null || true
  rm -f "$log"

  echo "==> compress"
  compress "$raw" "$SIM_OUT"
  write_capture "simulator" "$name" "$version" "$udid" "$SIM_OUT"
}

record_device() {
  local udid="$1" name="$2" version="$3"
  local app="$DERIVED/Build/Products/Debug-iphoneos/ZeroFret.app"

  if ! phone_is_unlocked "$udid"; then
    echo "error: $name is locked. Unlock it, leave it face up, and re-run." >&2
    echo "       A locked phone records a black frame. Apple will not accept that." >&2
    exit 2
  fi

  echo "==> device $name (iOS $version) $udid"
  echo "==> build"
  xcodebuild build \
    -project ZeroFret.xcodeproj \
    -scheme ZeroFret \
    -configuration Debug \
    -destination "id=$udid" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    -quiet

  echo "==> install"
  xcrun devicectl device install app --device "$udid" "$app"

  echo "==> record"
  # `--` is required. Without it devicectl reads `-zf-review-tour` as its own
  # `-t` flag and the launch never happens.
  # iPhone 13 Pro (and some other devices) report screen recording unsupported.
  # Fail before deleting anything, and say so.
  if ! xcrun devicectl device capture screen-record --help >/dev/null 2>&1; then
    echo "error: devicectl screen-record is not available" >&2
    exit 1
  fi
  local raw="$OUT_DIR/.raw-device.mp4"
  rm -f "$raw"
  xcrun devicectl device capture screen-record \
    --device "$udid" \
    --destination "$raw" \
    --codec h264 \
    --duration "$((HOLD_SECONDS + 8))" &
  local rec_pid=$!
  sleep 2
  if ! kill -0 "$rec_pid" 2>/dev/null; then
    echo "error: this iPhone does not support developer screen recording." >&2
    echo "       Unlock it, start the Control Center screen recording, then run:" >&2
    echo "       xcrun devicectl device process launch --device $udid --terminate-existing $BUNDLE_ID -- -zf-review-tour -zf-hide-demo" >&2
    wait "$rec_pid" 2>/dev/null || true
    exit 2
  fi
  xcrun devicectl device process launch \
    --device "$udid" \
    --terminate-existing \
    "$BUNDLE_ID" -- -zf-review-tour -zf-hide-demo
  wait "$rec_pid"
  compress "$raw" "$DEVICE_OUT"
  write_capture "physical" "$name" "$version" "$udid" "$DEVICE_OUT"
}

write_capture() {
  local kind="$1" name="$2" version="$3" udid="$4" file="$5"
  local when
  when=$(date "+%Y-%m-%d %H:%M %Z")
  cat >"$CAPTURE" <<EOF
kind: $kind
device: $name
os: iOS $version
udid: $udid
captured: $when
file: $file
signal: generated plucked-string through the shipping detector (Debug review tour only)
begins: cold launch, then idle → flat → in tune → sharp → tuning sheet (Drop D) → settings (A=442, Feel the beat) → pin
EOF
  echo "==> $file"
  if command -v ffprobe >/dev/null; then
    ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$file" || true
  fi
  ls -lh "$file"
}

# simctl writes a very high bitrate. App Review attachments do not need it.
compress() {
  local src="$1" dest="$2"
  local tmp="${dest}.tmp.mp4"
  if ! command -v ffmpeg >/dev/null; then
    mv "$src" "$dest"
    return
  fi
  ffmpeg -y -i "$src" -an -c:v libx264 -crf 20 -preset fast -pix_fmt yuv420p \
    -movflags +faststart "$tmp" -loglevel error
  mv "$tmp" "$dest"
  rm -f "$src"
}

read_lines() {
  local i=0 line
  while IFS= read -r line; do
    eval "$1_$i=\$line"
    i=$((i + 1))
  done
}

case "$mode" in
  --simulator)
    read_lines sim < <(latest_simulator)
    record_simulator "$sim_0" "$sim_1" "$sim_2" "$sim_3"
    ;;
  --device)
    read_lines phone < <(phone_udid)
    if [[ -z "${phone_0:-}" ]]; then
      echo "error: no connected iPhone" >&2
      exit 1
    fi
    record_device "$phone_0" "$phone_1" "$phone_2"
    ;;
  auto|"")
    read_lines phone < <(phone_udid || true)
    if [[ -n "${phone_0:-}" ]] && phone_is_unlocked "$phone_0"; then
      record_device "$phone_0" "$phone_1" "$phone_2"
    else
      if [[ -n "${phone_0:-}" ]]; then
        echo "==> ${phone_1} is connected but locked; recording the simulator instead"
        echo "    unlock it and run: Scripts/review-recording.sh --device"
      fi
      read_lines sim < <(latest_simulator)
      record_simulator "$sim_0" "$sim_1" "$sim_2" "$sim_3"
    fi
    ;;
  *)
    echo "usage: Scripts/review-recording.sh [--simulator|--device]" >&2
    exit 1
    ;;
esac
