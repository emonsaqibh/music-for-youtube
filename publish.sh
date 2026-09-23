#!/bin/bash
# Publishes a release made by ./release.sh:
#
#   ./publish.sh 0.2.0-beta.2 notes.md
#
# - tags the current commit v<version> and pushes it,
# - creates the GitHub pre-release with the app zipped. The repo is public: install.sh
#   and the in-app updater pick the newest release from here.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./publish.sh <version> <notes.md>}"
NOTES="${2:?usage: ./publish.sh <version> <notes.md>}"
TAG="v$VERSION"
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

echo "==> release"
gh release create "$TAG" "$STAGE/$ASSET" --verify-tag --prerelease --title "$VERSION" --notes-file "$NOTES"

echo "==> published $VERSION"
