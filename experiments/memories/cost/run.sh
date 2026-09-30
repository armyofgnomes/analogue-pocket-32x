#!/usr/bin/env bash
# Compile ss_cost with and without the save-state bus and print ALMs (Cyclone V 5CEBA4F23C8).
set -euo pipefail
Q=${QUARTUS_BIN:-$HOME/altera_lite/25.1std/quartus/bin}
cd "$(dirname "$0")"
for ss in 0 1 2; do
    d=build_ss$ss; rm -rf $d; mkdir -p $d; cd $d
    cat > top.sv <<SV
module top(input clk, en, input [31:0] din, input [5:0] sel, output [31:0] dout,
           input [9:0] ss_addr, input [31:0] ss_din, input ss_wr, output [31:0] ss_dout);
    ss_cost #(.N_WORDS(64), .SS($ss)) u(.*);
endmodule
SV
    cat > p.tcl <<TCL
project_new p -overwrite
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CEBA4F23C8
set_global_assignment -name TOP_LEVEL_ENTITY top
set_global_assignment -name SYSTEMVERILOG_FILE ../ss_cost.sv
set_global_assignment -name SYSTEMVERILOG_FILE top.sv
set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"
set_instance_assignment -name VIRTUAL_PIN ON -to *
project_close
TCL
    "$Q/quartus_sh" -t p.tcl >/dev/null
    "$Q/quartus_map" p >/dev/null && "$Q/quartus_fit" p >/dev/null
    echo "SS=$ss: $(grep -E 'Logic utilization' p.fit.summary | sed 's/  */ /g')  $(grep -E 'Total registers' p.fit.summary | sed 's/  */ /g')"
    cd ..
done
