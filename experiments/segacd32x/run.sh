#!/usr/bin/env bash
# Fit experiment for Sega CD 32X support: compile MiSTer MegaCD's Sega CD block (MCD) alone for
# the Pocket's FPGA (5CEBA4F23C8) with our core's area-first settings, and print its ALMs, block
# RAM and timing. MegaCD_MiSTer is fetched at a pinned commit into build/upstream (gitignored).
# Usage: experiments/segacd32x/run.sh      (~10 minutes)
set -euo pipefail
URL=https://github.com/MiSTer-devel/MegaCD_MiSTer.git
COMMIT=a3a3da81d04b22533def34f26eb9d748be9d2d0c
Q=${QUARTUS_BIN:-$HOME/altera_lite/25.1std/quartus/bin}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
src=$repo/build/upstream/MegaCD_MiSTer
if [ ! -d "$src/.git" ]; then git clone -q "$URL" "$src"; fi
git -C "$src" cat-file -e "$COMMIT^{commit}" 2>/dev/null || git -C "$src" fetch -q origin
git -C "$src" checkout -q --force "$COMMIT"
# As our patch 0001 does for S32X_MiSTer: no JTAG memory editor hub (a MiSTer debug aid)
sed -i 's/ENABLE_RUNTIME_MOD=YES/ENABLE_RUNTIME_MOD=NO/' "$src/rtl/bram.vhd"

out=$repo/build/fit/segacd32x
rm -rf "$out"; mkdir -p "$out"; cd "$out"
cat > mcd_fit.sdc <<'SDC'
create_clock -name clk -period 18.624 [get_ports clk]
derive_clock_uncertainty
SDC
cat > p.tcl <<TCL
project_new mcd_fit -overwrite
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CEBA4F23C8
set_global_assignment -name TOP_LEVEL_ENTITY mcd_fit_top
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"
set_global_assignment -name OPTIMIZATION_TECHNIQUE AREA
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF
set_global_assignment -name SEED 1
set_global_assignment -name SDC_FILE mcd_fit.sdc
set_global_assignment -name SYSTEMVERILOG_FILE $here/mcd_fit_top.sv
set_global_assignment -name QIP_FILE $src/rtl/MCD/MCD.qip
set_global_assignment -name QIP_FILE $src/rtl/FX68K/fx68k.qip
set_global_assignment -name VHDL_FILE $src/rtl/bram.vhd
set_global_assignment -name VHDL_FILE $src/rtl/mlab.vhd
set_global_assignment -name VHDL_FILE $src/rtl/CEGen.vhd
set_global_assignment -name SYSTEMVERILOG_FILE $src/rtl/cheatcodes.sv
set_instance_assignment -name VIRTUAL_PIN ON -to *
project_close
TCL
"$Q/quartus_sh" -t p.tcl >/dev/null
"$Q/quartus_map" mcd_fit >/dev/null
f=output_files/mcd_fit
grep -E "Estimate of Logic utilization|Total registers|Total block memory bits|Total DSP" $f.map.rpt | sed 's/  */ /g'
# The fit is expected to fail: the block's RAM doesn't fit the device on its own.
if "$Q/quartus_fit" mcd_fit >/dev/null; then echo "fit: succeeded"
else echo "fit: failed: $(grep -m1 -E 'Error \(' $f.fit.rpt | sed 's/Error ([0-9]*): //')"; fi
