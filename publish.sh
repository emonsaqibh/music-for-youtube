#!/bin/bash
# Publishes a release made by ./release.sh:
#
#   ./publish.sh 0.2.0-beta.2 notes.md
#
# - tags the current commit v<version> and pushes it,
# - creates the GitHub release with the app zipped — a pre-release for x.y.z-suffix
#   versions, the Latest release for a stable x.y.z. The repo is public: install.sh
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

# Versions with a suffix (0.2.0-beta.5) are pre-releases; a plain x.y.z is a stable release
# and becomes the repo's Latest.
case "$VERSION" in
    *-*) KIND=(--prerelease) ;;
    *)   KIND=(--latest) ;;
esac
echo "==> release (${KIND[0]#--})"
gh release create "$TAG" "$STAGE/$ASSET" --verify-tag "${KIND[@]}" --title "$VERSION" --notes-file "$NOTES"

# The release is useless without its zip (install.sh and the updater both need it), and
# gh has returned success with the asset missing — so confirm it's really there.
# Ask the release's own assets endpoint: the asset list embedded in the release object can
# lag behind for minutes, which once made a fine release look empty.
echo "==> checking the zip is attached"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
RID="$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id)"
has_zip() { gh api "repos/$REPO/releases/$RID/assets" --jq '.[] | select(.state == "uploaded") | .name' | grep -q '\.zip$'; }
for _ in $(seq 1 12); do has_zip && break; sleep 5; done
if ! has_zip; then
    echo "==> zip missing after publishing — uploading it again"
    gh release upload "$TAG" "$STAGE/$ASSET" --clobber
    has_zip || { echo "error: $TAG still has no zip attached — fix before announcing it" >&2; exit 1; }
fi
echo "==> published $VERSION"
