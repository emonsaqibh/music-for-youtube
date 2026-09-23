#!/bin/bash
# Builds the app bundle and ad-hoc signs it.
#
#   ./build.sh                    → build/Music for YouTube Dev.app  (dev flavor, debug)
#   FLAVOR=beta VERSION=x ./build.sh  → build/Music for YouTube.app  (used by release.sh)
#
# The two flavors have different bundle identifiers, so they keep separate sign-in
# cookies, settings and logs and can run side by side. The dev build never touches the
# installed beta's data.
set -euo pipefail
cd "$(dirname "$0")"

FLAVOR="${FLAVOR:-dev}"
BASE_ID="dev.fringecore.ytmusic"
case "$FLAVOR" in
    dev)
        CONF="${CONF:-debug}"
        APP_NAME="Music for YouTube Dev"
        BUNDLE_ID="${BASE_ID}.dev"
        VERSION="${VERSION:-dev}"
        BUILD_NUMBER="$(date +%Y%m%d%H%M)"
        ;;
    beta)
        CONF="${CONF:-release}"
        APP_NAME="Music for YouTube"
        BUNDLE_ID="$BASE_ID"
        : "${VERSION:?FLAVOR=beta needs VERSION (use ./release.sh)}"
        BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
        ;;
    *) echo "unknown FLAVOR '$FLAVOR' (dev|beta)" >&2; exit 1 ;;
esac
APP="${OUT_DIR:-build}/${APP_NAME}.app"

echo "==> swift build (${CONF}, ${FLAVOR})"
swift build -c "$CONF" --arch arm64
BIN="$(swift build -c "$CONF" --arch arm64 --show-bin-path)/YouTubeMusic"

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YouTubeMusic"
cp Resources/Info.plist "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleName $APP_NAME" \
    -c "Set :CFBundleDisplayName $APP_NAME" \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP/Contents/Info.plist"
if [ -d Resources/AppIcon.icon ]; then
    # Icon Composer document → Assets.car (Liquid Glass, dark / tinted / clear) + AppIcon.icns.
    xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
        --app-icon AppIcon --platform macosx --minimum-deployment-target 26.0 \
        --target-device mac --output-partial-info-plist "build/icon-partial.plist" >/dev/null
elif [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $APP ($BUNDLE_ID $VERSION ($BUILD_NUMBER))"
