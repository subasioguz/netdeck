#!/bin/bash
# Builds build/Netdeck.app (release, ad-hoc signed). Usage: scripts/make-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Netdeck
BIN_DIR=$(swift build -c release --show-bin-path)
APP=build/Netdeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Netdeck" "$APP/Contents/MacOS/Netdeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
