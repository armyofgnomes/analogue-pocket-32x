#!/usr/bin/env bash
# Print a fingerprint (git tree ID) of the sources that go into the bitstream and the SD package:
# src/, dist/ and the APF JSON/info files, without build outputs (src/fpga/output_files,
# apf/build_id.mif) and without core.json (its version is bumped after the hardware test).
# Usage: tools/fingerprint.sh            the working tree, committed or not
#        tools/fingerprint.sh <tag|rev>  that commit
set -euo pipefail
cd "$(dirname "$0")/.."
paths=(src dist data.json interact.json video.json audio.json input.json variants.json info.txt)
idx=$(mktemp -u)
trap 'rm -f "$idx"' EXIT
export GIT_INDEX_FILE=$idx
if [ $# -eq 0 ]; then
    git -c advice.addEmbeddedRepo=false add -A -- "${paths[@]}" 2> >(grep -v "embedded git repository" >&2)
else
    git ls-tree -r --full-tree "$1" -- "${paths[@]}" | git update-index --index-info
fi
git rm -q -r -f --cached --ignore-unmatch -- src/fpga/output_files src/fpga/apf/build_id.mif
git write-tree
