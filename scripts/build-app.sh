#!/bin/bash
# Build Torpor.app from the Swift package.
#
#   scripts/build-app.sh
#   IDENTITY="Developer ID Application: You (TEAMID)" scripts/build-app.sh
#
# Ad-hoc signing is enough to run locally AND to ship: Sparkle verifies updates
# with an EdDSA signature over the archive, not with an Apple certificate. What
# ad-hoc signing does NOT buy is notarisation — see the README's Gatekeeper
# section — or stable Automation/Keychain grants across updates.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/Torpor.app"
CONFIG="${CONFIG:-release}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

echo "==> Building Torpor $VERSION ($CONFIG, universal)"
# Universal, so the release runs on Intel too. `swift build` alone is host-arch
# only, which would silently ship an arm64-only zip.
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/Torpor"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Torpor"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# One version number to bump per release: CFBundleVersion is what Sparkle
# compares, and deriving it here means it can never drift from the one in
# Resources/Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> Embedding Sparkle"
SPARKLE_FW=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" | head -1)
[ -n "$SPARKLE_FW" ] || { echo "Sparkle.framework not found — run: swift package resolve" >&2; exit 1; }
# -R preserves the framework's internal symlinks. `cp -r` would flatten them and
# produce a bundle whose signature can never verify.
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# The binary links Sparkle as @rpath/Sparkle.framework/..., but SwiftPM only
# emits rpaths for its own layout (@executable_path/../lib). Without this the
# app builds, signs and verifies cleanly and then dies at launch with
# "Library missing" — which looks like a Gatekeeper problem and is not one.
# Must run before signing: it rewrites the Mach-O and invalidates any signature.
if ! otool -l "$APP/Contents/MacOS/Torpor" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Torpor"
fi

echo "==> Signing"
# Nested code first, outside-in, or the outer signature seals a stale inner one.
SIGN_ARGS=(--force --timestamp=none)
if [ -n "${IDENTITY:-}" ]; then SIGN_ARGS+=(--options runtime --timestamp --sign "$IDENTITY")
else SIGN_ARGS+=(--sign -); fi

for inner in "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc \
             "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
             "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"; do
    [ -e "$inner" ] && codesign "${SIGN_ARGS[@]}" "$inner" 2>/dev/null || true
done
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$APP"

codesign --verify --deep --strict "$APP" && echo "    signature verifies"
[ -n "${IDENTITY:-}" ] && echo "    signed with: $IDENTITY" || echo "    ad-hoc signed"
lipo -archs "$APP/Contents/MacOS/Torpor" | sed 's/^/    architectures: /'
otool -l "$APP/Contents/MacOS/Torpor" | grep -q '@executable_path/../Frameworks' \
    && echo "    framework rpath present" || { echo "    MISSING framework rpath" >&2; exit 1; }

echo
echo "Built: $APP"
echo "Run:   open \"$APP\""
