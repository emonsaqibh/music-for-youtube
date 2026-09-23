#!/bin/bash
# Installs a released beta from GitHub into /Applications.
#
#   ./install.sh                 → the newest release
#   ./install.sh 0.2.0-beta.1    → a specific one
#
# Why not just download the zip in a browser: browsers mark downloads as quarantined, and
# since macOS 15 Gatekeeper refuses to open a quarantined app that isn't notarized by
# Apple ("Apple could not verify … is free of malware"). Our builds are ad-hoc signed, not
# notarized. Downloading with `gh` doesn't quarantine the file, so the app opens normally.
set -euo pipefail

REPO="emonsaqibh/music-for-youtube"
APP_NAME="Music for YouTube"
DEST="${DEST:-/Applications}"

command -v gh >/dev/null || { echo "needs the GitHub CLI: brew install gh && gh auth login" >&2; exit 1; }

if [ -n "${1:-}" ]; then
    TAG="v${1#v}"
else
    TAG="$(gh release list --repo "$REPO" --limit 1 --json tagName -q '.[0].tagName')"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading $TAG"
gh release download "$TAG" --repo "$REPO" --pattern '*.zip' --dir "$TMP"
ditto -x -k "$TMP"/*.zip "$TMP/unzipped"
APP="$TMP/unzipped/$APP_NAME.app"
[ -d "$APP" ] || { echo "no \"$APP_NAME.app\" in the $TAG download" >&2; exit 1; }
# Belt and braces, in case the zip itself came through a quarantining path.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

TARGET="$DEST/$APP_NAME.app"
if pgrep -f "$TARGET/Contents/MacOS/YouTubeMusic" >/dev/null; then
    echo "$APP_NAME is running — quit it, then run this again." >&2
    exit 1
fi

echo "==> installing to $TARGET"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
echo "==> installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"
