#!/usr/bin/env bash
#
# Archive Zero Fret, export a signed .ipa, and optionally upload it to
# App Store Connect for TestFlight.
#
#   Scripts/archive.sh                 # archive + export only
#   Scripts/archive.sh --upload        # ...and upload to App Store Connect
#   Scripts/archive.sh --build 7       # set the build number
#
# Signing credentials, in order of preference:
#
#   1. An App Store Connect API key (fully headless, and the only option that
#      works over SSH):
#        export ASC_KEY_ID=XXXXXXXXXX
#        export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#        export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
#      Create one at App Store Connect > Users and Access > Integrations > Keys
#      with the "App Manager" role.
#
#   2. An Apple ID signed into Xcode (Xcode > Settings > Accounts). Enough to
#      archive and export; uploading then also needs an app-specific password:
#        export ASC_APPLE_ID=you@example.com
#        export ASC_APP_PASSWORD=abcd-efgh-ijkl-mnop     # appleid.apple.com
#
# Neither is stored in this repo. Config/Signing.xcconfig, which carries the
# team ID, is gitignored.

set -euo pipefail

cd "$(dirname "$0")/.."

# Load local App Store Connect credentials if present. .env.asc is gitignored;
# see docs/SHIPPING.md for what goes in it.
if [[ -f .env.asc ]]; then
  # shellcheck disable=SC1091
  source .env.asc
fi

SCHEME=ZeroFret
PROJECT=ZeroFret.xcodeproj
BUILD_DIR=build
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
SIGNING="Config/Signing.xcconfig"

UPLOAD=0
BUILD_NUMBER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload) UPLOAD=1; shift ;;
    --build)  BUILD_NUMBER="${2:?--build needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$SIGNING" ]]; then
  cat >&2 <<MSG
error: $SIGNING is missing.

  cp Config/Signing.example.xcconfig $SIGNING
  \$EDITOR $SIGNING     # set DEVELOPMENT_TEAM to your team ID

It is gitignored on purpose so no account identifier ends up in the public repo.
MSG
  exit 1
fi

TEAM_ID=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$SIGNING" | head -1)
if [[ -z "$TEAM_ID" ]]; then
  echo "error: no DEVELOPMENT_TEAM found in $SIGNING" >&2
  exit 1
fi
echo "==> team $TEAM_ID"

AUTH=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
  [[ -f "$KEY_PATH" ]] || { echo "error: ASC_KEY_PATH not found: $KEY_PATH" >&2; exit 1; }
  AUTH=(-authenticationKeyPath "$KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "==> using App Store Connect API key $ASC_KEY_ID"
else
  echo "==> no API key set; relying on an Apple ID signed into Xcode"
fi

VERSION_FLAGS=()
if [[ -n "$BUILD_NUMBER" ]]; then
  VERSION_FLAGS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
  echo "==> build number $BUILD_NUMBER"
fi

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

echo "==> archiving"
set +e
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  "${AUTH[@]}" \
  "${VERSION_FLAGS[@]}" 2>&1 | tee "$BUILD_DIR/archive.log"
STATUS=${PIPESTATUS[0]}
set -e

if [[ $STATUS -ne 0 ]]; then
  if grep -q "No Accounts" "$BUILD_DIR/archive.log"; then
    cat >&2 <<'MSG'

------------------------------------------------------------------------------
Xcode has no Apple ID signed in, so it cannot register the App ID or create a
provisioning profile. Fix it one of two ways, then re-run this script:

  A. Xcode > Settings > Accounts > + > Apple ID, and sign in.

  B. Create an App Store Connect API key with the App Manager role at
     App Store Connect > Users and Access > Integrations > Keys, then:

       mkdir -p ~/.appstoreconnect/private_keys
       mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
       export ASC_KEY_ID=XXXXXXXXXX
       export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
       export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8

     Option B is the only one that works without a GUI, and the only one that
     works in CI.

Full log: build/archive.log
------------------------------------------------------------------------------
MSG
  fi
  exit $STATUS
fi

# Written at run time so the team ID never lands in a tracked file.
PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PL

echo "==> exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PLIST" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  "${AUTH[@]}"

IPA=$(find "$EXPORT_DIR" -name '*.ipa' | head -1)
[[ -n "$IPA" ]] || { echo "error: no .ipa produced" >&2; exit 1; }
echo "==> exported $IPA"

if [[ "$UPLOAD" -eq 0 ]]; then
  cat <<MSG

Done. To upload to TestFlight:

  Scripts/archive.sh --upload

or open Xcode > Window > Organizer, select the archive, Distribute App.
MSG
  exit 0
fi

echo "==> validating"
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "==> uploading"
  xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
elif [[ -n "${ASC_APPLE_ID:-}" && -n "${ASC_APP_PASSWORD:-}" ]]; then
  xcrun altool --validate-app -f "$IPA" -t ios \
    -u "$ASC_APPLE_ID" -p "$ASC_APP_PASSWORD"
  echo "==> uploading"
  xcrun altool --upload-app -f "$IPA" -t ios \
    -u "$ASC_APPLE_ID" -p "$ASC_APP_PASSWORD"
else
  cat >&2 <<MSG
error: --upload needs credentials.

  API key:            ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
  or Apple ID:        ASC_APPLE_ID, ASC_APP_PASSWORD

See the header of this script.
MSG
  exit 1
fi

echo "==> uploaded. Processing takes a few minutes; the build then appears"
echo "    under TestFlight in App Store Connect."
