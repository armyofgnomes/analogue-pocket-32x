# Quartus pre-flow hook (PRE_FLOW_SCRIPT_FILE). Runs from src/fpga.
# 1. Reset the S32X_MiSTer submodule and apply our patches.
# 2. Run the APF build-ID generator (unchanged vendor script).
# The bitstream contains no BIOS: the core loads it from the SD card through data slots
# (REQ-APF-03b). tools/gen_bios_mif.py is only used by the simulations (BIOS_MIF).
if {[catch {exec bash ../../tools/prepare_upstream.sh} msg]} {
    post_message -type error "prepare_upstream.sh failed: $msg"
    error $msg
}
post_message $msg
source apf/build_id_gen.tcl
