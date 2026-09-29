#!/usr/bin/env bash
# Sim-only copy of upstream sdram.sv with the late declarations (mode, MODE_*, reset) hoisted
# above their first use, and the procedurally driven inout SDRAM_DQ routed through a register.
# Quartus accepts both idioms; Questa does not. Behavior is unchanged.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$repo/build/sim/sdram_hoisted.sv
mkdir -p "$(dirname "$out")"
python3 - "$repo/src/fpga/core/rtl/S32X_MiSTer/rtl/sdram.sv" "$out" <<'PY'
import re, sys
src, out = sys.argv[1], sys.argv[2]
lines = open(src, newline='').read().replace('\r\n', '\n').split('\n')
pat = re.compile(r'^\s*(localparam MODE_(NORMAL|RESET|LDM|PRE)\b|reg \[1:0\] mode;|reg \[4:0\] reset=)')
hoist = [l for l in lines if pat.match(l)]
rest = [l for l in lines if not pat.match(l)]
end_ports = rest.index(');')          # end of the module port list
body = rest[:end_ports + 1] + hoist + ['reg [15:0] SDRAM_DQ_r = 16\'hZZZZ;', 'assign SDRAM_DQ = SDRAM_DQ_r;'] + rest[end_ports + 1:]
text = '\n'.join(body)
# Questa rejects procedural assignment to an inout: drive it through SDRAM_DQ_r instead.
text = text.replace('inout  reg [15:0] SDRAM_DQ,', 'inout      [15:0] SDRAM_DQ,')
text = re.sub(r'(^|[^\w])SDRAM_DQ(\s*<=)', r'\1SDRAM_DQ_r\2', text, flags=re.M)
text = text.replace('{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_DQ} <=', '{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_DQ_r} <=')
# FPGA registers power up as 0; give the uninitialized state register that value in simulation.
text = re.sub(r'^(\s*reg\s+\[[23]:0\]\s+state)\s*;', r'\1 = 0;', text, flags=re.M)
open(out, 'w').write(text)
print(f"hoisted {len(hoist)} declarations into {out}")
PY
