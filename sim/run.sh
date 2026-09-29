#!/usr/bin/env bash
# Run a Questa (Intel FPGA Starter Edition) testbench.
# Usage: [VLOG_DEFS=+define+X=1] sim/run.sh <bench>     e.g. sim/run.sh fb_sram
# Each bench is sim/<bench>/ with a files.f (paths relative to the repo root) and tb_<bench>.sv.
# Needs the free Questa license: SALT_LICENSE_SERVER defaults to ~/.altera.quartus/questa_lic.dat.
set -euo pipefail

bench=${1:?usage: sim/run.sh <bench>}
repo=$(cd "$(dirname "$0")/.." && pwd)
QUESTA_BIN=${QUESTA_BIN:-$HOME/altera_lite/25.1std/questa_fse/bin}
export SALT_LICENSE_SERVER=${SALT_LICENSE_SERVER:-$HOME/.altera.quartus/questa_lic.dat}

work=$repo/build/sim/$bench
mkdir -p "$work"
cd "$work"
rm -rf work
"$QUESTA_BIN/vlib" work >/dev/null
files=$(sed -e 's/#.*//' -e '/^\s*$/d' "$repo/sim/$bench/files.f" | sed "s#^#$repo/#")
"$QUESTA_BIN/vlog" -sv -quiet ${VLOG_DEFS:-} $files "$repo/sim/$bench/tb_$bench.sv"
"$QUESTA_BIN/vsim" -c -quiet ${VSIM_ARGS:-} "tb_$bench" -do "run -all; quit -f" | tee sim.log | grep -vE "^# (Loading|//)"
grep -q "^# PASS" sim.log
