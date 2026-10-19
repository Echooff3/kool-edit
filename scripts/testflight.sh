#!/usr/bin/env bash
# Archive Kool Edit and upload it to TestFlight.
#
# Required environment:
#   ASC_KEY_ID       App Store Connect API key id
#   ASC_ISSUER_ID    App Store Connect issuer id
# Optional:
#   ASC_KEY_PATH     defaults to ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
#   ASC_TEAM_ID      defaults to X3LBX8Z44X
#
# The .p8 file is read by altool and xcodebuild from the path above. This
# script does not print it, copy it, or write it into the repository.
# Automatic signing is used. Certificates and profiles are not revoked or deleted.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
ASC_TEAM_ID="${ASC_TEAM_ID:-X3LBX8Z44X}"

if [[ ! -f "$ASC_KEY_PATH" ]]; then
  echo "App Store Connect key file is missing at the expected AuthKey path." >&2
  exit 1
fi

ICON="$ROOT/ios/KoolEdit/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
if [[ ! -f "$ICON" ]]; then
  echo "Missing 1024x1024 app icon at ios/KoolEdit/Assets.xcassets/AppIcon.appiconset/AppIcon.png" >&2
  exit 1
fi
ICON_WIDTH="$(sips -g pixelWidth "$ICON" | awk '/pixelWidth/ { print $2 }')"
ICON_HEIGHT="$(sips -g pixelHeight "$ICON" | awk '/pixelHeight/ { print $2 }')"
if [[ "$ICON_WIDTH" != "1024" || "$ICON_HEIGHT" != "1024" ]]; then
  echo "App icon must be 1024x1024 (found ${ICON_WIDTH}x${ICON_HEIGHT})." >&2
  exit 1
fi

INFO_PLIST="$ROOT/ios/Config/Info.plist"
ENCRYPTION="$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$ENCRYPTION" != "false" ]]; then
  echo "ios/Config/Info.plist must set ITSAppUsesNonExemptEncryption to false." >&2
  exit 1
fi

STATUS_JSON="$(mktemp)"
EXPORT_PLIST="$(mktemp -t kooledit-export.plist)"
ARCHIVE_LOG="$ROOT/ios/build/xcodebuild-archive.log"
EXPORT_LOG="$ROOT/ios/build/xcodebuild-export.log"
cleanup() {
  rm -f "$STATUS_JSON" "$EXPORT_PLIST"
}
trap cleanup EXIT

python3 "$ROOT/scripts/asc_api.py" prepare \
  --key-id "$ASC_KEY_ID" \
  --issuer-id "$ASC_ISSUER_ID" > "$STATUS_JSON"

BUILD_NUMBER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["buildNumber"])' "$STATUS_JSON")"
APPLE_APP_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["appleAppId"])' "$STATUS_JSON")"
echo "Uploading Kool Edit build $BUILD_NUMBER for Apple app $APPLE_APP_ID"

# xcodebuild can sit forever on a login-keychain dialog. Bail out as soon as
# SecurityAgent is actually waiting, instead of blocking the upload.
run_logged() {
  local log_file="$1"
  shift
  mkdir -p "$(dirname "$log_file")"
  "$@" >"$log_file" 2>&1 &
  local pid=$!
  local last_size=-1
  local stalled=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10
    if pgrep -x SecurityAgent >/dev/null 2>&1 && pgrep -x codesign >/dev/null 2>&1; then
      sleep 5
      if pgrep -x SecurityAgent >/dev/null 2>&1 && pgrep -x codesign >/dev/null 2>&1 && kill -0 "$pid" 2>/dev/null; then
        echo "SECURITY_AGENT_PROMPT" >&2
        echo "codesign is blocked by a SecurityAgent keychain prompt." >&2
        echo "Approve the login keychain prompt for codesign (Always Allow), then re-run scripts/testflight.sh." >&2
        pgrep -lf 'SecurityAgent|codesign' >&2 || true
        tail -40 "$log_file" >&2 || true
        local child
        for child in $(pgrep -P "$pid" || true); do
          kill "$child" 2>/dev/null || true
        done
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 3
      fi
    fi
    local size
    size="$(wc -c <"$log_file" | tr -d ' ')"
    if [[ "$size" == "$last_size" ]]; then
      stalled=$((stalled + 10))
    else
      stalled=0
      last_size="$size"
      tail -1 "$log_file" | cut -c1-220 || true
    fi
    if (( stalled >= 240 )); then
      echo "xcodebuild produced no output for 4 minutes." >&2
      if pgrep -lf 'SecurityAgent|codesign' >&2; then
        echo "A codesign or SecurityAgent process is still running." >&2
      fi
      local child
      for child in $(pgrep -P "$pid" || true); do
        kill "$child" 2>/dev/null || true
      done
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      exit 1
    fi
  done
  set +e
  wait "$pid"
  local status=$?
  set -e
  return "$status"
}

