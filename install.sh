#!/bin/bash
# Installs Music for YouTube into /Applications and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/emonsaqibh/music-for-youtube-releases/main/install.sh | bash
#   … | bash -s -- 0.2.0-beta.2      (a specific version)
#
# Why a script rather than a download link: the app isn't notarized by Apple, and macOS
# refuses to open an un-notarized app that was downloaded in a browser. Files fetched with
# curl aren't marked as downloads, so the app opens normally. After this first install the
# app keeps itself up to date.
set -euo pipefail

REPO="emonsaqibh/music-for-youtube-releases"
ASSET="Music-for-YouTube.zip"
APP_NAME="Music for YouTube"
DEST="${DEST:-/Applications}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "this app is for macOS."
[ "$(uname -m)" = arm64 ] || fail "this app needs an Apple silicon Mac."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "this app needs macOS 26 or later (you have $(sw_vers -productVersion))."

if [ -n "${1:-}" ]; then
    URL="https://github.com/$REPO/releases/download/v${1#v}/$ASSET"
else
    URL="https://github.com/$REPO/releases/latest/download/$ASSET"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading ${APP_NAME}…"
curl -fL --progress-bar "$URL" -o "$TMP/$ASSET" || fail "couldn't download $URL"
ditto -x -k "$TMP/$ASSET" "$TMP/unzipped"
APP="$TMP/unzipped/$APP_NAME.app"
[ -d "$APP" ] || fail "the download didn't contain $APP_NAME.app"
codesign --verify --deep "$APP" 2>/dev/null || fail "the downloaded app failed its signature check"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

TARGET="$DEST/$APP_NAME.app"
if pgrep -f "$TARGET/Contents/MacOS/YouTubeMusic" >/dev/null; then
    say "Quitting the running copy…"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do pgrep -f "$TARGET/Contents/MacOS/YouTubeMusic" >/dev/null || break; sleep 0.2; done
fi

say "Installing to $DEST…"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"

[ "${NO_OPEN:-}" = 1 ] || open "$TARGET"
say "Installed $APP_NAME $version. It will keep itself up to date."
