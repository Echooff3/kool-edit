#!/usr/bin/env bash
# Build and install Kool Edit, and register it with Launch Services so Finder offers it
# under "Open With". Pass --default to also make it the default app for audio files.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

# Quit a running copy so the new one is picked up.
if pgrep -xq kool-edit; then
    osascript -e 'tell application id "dev.kooledit.KoolEdit" to quit' >/dev/null 2>&1 || true
    sleep 1
fi

rm -rf "$DEST/Kool Edit.app"
cp -R "target/release/Kool Edit.app" "$DEST/"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST/Kool Edit.app"

echo "Installed $DEST/Kool Edit.app"

if [ "${1:-}" = "--default" ]; then
    "$DEST/Kool Edit.app/Contents/MacOS/kool-edit" --make-default
else
    echo "To make it your default audio player, run: $0 --default"
    echo "(or use File ▸ Make Default Audio Player inside the app)"
fi