ARCHIVE="$ROOT/ios/build/KoolEdit.xcarchive"
EXPORT_DIR="$ROOT/ios/build/ipa"
DERIVED="$ROOT/ios/build/DerivedData"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$ROOT/ios/build"

echo "Archiving..."
if ! run_logged "$ARCHIVE_LOG" xcodebuild archive \
  -project "$ROOT/ios/KoolEdit.xcodeproj" \
  -scheme KoolEdit \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$ASC_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO
then
  echo "ARCHIVE_FAILED" >&2
  tail -80 "$ARCHIVE_LOG" >&2 || true
  exit 1
fi
echo "ARCHIVE_OK"

APP_PLIST="$ARCHIVE/Products/Applications/KoolEdit.app/Info.plist"
ARCHIVED_ENCRYPTION="$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$APP_PLIST")"
ARCHIVED_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP_PLIST")"
if [[ "$ARCHIVED_ENCRYPTION" != "false" ]]; then
  echo "Archived app is missing ITSAppUsesNonExemptEncryption=false." >&2
  exit 1
fi
if [[ "$ARCHIVED_BUILD" != "$BUILD_NUMBER" ]]; then
  echo "Archived CFBundleVersion is $ARCHIVED_BUILD, expected $BUILD_NUMBER." >&2
  exit 1
fi

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>${ASC_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

echo "Exporting IPA..."
if ! run_logged "$EXPORT_LOG" xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
then
  echo "EXPORT_FAILED" >&2
  tail -80 "$EXPORT_LOG" >&2 || true
  exit 1
fi
echo "EXPORT_OK"

IPA="$(find "$EXPORT_DIR" -name '*.ipa' -print | head -1)"
if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "No IPA to upload." >&2
  exit 1
fi

echo "Uploading $(basename "$IPA")"
UPLOAD_LOG="$ROOT/ios/build/altool-upload.log"
if ! run_logged "$UPLOAD_LOG" xcrun altool --upload-package "$IPA" \
  --api-key "$ASC_KEY_ID" \
  --api-issuer "$ASC_ISSUER_ID"
then
  echo "UPLOAD_FAILED" >&2
  tail -80 "$UPLOAD_LOG" >&2 || true
  exit 1
fi
echo "UPLOAD_OK"

echo "Waiting for App Store Connect to finish processing (up to 15 minutes)..."
STATE=""
DEADLINE=$((SECONDS + 900))
while (( SECONDS < DEADLINE )); do
  sleep 30
  BUILD_JSON="$(mktemp)"
  if python3 "$ROOT/scripts/asc_api.py" build-status \
    --key-id "$ASC_KEY_ID" \
    --issuer-id "$ASC_ISSUER_ID" \
    --app-id "$APPLE_APP_ID" > "$BUILD_JSON"
  then
    cat "$BUILD_JSON"
    STATE="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
want = sys.argv[2]
for build in data.get("builds", []):
    if str(build.get("version")) == want:
        print(build.get("processingState") or "")
        break
' "$BUILD_JSON" "$BUILD_NUMBER")"
  else
    echo "Build status lookup failed; retrying." >&2
    STATE=""
  fi
  rm -f "$BUILD_JSON"
  case "$STATE" in
    VALID|FAILED|INVALID)
      break
      ;;
  esac
done

echo "Apple app ID: $APPLE_APP_ID"
echo "Build number: $BUILD_NUMBER"
if [[ -z "$STATE" ]]; then
  echo "Processing state: not listed yet"
elif [[ "$STATE" == "FAILED" || "$STATE" == "INVALID" ]]; then
  echo "Processing state: $STATE"
  exit 1
elif [[ "$STATE" == "VALID" ]]; then
  echo "Processing state: VALID"
else
  echo "Processing state: ${STATE} (still processing after 15 minutes)"
fi
echo "Script: scripts/testflight.sh"
