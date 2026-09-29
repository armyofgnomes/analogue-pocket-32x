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
 -group { ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk }

# From upstream S32X.sdc: SDRAM read data into the 32X interface is used a cycle later.
set_multicycle_path -from {ic|system|sdram|*} -to {ic|system|S32X|s32x_if|*} -start -setup 2
set_multicycle_path -from {ic|system|sdram|*} -to {ic|system|S32X|s32x_if|*} -start -hold 1

# fb_sram samples its clk_sys-domain requests only on the clk_ram edge in the middle of the
# clk_sys cycle (it detects that edge itself, see fb_sram.sv). The clk_ram edge that coincides
# with the launching clk_sys edge never loads these registers, so the hold check moves one
# clk_ram cycle earlier. Setup keeps the default (capture at the mid edge, half a clk_sys cycle).
set fb_sram_req_regs {ic|system|fb_sram|ch_* ic|system|fb_sram|fs_r ic|system|fb_sram|wr_pend* ic|system|fb_sram|rd_pend*}
set_multicycle_path -from [get_clocks {ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
 -to $fb_sram_req_regs -end -hold 1

# sdram.sv (patch 0007) does the same for its request inputs, on the mid edge that
# s32x_system.sv derives (ram_mid).
set sdram_req_regs {ic|system|sdram|ch_addr* ic|system|sdram|ch_din* ic|system|sdram|ch_wr* ic|system|sdram|ch_req* ic|system|sdram|ch_pend* ic|system|sdram|old_rd* ic|system|sdram|old_wr* ic|system|sdram|rd_q* ic|system|sdram|wr_q*}
set_multicycle_path -from [get_clocks {ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
 -to $sdram_req_regs -end -hold 1
