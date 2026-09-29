# Quartus pre-flow hook (PRE_FLOW_SCRIPT_FILE). Runs from src/fpga.
# 1. Reset the S32X_MiSTer submodule and apply our patches.
# 2. Generate the 32X BIOS ROM init files from the gitignored bios/ dir. Optional while the 32X
#    block isn't instantiated (Genesis-only builds); becomes required in M4 (REQ-APF-03a).
# 3. Run the APF build-ID generator (unchanged vendor script).
if {[catch {exec bash ../../tools/prepare_upstream.sh} msg]} {
    post_message -type error "prepare_upstream.sh failed: $msg"
    error $msg
}
post_message $msg
if {[catch {exec python3 ../../tools/gen_bios_mif.py --optional} msg]} {
    post_message -type error "gen_bios_mif.py failed: $msg"
    error $msg
}
post_message $msg
source apf/build_id_gen.tcl
