#!/bin/bash
# Builds build/Netdeck.app (release, ad-hoc signed). Usage: scripts/make-app.sh [--sandbox] [--open]
#   --sandbox  signs with Resources/Netdeck.entitlements (App Sandbox, as in the Mac App Store build).
#              network.client: SSH (embedded client) and HTTPS APIs; device.serial: USB console adapters.
#              Nothing else is needed: files live in the container, passwords in the Keychain.
#              (codesign rejects XML comments in entitlements, so the reasons are kept here.)
set -euo pipefail
cd "$(dirname "$0")/.."
SANDBOX=0 OPEN=0
for arg in "$@"; do
  case "$arg" in
    --sandbox) SANDBOX=1 ;;
    --open) OPEN=1 ;;
    *) echo "usage: scripts/make-app.sh [--sandbox] [--open]" >&2; exit 2 ;;
  esac
done
swift build -c release --product Netdeck
BIN_DIR=$(swift build -c release --show-bin-path)
APP=build/Netdeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Netdeck" "$APP/Contents/MacOS/Netdeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
if [ "$SANDBOX" = 1 ]; then
  codesign --force --deep --sign - --entitlements Resources/Netdeck.entitlements "$APP" >/dev/null
else
  codesign --force --deep --sign - "$APP" >/dev/null
fi
echo "$APP"
if [ "$OPEN" = 1 ]; then open "$APP"; fi
