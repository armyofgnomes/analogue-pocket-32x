# Quartus pre-flow hook (PRE_FLOW_SCRIPT_FILE). Runs from src/fpga.
# 1. Reset the S32X_MiSTer submodule and apply our patches.
# 2. Run the APF build-ID generator (unchanged vendor script).
if {[catch {exec bash ../../tools/prepare_upstream.sh} msg]} {
    post_message -type error "prepare_upstream.sh failed: $msg"
    error $msg
}
post_message $msg
source apf/build_id_gen.tcl
