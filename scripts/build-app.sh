#!/bin/bash
# Build Torpor.app from the Swift package.
#
# Usage:
#   scripts/build-app.sh                 # ad-hoc signed, runs locally
#   IDENTITY="Developer ID Application: You (TEAMID)" scripts/build-app.sh
#
# Ad-hoc signing is enough for the app to run on the machine that built it and
# for Automation (AppleEvents) consent to stick. Distributing to anyone else
# requires a Developer ID identity plus notarization — see README.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/Torpor.app"
CONFIG="${CONFIG:-release}"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Torpor"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Torpor"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon, if one has been generated into Resources/.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> Signing"
if [ -n "${IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$APP"
    echo "    signed with: $IDENTITY"
    echo "    next: xcrun notarytool submit --keychain-profile <profile> --wait \\"
    echo "            \"\$(cd dist && zip -qr Torpor.zip Torpor.app && echo dist/Torpor.zip)\""
    echo "          xcrun stapler staple \"$APP\""
else
    codesign --force --sign - "$APP"
    echo "    ad-hoc signed (local use only)"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built: $APP"
echo "Run:   open \"$APP\""
