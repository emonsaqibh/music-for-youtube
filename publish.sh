#!/bin/bash
# Publishes a release made by ./release.sh:
#
#   ./publish.sh 0.2.0-beta.2 notes.md
#
# - tags the current commit v<version> in this (private) repo and pushes it,
# - creates a pre-release here with the zip (the source of record),
# - creates the public release in the releases repo, marked Latest — that is what
#   install.sh and the in-app updater fetch — and syncs install.sh + README there.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./publish.sh <version> <notes.md>}"
NOTES="${2:?usage: ./publish.sh <version> <notes.md>}"
TAG="v$VERSION"
PUBLIC="emonsaqibh/music-for-youtube-releases"
APP="releases/$VERSION/Music for YouTube.app"
ASSET="Music-for-YouTube.zip"

[ -d "$APP" ] || { echo "no $APP — run ./release.sh $VERSION first" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first — the tag must match the release" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto -c -k --keepParent "$APP" "$STAGE/$ASSET"

echo "==> tagging $TAG"
git tag -a "$TAG" -m "$VERSION"
git push -q origin HEAD "$TAG"

echo "==> private release"
gh release create "$TAG" "$STAGE/$ASSET" --verify-tag --prerelease --title "$VERSION" --notes-file "$NOTES"

echo "==> syncing installer to $PUBLIC"
git clone -q "https://github.com/$PUBLIC.git" "$STAGE/public"
cp install.sh "$STAGE/public/install.sh"
cp distribution/README.md "$STAGE/public/README.md"
if [ -n "$(git -C "$STAGE/public" status --porcelain)" ]; then
    git -C "$STAGE/public" add -A
    git -C "$STAGE/public" commit -qm "Installer and README for $VERSION"
    git -C "$STAGE/public" push -q
fi

echo "==> public release"
gh release create "$TAG" "$STAGE/$ASSET" --repo "$PUBLIC" --target main --latest \
    --title "Music for YouTube $VERSION" --notes-file "$NOTES"
echo "==> published $VERSION"
