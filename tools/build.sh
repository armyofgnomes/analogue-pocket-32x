#!/usr/bin/env bash
# Full build: prepare upstream, BIOS init files, build ID, Quartus compile, bit-reverse, package.
# Usage: tools/build.sh [--memtest]
#   --memtest   memory self-test build (REQ-MEM-06): bars overlaid on the Genesis picture
# Equivalent to opening ap_core.qpf and compiling, plus tools/reverse_bits.py and package.py.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
QUARTUS_BIN=${QUARTUS_BIN:-$HOME/altera_lite/25.1std/quartus/bin}
macros=()
for arg in "$@"; do
    case $arg in
        --memtest) macros+=(--verilog_macro=MEMTEST=1) ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

cd "$repo/src/fpga"
"$repo/tools/prepare_upstream.sh"
python3 "$repo/tools/gen_bios_mif.py" --optional
"$QUARTUS_BIN/quartus_sh" -t apf/build_id_gen.tcl >/dev/null
"$QUARTUS_BIN/quartus_map" ap_core ${macros[@]+"${macros[@]}"}
"$QUARTUS_BIN/quartus_fit" ap_core
"$QUARTUS_BIN/quartus_asm" ap_core
"$QUARTUS_BIN/quartus_sta" ap_core
grep -E "Logic utilization|Total RAM Blocks|Total DSP" output_files/ap_core.fit.summary
python3 "$repo/tools/reverse_bits.py"
python3 "$repo/tools/package.py" --zip
