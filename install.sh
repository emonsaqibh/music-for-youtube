#!/bin/bash
# Installs Music for YouTube into /Applications and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/emonsaqibh/music-for-youtube/main/install.sh | bash
#   … | bash -s -- 0.2.0-beta.2      (a specific version)
#
# Why a script rather than a download link: the app isn't notarized by Apple, and macOS
# refuses to open an un-notarized app that was downloaded in a browser. Files fetched with
# curl aren't marked as downloads, so the app opens normally. After this first install the
# app keeps itself up to date.
set -euo pipefail

REPO="emonsaqibh/music-for-youtube"
APP_NAME="Music for YouTube"
DEST="${DEST:-/Applications}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "this app is for macOS."
[ "$(uname -m)" = arm64 ] || fail "this app needs an Apple silicon Mac."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "this app needs macOS 26 or later (you have $(sw_vers -productVersion))."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Which release: the one asked for, or the newest. Betas are GitHub pre-releases, which
# "releases/latest" skips, so take the first of the list (newest first) instead.
# plutil reads JSON, so this needs nothing beyond what macOS ships with.
if [ -n "${1:-}" ]; then
    API="https://api.github.com/repos/$REPO/releases/tags/v${1#v}"; P=""
else
    API="https://api.github.com/repos/$REPO/releases?per_page=1"; P="0."
fi
curl -fsSL "$API" -o "$TMP/release.json" || fail "couldn't reach GitHub ($API)"
field() { plutil -extract "$P$1" raw -o - "$TMP/release.json" 2>/dev/null; }
TAG="$(field tag_name)" || fail "no release found"

# The first .zip in a list of assets; $1 is the file, $2 the key path to the list.
zip_url() {
    local i name
    for i in 0 1 2 3 4 5 6 7 8 9; do
        name="$(plutil -extract "$2$i.name" raw -o - "$1" 2>/dev/null)" || return 1
        case "$name" in *.zip) plutil -extract "$2$i.browser_download_url" raw -o - "$1"; return ;; esac
    done
    return 1
}
URL="$(zip_url "$TMP/release.json" "${P}assets.")" || URL=""
if [ -z "$URL" ]; then
    # GitHub sometimes lags filling in a release's embedded asset list; its own assets
    # endpoint is up to date.
    ID="$(field id)"
    curl -fsSL "https://api.github.com/repos/$REPO/releases/$ID/assets" -o "$TMP/assets.json" \
        && URL="$(zip_url "$TMP/assets.json" "")" || URL=""
fi
[ -n "$URL" ] || fail "release $TAG has no app zip"

say "Downloading ${APP_NAME} ${TAG#v}…"
curl -fL --progress-bar "$URL" -o "$TMP/app.zip" || fail "couldn't download $URL"
ditto -x -k "$TMP/app.zip" "$TMP/unzipped"
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

say "Installing to ${DEST}…"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"

[ "${NO_OPEN:-}" = 1 ] || open "$TARGET"
say "Installed $APP_NAME $version. It will keep itself up to date."
