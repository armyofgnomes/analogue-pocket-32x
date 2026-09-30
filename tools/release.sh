#!/usr/bin/env bash
# Publish a hardware-verified build as a GitHub release (docs/hardware-testing.md).
# Usage: tools/release.sh vX.Y.Z        (DRY_RUN=1: build the zip and notes, don't publish)
#   Needs: the annotated tag vX.Y.Z pushed, core.json at the tag saying X.Y.Z, and the bitstream
#   in output/ built by tools/build.sh from the same sources as the tag (output/build_info.txt).
#   Packages the tag's tree with that bitstream and creates the release with the SD-card zip,
#   using the tag's message plus install notes as the release notes.
set -euo pipefail

tag=${1:?usage: tools/release.sh vX.Y.Z}
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

die() { echo "error: $*" >&2; exit 1; }

[ "$(git cat-file -t "$tag" 2>/dev/null)" = tag ] || die "$tag is not an annotated tag"
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || die "$tag isn't pushed (git push origin $tag)"
ver=$(git show "$tag:core.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["core"]["metadata"]["version"])')
[ "$ver" = "${tag#v}" ] || die "core.json at $tag says $ver"

info=output/build_info.txt
[ -f "$info" ] && [ -f output/bitstream.rbf_r ] || die "no build in output/ (run tools/build.sh)"
built=$(sed -n 's/^fingerprint //p' "$info")
[ -n "$built" ] || die "$info has no fingerprint (rebuild with tools/build.sh)"
[ "$(tools/fingerprint.sh "$tag")" = "$built" ] || die "the build in output/ isn't from $tag's sources: rebuild from the tag"

work=$(mktemp -d)
trap 'git worktree remove --force "$work/tree" 2>/dev/null || true; rm -rf "$work"' EXIT
git worktree add -q "$work/tree" "$tag"
cp output/bitstream.rbf_r "$work/tree/output/"
(cd "$work/tree" && python3 tools/package.py --zip >/dev/null)
zip="build/32x-core-$tag.zip"
mkdir -p build
cp "$work/tree/build/sdcard.zip" "$zip"

{
    git tag -l --format='%(contents)' "$tag"
    cat <<'NOTES'

## Install

Unzip `32x-core-*.zip` to the root of the Pocket's SD card. Put your own 32X BIOS dumps in
`Assets/32x/common/`: `32X_G_BIOS.BIN` (68K, 256 bytes), `32X_M_BIOS.BIN` (master SH-2, 2 KB)
and `32X_S_BIOS.BIN` (slave SH-2, 1 KB). ROMs go in the same folder (`.32x`, `.md`, `.bin`, `.gen`).
NOTES
} > "$work/notes.md"

if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "dry run: $zip ready, release notes:"; cat "$work/notes.md"; exit 0
fi
gh release create "$tag" "$zip" --title "32X core ${tag#v}" --notes-file "$work/notes.md" --verify-tag
echo "released $tag with $zip"
