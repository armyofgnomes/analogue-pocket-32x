#!/usr/bin/env bash
# REQ-ARCH-03/04 fit experiment.
#
# Usage: experiments/fit_s32x/run.sh [--synth-only] [-j N] BUILD...
#   BUILD is "baseline" or one or more variant names joined with "+", e.g. "area+no_debug".
#   Each variant is a directory under variants/ holding any of:
#     settings.qsf   lines appended to the generated qsf (synthesis settings, VERILOG_MACRO)
#     *.patch        applied to that build's private copy of upstream (git apply, in name order)
#   Builds run in parallel (default 4 at a time) in build/fit/<BUILD>/, and each prints a
#   one-line result: ALMs, M10K, DSP, worst clk_sys setup/hold slack.
#
# Upstream S32X_MiSTer is fetched at a pinned commit into build/upstream (gitignored; it ships
# BIOS .mif files that must never be committed). Each build gets its own git worktree of it.
set -euo pipefail

UPSTREAM_URL=https://github.com/MiSTer-devel/S32X_MiSTer.git
UPSTREAM_COMMIT=b438679e897eecca6926fff22083d6f86a8265a3
QUARTUS_BIN=${QUARTUS_BIN:-$HOME/altera_lite/25.1std/quartus/bin}

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
src=$repo/build/upstream/S32X_MiSTer

synth_only=0
jobs=4
builds=()
while [ $# -gt 0 ]; do
    case $1 in
        --synth-only) synth_only=1 ;;
        -j) jobs=$2; shift ;;
        *) builds+=("$1") ;;
    esac
    shift
done
[ ${#builds[@]} -gt 0 ] || builds=(baseline)

if [ ! -d "$src/.git" ]; then
    git clone -q "$UPSTREAM_URL" "$src"
fi
git -C "$src" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null || git -C "$src" fetch -q origin
git -C "$src" worktree prune

# Validate every variant name before starting anything.
for b in "${builds[@]}"; do
    [ "$b" = baseline ] && continue
    for v in ${b//+/ }; do
        [ -d "$here/variants/$v" ] || { echo "unknown variant: $v" >&2; exit 2; }
    done
done

summarize() {
    local out=$1/output_files
    local alms m10k dsp setup hold
    alms=$(grep -m1 "Logic utilization" "$out/s32x_fit.fit.summary" | sed 's/.*: //')
    m10k=$(grep -m1 "Total RAM Blocks" "$out/s32x_fit.fit.summary" | sed 's/.*: //')
    dsp=$(grep -m1 "Total DSP Blocks" "$out/s32x_fit.fit.summary" | sed 's/.*: //')
    setup=$(grep -A1 "Setup 'clk_sys'" "$out/s32x_fit.sta.summary" | grep Slack | awk '{print $3}' | sort -g | head -1)
    hold=$(grep -A1 "Hold 'clk_sys'" "$out/s32x_fit.sta.summary" | grep Slack | awk '{print $3}' | sort -g | head -1)
    echo "ALMs $alms | M10K $m10k | DSP $dsp | setup $setup ns | hold $hold ns"
}

build_one() {
    local b=$1
    local dir=$repo/build/fit/$b
    local up=$dir/upstream
    if [ -d "$up" ]; then git -C "$src" worktree remove --force "$up"; fi
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$src" worktree add -q --detach "$up" "$UPSTREAM_COMMIT"

    sed -e "s#@UPSTREAM@#$up#g" -e "s#@HERE@#$here#g" "$here/s32x_fit.qsf.in" > "$dir/s32x_fit.qsf"
    cp "$here/s32x_fit.qpf" "$dir/"
    if [ "$b" != baseline ]; then
        for v in ${b//+/ }; do
            local vd=$here/variants/$v
            if [ -f "$vd/settings.qsf" ]; then
                { echo; echo "# variant: $v"; cat "$vd/settings.qsf"; } >> "$dir/s32x_fit.qsf"
            fi
            for p in "$vd"/*.patch; do
                [ -e "$p" ] || continue
                git -C "$up" apply "$p"
            done
        done
    fi

    cd "$dir"
    local rc=0
    if [ $synth_only = 1 ]; then
        "$QUARTUS_BIN/quartus_map" s32x_fit > compile.log 2>&1 || rc=$?
    else
        "$QUARTUS_BIN/quartus_sh" --flow compile s32x_fit > compile.log 2>&1 || rc=$?
    fi
    if [ $rc != 0 ]; then
        echo "$b: FAILED (see build/fit/$b/compile.log)"
    elif [ $synth_only = 1 ]; then
        echo "$b: synthesis OK, registers $(grep -m1 'Total registers' output_files/s32x_fit.map.summary | sed 's/.*: //')"
    else
        echo "$b: $(summarize "$dir")" | tee summary.txt
    fi
}

running=0
for b in "${builds[@]}"; do
    build_one "$b" &
    running=$((running + 1))
    if [ $running -ge "$jobs" ]; then
        wait -n || true
        running=$((running - 1))
    fi
done
wait
