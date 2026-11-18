#!/bin/bash
# Builds build/Netdeck.app (release). Usage: scripts/make-app.sh [--sandbox] [--notarize] [--open]
#   Without --notarize the app is ad-hoc signed: fine on this Mac, blocked by Gatekeeper elsewhere.
#   --sandbox   signs with Resources/Netdeck.entitlements (App Sandbox, as in the Mac App Store build).
#               network.client: SSH (embedded client) and HTTPS APIs; device.serial: USB console adapters.
#               Nothing else is needed: files live in the container, passwords in the Keychain.
#               (codesign rejects XML comments in entitlements, so the reasons are kept here.)
#   --notarize  for distribution: signs with the "Developer ID Application" identity in the keychain
#               (NETDECK_SIGN_IDENTITY picks another), hardened runtime and a secure timestamp; sends the app
#               to Apple's notary service with the notarytool keychain profile "netdeck"
#               (NETDECK_NOTARY_PROFILE; create it once with `xcrun notarytool store-credentials netdeck`),
#               staples the ticket and writes build/Netdeck-<version>-macOS-<arch>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
SANDBOX=0 OPEN=0 NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --sandbox) SANDBOX=1 ;;
    --notarize) NOTARIZE=1 ;;
    --open) OPEN=1 ;;
    *) echo "usage: scripts/make-app.sh [--sandbox] [--notarize] [--open]" >&2; exit 2 ;;
  esac
done

if [ "$NOTARIZE" = 1 ]; then
  IDENTITY=${NETDECK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
  if [ -z "$IDENTITY" ]; then
    echo "No \"Developer ID Application\" identity in the keychain." >&2
    exit 1
  fi
  PROFILE=${NETDECK_NOTARY_PROFILE:-netdeck}
  SIGN=(--force --sign "$IDENTITY" --timestamp --options runtime)
else
  SIGN=(--force --sign -)
fi

swift build -c release --product Netdeck
BIN_DIR=$(swift build -c release --show-bin-path)
APP=build/Netdeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Netdeck" "$APP/Contents/MacOS/Netdeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

# Nested resource bundles first, then the app itself (inside out, without --deep).
for b in "$APP"/Contents/Resources/*.bundle; do [ -e "$b" ] && codesign "${SIGN[@]}" "$b" >/dev/null; done
if [ "$SANDBOX" = 1 ]; then
  codesign "${SIGN[@]}" --entitlements Resources/Netdeck.entitlements "$APP" >/dev/null
else
  codesign "${SIGN[@]}" "$APP" >/dev/null
fi
codesign --verify --deep --strict "$APP"
echo "$APP"

if [ "$NOTARIZE" = 1 ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  ZIP="build/Netdeck-$VERSION-macOS-$(uname -m).zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Sending $ZIP to the notary service (usually a few minutes)..."
  RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)
  STATUS=$(plutil -extract status raw -o - - <<<"$RESULT")
  if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization: $STATUS" >&2
    ID=$(plutil -extract id raw -o - - <<<"$RESULT" || true)
    [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$APP"
  # Zip again so the download carries the stapled ticket and opens offline too.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
  echo "$ZIP"
  shasum -a 256 "$ZIP"
fi

if [ "$OPEN" = 1 ]; then open "$APP"; fi
