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
