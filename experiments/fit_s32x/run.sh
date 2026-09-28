#!/usr/bin/env bash
# REQ-ARCH-03 fit experiment: fetch S32X_MiSTer at a pinned commit into build/upstream
# (gitignored; it ships BIOS .mif files that must never be committed), then compile.
# Usage: experiments/fit_s32x/run.sh [--synth-only]
set -euo pipefail

UPSTREAM_URL=https://github.com/MiSTer-devel/S32X_MiSTer.git
UPSTREAM_COMMIT=b438679e897eecca6926fff22083d6f86a8265a3
QUARTUS_BIN=${QUARTUS_BIN:-$HOME/altera_lite/25.1std/quartus/bin}

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
src=$repo/build/upstream/S32X_MiSTer

if [ ! -d "$src/.git" ]; then
    git clone -q "$UPSTREAM_URL" "$src"
fi
git -C "$src" fetch -q origin "$UPSTREAM_COMMIT" 2>/dev/null || true
git -C "$src" checkout -q "$UPSTREAM_COMMIT"

cd "$here"
if [ "${1:-}" = "--synth-only" ]; then
    "$QUARTUS_BIN/quartus_map" s32x_fit
else
    "$QUARTUS_BIN/quartus_sh" --flow compile s32x_fit
fi
