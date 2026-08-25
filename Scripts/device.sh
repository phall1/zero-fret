#!/usr/bin/env bash
#
# Build Zero Fret and run it on a connected iPhone.
#
#   Scripts/device.sh              # first reachable device
#   Scripts/device.sh <name|udid>  # a specific one
#   Scripts/device.sh --list       # just show what's visible
#
# The Simulator is deliberately not supported here: its microphone resamples and
# applies processing you cannot disable, so it produces plausible-looking wrong
# answers (spec §9). In the Simulator the app feeds itself a generated signal
# and labels the readout DEMO.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=dev.phux.zerofret
DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Debug-iphoneos/ZeroFret.app"

JSON=$(mktemp -t zerofret-devices.XXXXXX)
trap 'rm -f "$JSON"' EXIT
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true

# Parsed as JSON rather than by column: a device named "Pat's iPhone" has spaces
# in it, and an awk field split silently picks the wrong column.
describe() {
  python3 - "$JSON" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in data.get("result", {}).get("devices", []):
    props = dev.get("deviceProperties", {})
    conn = dev.get("connectionProperties", {})
    print("  {:<24} {:<14} {:<10} {}".format(
        props.get("name", "?"),
        conn.get("tunnelState", "?"),
        conn.get("pairingState", "?"),
        dev.get("identifier", "?")))
PY
}

resolve() {
  python3 - "$JSON" "${1:-}" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
wanted = sys.argv[2] if len(sys.argv) > 2 else ""
devices = data.get("result", {}).get("devices", [])
def reachable(d):
    return d.get("connectionProperties", {}).get("tunnelState") in ("connected", "available")
for d in devices:
    name = d.get("deviceProperties", {}).get("name", "")
    ident = d.get("identifier", "")
    if wanted and wanted not in (name, ident):
        continue
    if wanted or reachable(d):
        print(ident)
        break
PY
}

echo "==> devices"
echo "  NAME                     TUNNEL         PAIRING    IDENTIFIER"
describe

if [[ "${1:-}" == "--list" ]]; then exit 0; fi

TARGET=$(resolve "${1:-}")
if [[ -z "$TARGET" ]]; then
  cat >&2 <<'MSG'

error: no reachable device.

  - Plug the iPhone in over USB
  - Unlock it and tap Trust This Computer
  - Settings > Privacy & Security > Developer Mode must be on

A device whose tunnel state is "unavailable" is paired but not currently
reachable. Pass a name or UDID explicitly to try it anyway.
MSG
  exit 1
fi
echo "==> target $TARGET"

set +e
xcodebuild build \
  -project ZeroFret.xcodeproj \
  -scheme ZeroFret \
  -configuration Debug \
  -destination "id=$TARGET" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates 2>&1 | tee build/device.log
STATUS=${PIPESTATUS[0]}
set -e

if [[ $STATUS -ne 0 ]]; then
  if grep -q "No Accounts" build/device.log; then
    cat >&2 <<'MSG'

------------------------------------------------------------------------------
Xcode has no Apple ID signed in, so it cannot register the App ID or create a
provisioning profile.

  Xcode > Settings > Accounts > + > Apple ID, sign in, then re-run this script.

See docs/SHIPPING.md for the headless alternative (an App Store Connect API key).
------------------------------------------------------------------------------
MSG
  fi
  exit $STATUS
fi

echo "==> installing"
xcrun devicectl device install app --device "$TARGET" "$APP"
echo "==> launching"
xcrun devicectl device process launch --device "$TARGET" "$BUNDLE_ID"

cat <<'MSG'

Running. On the phone:
  - grant the microphone prompt
  - pick a string and play it

Device-only acceptance checks are in docs/ACCEPTANCE.md; §9 says tests 1, 4 and
5 are the ones that fail, so start there.
MSG
