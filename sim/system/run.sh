#!/usr/bin/env bash
# Full-system simulation (Questa FSE). Usage: sim/system/run.sh +rom=<file> [+frames=N] [+trace]
# Mixed Verilog/VHDL; source list generated from ap_core.qsf by gen_files.py.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
Q=${QUESTA_BIN:-$HOME/altera_lite/25.1std/questa_fse/bin}
export SALT_LICENSE_SERVER=${SALT_LICENSE_SERVER:-$HOME/.altera.quartus/questa_lic.dat}
INTEL=$Q/../intel

# Parallel runs (WORK=...): prepare_upstream.sh resets and re-patches the submodule, which breaks
# another run that is patching or compiling at the same moment. Serialize that part.
mkdir -p "$repo/build/sim"
exec 9>"$repo/build/sim/.prepare_compile.lock"
flock 9
"$repo/tools/prepare_upstream.sh" >/dev/null
python3 "$repo/tools/gen_bios_mif.py" >/dev/null
"$repo/sim/sdram/prep.sh" >/dev/null

work=${WORK:-$repo/build/sim/system}   # WORK=<dir>: a separate run directory, e.g. for a second sim in parallel
mkdir -p "$work"
cd "$work"
if [ "${SKIP_COMPILE:-0}" != 1 ]; then
    rm -rf work
    "$Q/vlib" work >/dev/null
    "$Q/vmap" altera_mf "$INTEL/vhdl/altera_mf" >/dev/null
    list=$(python3 "$repo/sim/system/gen_files.py")
    # ddram.sv is only used by the SIM_DDRAM_REF reference (MiSTer's DDR3 path for the 32X SDRAM)
    python3 "$repo/sim/common/hoist_decls.py" "$repo/src/fpga/core/rtl/S32X_MiSTer/rtl/ddram.sv" "$work/ddram_sim.sv"
    # VHDL in one call with -autoorder: Quartus accepts use-before-definition (e.g. bram.vhd,
    # T80_Pack listed last); Questa sorts the design units by dependency.
    vhd=$(echo "$list" | awk '$1=="vcom"{print "'"$repo"'/"$2}')
    "$Q/vcom" -quiet -2008 -autoorder $vhd
    vl=$(echo "$list" | awk '$1=="vlog"{print "'"$repo"'/"$2}')
    # BIOS_MIF: the BIOS memories start from core/bios_mif/*.mif (the hardware loads them from the
# SD card instead). BIOS_LOAD=1 leaves them empty and tb_system loads them through the core's
# BIOS loading port, as the Pocket does.
    bios_def="+define+BIOS_MIF"
    [ "${BIOS_LOAD:-0}" = 1 ] && bios_def=""
    "$Q/vlog" -sv -quiet -suppress 2244,2388 $bios_def ${VLOG_DEFS:-} -L altera_mf_ver $vl \
        "$work/ddram_sim.sv" "$repo/sim/common/sdram_model.sv" "$repo/sim/system/tb_system.sv"
fi
flock -u 9
# Init files: the BIOS ROMs use core/bios_mif/*.mif (relative to the Quartus project dir), fx68k
# reads microrom.mem / nanorom.mem from the working directory.
mkdir -p core
rm -rf core/bios_mif
if [ "${FAST_BIOS:-0}" = 1 ]; then
    # Sim-only shortcut: the master BIOS's SDRAM fill-and-verify test takes ~130 ms of simulated
    # time. Branch from its start (0x1C0) to the success path (0x20C, which still clears SDRAM).
    mkdir -p core/bios_mif
    cp "$repo"/src/fpga/core/bios_mif/*.mif core/bios_mif/
    # It also replaces the cartridge checksum loop (0x264-0x282, one word at a time over the whole
    # ROM: ~850 ms for 3 MB) by loading the sum computed here from the ROM file.
    rom=""
    for a in "$@"; do case $a in +rom=*) rom=${a#+rom=} ;; esac; done
    python3 - core/bios_mif/shbios.mif "$rom" <<'PY'
import re, struct, sys
p, rom = sys.argv[1], sys.argv[2]
t = open(p).read()
patch = [(0x0E0, 0xA024), (0x0E1, 0x0009)]            # byte 0x1C0: bra 0x20C; nop
if rom:
    d = open(rom, 'rb').read()
    end = struct.unpack('>I', d[0x1A4:0x1A8])[0]       # header: ROM end address
    count = (((end - 0x200) >> 1) & 0x3FFFFF) + 1      # as the BIOS computes it
    words = struct.unpack('>%dH' % count, d[0x200:0x200 + 2 * count].ljust(2 * count, b'\0'))
    csum = sum(words) & 0xFFFF
    # byte 0x264: mov.w @(0x26C),r0; 0x266: bra 0x284; 0x268/0x26A: nop; 0x26C: the sum
    patch += [(0x132, 0x9002), (0x133, 0xA00D), (0x134, 0x0009), (0x135, 0x0009), (0x136, csum)]
    print(f"FAST_BIOS: cart checksum {csum:04X} over {count} words")
for addr, val in patch:
    t, n = re.subn(r'(?m)^(\s*)%04X(\s*:\s*)[0-9A-Fa-f]+;' % addr, r'\g<1>%04X\g<2>%04X;' % (addr, val), t)
    assert n == 1, hex(addr)
open(p, 'w').write(t)
PY
else
    ln -sfn "$repo/src/fpga/core/bios_mif" core/bios_mif
fi
cp -f "$repo"/src/fpga/core/rtl/S32X_MiSTer/rtl/FX68K/*.mem .
# ACC=1 keeps full signal visibility for diagnostics (slower)
# +initreg+0: every register starts at 0, like FPGA power-up (upstream has many registers
# without a reset, e.g. the Genesis bus arbiter's refresh timers, which would stay X otherwise).
# INITREG=0 turns it off (it may also override explicit initializers such as reg x = 3'b111).
vopt=""
[ "${INITREG:-1}" = 1 ] && vopt="+initreg+0"
[ "${ACC:-0}" = 1 ] && vopt="$vopt +acc"
acc=(-voptargs="$vopt")
# CHECKPOINT_AT=<ms>: run to that time, save checkpoint.cpt, then continue.
# RESTORE=1: resume from checkpoint.cpt instead of starting at 0 (same compiled design only;
# plusargs are fixed at checkpoint time, except those read later such as +win_start/+win_end are not).
run_cmd="run -all"
[ -n "${CHECKPOINT_AT:-}" ] && run_cmd="run ${CHECKPOINT_AT}ms; checkpoint checkpoint.cpt; run -all"
if [ "${RESTORE:-0}" = 1 ]; then
    "$Q/vsim" -c -quiet -restore checkpoint.cpt -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all; quit -f"
    exit
fi
"$Q/vsim" -c -quiet ${acc[@]+"${acc[@]}"} -suppress 7063,7061,10000 -L "$INTEL/verilog/altera_mf" -L altera_mf tb_system "$@" \
    -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; $run_cmd; quit -f"
