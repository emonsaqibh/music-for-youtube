#!/bin/bash
# Freezes the current source as a versioned beta and installs it.
#
#   ./release.sh 0.1.0-beta.1
#
# Produces releases/<version>/ with the built app and a snapshot of the source it was
# built from, then copies the app to /Applications. A release is never rebuilt or
# overwritten — later code changes only ever reach the dev build.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>   e.g. 0.1.0-beta.1}"
DEST="releases/$VERSION"
APP_NAME="Music for YouTube"
[ -e "$DEST" ] && { echo "$DEST already exists — releases are immutable, pick a new version" >&2; exit 1; }

mkdir -p "$DEST"
# Build outside $DEST first so a failed build leaves no half-made release behind.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
FLAVOR=beta VERSION="$VERSION" OUT_DIR="$STAGE" ./build.sh

echo "==> archiving source"
tar -czf "$DEST/source.tar.gz" --exclude .build --exclude build --exclude releases \
    --exclude .DS_Store .
mv "$STAGE/$APP_NAME.app" "$DEST/"

INSTALLED="/Applications/$APP_NAME.app"
if pgrep -f "$INSTALLED/Contents/MacOS/YouTubeMusic" >/dev/null; then
    echo "==> $INSTALLED is running — quit it, then: ditto \"$DEST/$APP_NAME.app\" \"$INSTALLED\""
else
    echo "==> installing to $INSTALLED"
    rm -rf "$INSTALLED"
    ditto "$DEST/$APP_NAME.app" "$INSTALLED"
fi
echo "==> released $VERSION → $DEST"
