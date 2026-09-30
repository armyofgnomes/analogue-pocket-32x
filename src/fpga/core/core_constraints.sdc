#
# user core constraints
#
# pll_core outputs (clk_sys, clk_ram, clk_vid, clk_vid_90) come from one PLL and are related:
# the SDRAM controller (clk_ram) samples clk_sys-domain requests directly, and the video
# formatter (clk_vid) samples clk_sys-domain pixels directly, as in upstream S32X_MiSTer. They
# are only asynchronous to the bridge/APF clocks.
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk \
          ic|mp1|pll|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk \
          ic|mp1|pll|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk \
          ic|mp1|pll|altera_pll_i|cyclonev_pll|counter[3].output_counter|divclk }

# From upstream S32X.sdc: SDRAM read data into the 32X interface is used a cycle later.
set_multicycle_path -from {ic|system|sdram|*} -to {ic|system|S32X|s32x_if|*} -start -setup 2
set_multicycle_path -from {ic|system|sdram|*} -to {ic|system|S32X|s32x_if|*} -start -hold 1

# fb_sram samples its clk_sys-domain requests only on the clk_ram edge in the middle of the
# clk_sys cycle (it detects that edge itself, see fb_sram.sv). The clk_ram edge that coincides
# with the launching clk_sys edge never loads these registers, so the hold check moves one
# clk_ram cycle earlier. Setup keeps the default (capture at the mid edge, half a clk_sys cycle).
set fb_sram_req_regs {ic|system|fb_sram|ch_* ic|system|fb_sram|fs_r ic|system|fb_sram|wr_pend* ic|system|fb_sram|rd_pend*}
set_multicycle_path -from [get_clocks {ic|mp1|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
 -to $fb_sram_req_regs -end -hold 1

# sdram.sv (patch 0007) does the same for its request inputs, on the mid edge that
# s32x_system.sv derives (ram_mid): they go straight into these input registers.
set sdram_req_regs {ic|system|sdram|a_q* ic|system|sdram|d_q* ic|system|sdram|w_q* ic|system|sdram|rd_q* ic|system|sdram|wr_q*}
set_multicycle_path -from [get_clocks {ic|mp1|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
 -to $sdram_req_regs -end -hold 1

# SDRAM line reads into the 32X front end's line buffer (clk_ram -> clk_sys). sdram.sv updates
# dout0_line on the same clk_ram edge that clears the port's busy; s32x_sdram_front.sv copies it
# into lb_data only on a clk_sys edge where it already sees busy low (strictly later), and
# dout0_line doesn't change again until the front end issues its next request. The zero-cycle
# hold check (launch and capture on coincident edges) can't happen; setup is still checked.
set_false_path -hold -from [get_registers {*|sdram:sdram|dout0_line[*]}] \
                     -to   [get_registers {*|s32x_sdram_front:s32x_sdram_front|lb_data[*][*]}]

# --- Pin timing (REQ-CLK-03) ---------------------------------------------------------------------
# These ports are timed by design rather than by input/output delay constraints, which would need
# the external chips' and the board's timing (not available). Declared explicitly so the timing
# report has no unconstrained paths, with the reason for each group:
# - SDRAM and framebuffer SRAM: every pin register sits in its I/O cell (FAST_*_REGISTER in the
#   QSF, enforced by tools/check_io_regs.py in tools/build.sh), so clock-to-pin delays are fixed.
#   The SDRAM clock runs at 180 degrees (sdram.sv's DDIO output) with command-to-capture cycles
#   as openFPGA-Genesis uses on the same Pocket SDRAM; the SRAM access lengths (37 ns read,
#   19 ns write) have margin measured on hardware by the memtest sweeps (docs/architecture.md §4).
# - APF bridge: Analogue's SPI link to the host, sampled by the framework's own logic
#   (apf/io_bridge_peripheral.v); Analogue's constraints don't time these pins either.
# - Video to the scaler: data launched on clk_vid, the pixel clock the scaler samples with is
#   clk_vid_90 (a quarter cycle, 9.3 ns, later), as in Analogue's template.
# - Audio: I2S at 12.288 MHz MCLK / 48 kHz frames, far slower than any path delay.
set_false_path -to   [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_clk dram_dq[*]}]
set_false_path -from [get_ports {dram_dq[*]}]
set_false_path -to   [get_ports {sram_a[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n sram_dq[*]}]
set_false_path -from [get_ports {sram_dq[*]}]
set_false_path -to   [get_ports {bridge_1wire bridge_spimiso bridge_spimosi}]
set_false_path -from [get_ports {bridge_1wire bridge_spimiso bridge_spimosi bridge_spiss}]
set_false_path -to   [get_ports {scal_vid[*] scal_de scal_hs scal_vs scal_skip scal_clk}]
set_false_path -to   [get_ports {scal_auddac scal_audlrck scal_audmclk}]
