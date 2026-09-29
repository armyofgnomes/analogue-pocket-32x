#!/usr/bin/env bash
# Full-system simulation (Questa FSE). Usage: sim/system/run.sh +rom=<file> [+frames=N] [+trace]
# Mixed Verilog/VHDL; source list generated from ap_core.qsf by gen_files.py.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
Q=${QUESTA_BIN:-$HOME/altera_lite/25.1std/questa_fse/bin}
export SALT_LICENSE_SERVER=${SALT_LICENSE_SERVER:-$HOME/.altera.quartus/questa_lic.dat}
INTEL=$Q/../intel

"$repo/tools/prepare_upstream.sh" >/dev/null
python3 "$repo/tools/gen_bios_mif.py" >/dev/null
"$repo/sim/sdram/prep.sh" >/dev/null

work=$repo/build/sim/system
mkdir -p "$work"
cd "$work"
if [ "${SKIP_COMPILE:-0}" != 1 ]; then
    rm -rf work
    "$Q/vlib" work >/dev/null
    "$Q/vmap" altera_mf "$INTEL/vhdl/altera_mf" >/dev/null
    list=$(python3 "$repo/sim/system/gen_files.py")
    # VHDL in one call with -autoorder: Quartus accepts use-before-definition (e.g. bram.vhd,
    # T80_Pack listed last); Questa sorts the design units by dependency.
    vhd=$(echo "$list" | awk '$1=="vcom"{print "'"$repo"'/"$2}')
    "$Q/vcom" -quiet -2008 -autoorder $vhd
    vl=$(echo "$list" | awk '$1=="vlog"{print "'"$repo"'/"$2}')
    "$Q/vlog" -sv -quiet -suppress 2244,2388 -L altera_mf_ver $vl \
        "$repo/sim/common/sdram_model.sv" "$repo/sim/system/tb_system.sv"
fi
# Init files: the BIOS ROMs use core/bios_mif/*.mif (relative to the Quartus project dir), fx68k
# reads microrom.mem / nanorom.mem from the working directory.
mkdir -p core
ln -sfn "$repo/src/fpga/core/bios_mif" core/bios_mif
cp -f "$repo"/src/fpga/core/rtl/S32X_MiSTer/rtl/FX68K/*.mem .
"$Q/vsim" -c -quiet -suppress 7063,7061,10000 -L "$INTEL/verilog/altera_mf" -L altera_mf tb_system "$@" -do "run -all; quit -f"
