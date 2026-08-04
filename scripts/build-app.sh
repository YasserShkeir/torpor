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

# CFBundleVersion is what Sparkle compares, so Resources/Info.plist carries the
# real value and this only re-asserts it — a bundle can never ship with the two
# out of step, and one built by any other path is still correct.
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
# `otool … | grep -q` is a trap under `set -o pipefail`: grep exits at the first
# match and closes the pipe, otool then fails its write and exits 1, and pipefail
# promotes that to the pipeline's status. A *present* rpath reads as absent, and
# whether it happens at all depends on how fast otool fills the pipe — so it
# passes on one build and fails the next. Capture the dump instead of piping it.
has_framework_rpath() {
    case "$(otool -l "$APP/Contents/MacOS/Torpor")" in
        *"@executable_path/../Frameworks"*) return 0 ;;
        *) return 1 ;;
    esac
}

if ! has_framework_rpath; then
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

# Entitlements go on the app alone. The file is deliberately an empty dict —
# Torpor requests nothing — so this is now about pinning that emptiness rather
# than granting anything. Sparkle's helpers are signed without it.
APP_SIGN_ARGS=("${SIGN_ARGS[@]}")
if [ -n "${IDENTITY:-}" ]; then
    ENTITLEMENTS="$ROOT/Resources/Torpor.entitlements"
    [ -f "$ENTITLEMENTS" ] || { echo "missing $ENTITLEMENTS" >&2; exit 1; }
    APP_SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${APP_SIGN_ARGS[@]}" "$APP"

codesign --verify --deep --strict "$APP" && echo "    signature verifies"
if [ -n "${IDENTITY:-}" ]; then
    echo "    signed with: $IDENTITY"
    # Inverted on purpose. This used to assert the Apple-events entitlement was
    # PRESENT, back when revive drove Terminal over Apple events. Nothing sends
    # an Apple event any more, so the entitlement is gone and the check now
    # guards its absence: shipping it again would let macOS ask a user for
    # Automation permission Torpor has no use for. See Resources/Torpor.entitlements.
    if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "apple-events"; then
        echo "    apple-events entitlement PRESENT — Torpor requests no entitlements; remove it" >&2
        exit 1
    fi
    echo "    requests no entitlements (no Automation permission is ever asked for)"
else
    echo "    ad-hoc signed (set IDENTITY to sign with Developer ID)"
fi
lipo -archs "$APP/Contents/MacOS/Torpor" | sed 's/^/    architectures: /'
has_framework_rpath \
    && echo "    framework rpath present" || { echo "    MISSING framework rpath" >&2; exit 1; }

# Notarisation. Apple has to see the build before Gatekeeper will open it on a
# machine that didn't compile it, and the ticket has to be stapled into the
# bundle so a first launch works offline.
#
# Two ways to authenticate, because CI and a laptop want different things:
#   NOTARY_PROFILE   a keychain profile from `xcrun notarytool store-credentials`
#   NOTARY_KEY_ID + NOTARY_ISSUER_ID + NOTARY_KEY_PATH   an App Store Connect key
# Neither set means skip, so an unsigned local build still works.
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
    if [ -z "${IDENTITY:-}" ]; then
        echo "==> Notarising: skipped, an ad-hoc signature is always rejected" >&2
        exit 1
    fi
    echo "==> Notarising"
    NOTARY_ZIP="$(dirname "$APP")/notarize.zip"
    # ditto, not zip: the symlinks inside Sparkle.framework must survive, and a
    # dereferenced copy fails the notary's own signature check.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_ARGS[@]}" --wait
    rm -f "$NOTARY_ZIP"

    # Staple the bundle, not the zip. Without this the first launch needs a
    # working network round-trip to Apple, which is exactly when it fails.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP" && echo "    ticket stapled"
    # The real question is not whether it is signed but whether Gatekeeper will
    # run it. spctl answers that one.
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo
echo "Built: $APP"
echo "Run:   open \"$APP\""
