#!/usr/bin/env bash
# Reset the S32X_MiSTer submodule to its pinned commit and apply our patches from
# src/fpga/core/rtl/patches/ (in name order). Idempotent; run automatically by Quartus via
# src/fpga/core/pre_flow.tcl, or by hand.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
sub=src/fpga/core/rtl/S32X_MiSTer
patches=$repo/src/fpga/core/rtl/patches

cd "$repo"
if [ ! -e "$sub/.git" ]; then
    git submodule update --init "$sub"
fi
pinned=$(git ls-files -s "$sub" | awk '{print $2}')
git -C "$sub" checkout -q --force "$pinned"
git -C "$sub" clean -fdq
for p in "$patches"/*.patch; do
    [ -e "$p" ] || continue
    git -C "$sub" apply "$p"
done
echo "S32X_MiSTer at ${pinned:0:7} with $(ls "$patches"/*.patch 2>/dev/null | wc -l) patch(es) applied"
