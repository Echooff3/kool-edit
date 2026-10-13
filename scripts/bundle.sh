#!/usr/bin/env bash
# Build "Kool Edit.app" in target/release/.
set -euo pipefail
cd "$(dirname "$0")/.."

cargo build --release --bins

APP="target/release/Kool Edit.app"
ICONSET="target/release/KoolEdit.iconset"

rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp target/release/kool-edit "$APP/Contents/MacOS/kool-edit"
cp macos/Info.plist "$APP/Contents/Info.plist"

target/release/make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/KoolEdit.icns"
rm -rf "$ICONSET"

# Ad-hoc sign the whole bundle so Launch Services treats it as one app.
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP"
