#!/usr/bin/env bash
# Publish a GitHub release with the Linux, Windows and Android packages.
#
#   tools/publish_release.sh            build, tag vX.Y.Z and publish
#   tools/publish_release.sh --dry-run  build and package only; publish nothing
#
# The version comes from config/version in game/project.godot: bump it there
# (and file_version/product_version, and Android's version/name and
# version/code, in game/export_presets.cfg) for each release. The release is built from the current commit, so the working tree
# must be clean and the commit must already be on origin/main.
# Requires the GitHub CLI (gh) and everything tools/build_release.sh needs.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

VERSION="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' game/project.godot)"
[ -n "$VERSION" ] || { echo "No config/version in game/project.godot" >&2; exit 1; }
TAG="v$VERSION"
SLUG="$(git remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
ASSETS=(build/airflight-linux.tar.gz build/airflight-windows.zip build/airflight-android.apk)

# gh's own login may not be allowed to write to the organisation's repository
# (it can read it, and then fails to create the release with a misleading
# "workflow scope may be required"); fall back to the credential that git
# pushes with.
if [ -z "${GH_TOKEN:-}" ] && [ "$(gh api "repos/$SLUG" --jq .permissions.push 2>/dev/null)" != "true" ]; then
	GH_TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')"
	export GH_TOKEN
fi
gh release list --repo "$SLUG" --limit 1 >/dev/null || { echo "Cannot reach releases of $SLUG" >&2; exit 1; }

if [ "$DRY_RUN" = 0 ]; then
	[ -z "$(git status --porcelain)" ] || { echo "Working tree has uncommitted changes; commit them first." >&2; exit 1; }
	git fetch --quiet origin main
	git merge-base --is-ancestor HEAD origin/main || { echo "HEAD is not on origin/main; push it first." >&2; exit 1; }
	if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1; then
		echo "$TAG already exists; bump config/version in game/project.godot." >&2; exit 1
	fi
fi

tools/build_release.sh

if [ "$DRY_RUN" = 1 ]; then
	echo "Dry run: would publish $TAG to $SLUG with: ${ASSETS[*]}"
	exit 0
fi
git tag -a "$TAG" -m "Airflight $VERSION"
git push origin "$TAG"
gh release create "$TAG" "${ASSETS[@]}" --repo "$SLUG" --verify-tag --latest \
	--title "Airflight $VERSION" --generate-notes
gh release view "$TAG" --repo "$SLUG" --json url,assets --jq '.url, (.assets[] | "  \(.name)  \(.size) bytes")'
