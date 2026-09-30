//
// Core PLL (REQ-CLK-01, REQ-ARCH-06). One reconfigurable fractional PLL fed by clk_74a, so the
// outputs are phase-related to each other (but asynchronous to the bridge clocks):
//
//   outclk_0  clk_sys     53.693180 MHz  Genesis MCLK (NTSC)
//   outclk_1  clk_ram    107.386360 MHz  SDRAM controller, 2x MCLK
//   outclk_2  clk_vid     26.846590 MHz  video to the Pocket scaler, MCLK/2
//   outclk_3  clk_vid_90  26.846590 MHz  same, +90 degrees
//
// VCO 644.318 MHz = 74.25 MHz x (8 + K/2^32), K = 2910637732; dividers 12, 6, 24, 24. The PAL
// MCLK (53.203424 MHz) needs only K = 2570680340 (VCO 638.441 MHz); every other setting is
// identical (both from ip-generate, see pll/README.md), so all outputs scale together and keep
// their relationships. pll/pll_core_cfg is Altera's reconfiguration controller for that, on
// clk_74a (not a clock of this PLL). This revision leaves it idle: NTSC only.
//
// H40 pixels are MCLK/8 (4 clk_vid cycles) and H32 pixels are MCLK/10 (5 clk_vid cycles), so one
// fixed video clock with video_skip covers both modes without switching clocks.
//

`timescale 1ns/10ps
module pll_core (
    input  wire refclk,         // clk_74a, also the reconfiguration controller's clock
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire locked
);

    wire    [63:0]  reconfig_to_pll;
    wire    [63:0]  reconfig_from_pll;

pll_core_reconf pll (
    .refclk             ( refclk ),
    .rst                ( rst ),
    .outclk_0           ( outclk_0 ),
    .outclk_1           ( outclk_1 ),
    .outclk_2           ( outclk_2 ),
    .outclk_3           ( outclk_3 ),
    .locked             ( locked ),
    .reconfig_to_pll    ( reconfig_to_pll ),
    .reconfig_from_pll  ( reconfig_from_pll )
);

// Power-on reset for the controller (clk_74a domain)
    reg     [3:0]   cfg_por = 4'hF;
always @(posedge refclk) if (cfg_por != 0) cfg_por <= cfg_por - 1'd1;

pll_core_cfg cfg (
    .mgmt_clk           ( refclk ),
    .mgmt_reset         ( cfg_por != 0 ),
    .mgmt_waitrequest   ( ),
    .mgmt_read          ( 1'b0 ),
    .mgmt_write         ( 1'b0 ),
    .mgmt_readdata      ( ),
    .mgmt_address       ( 6'd0 ),
    .mgmt_writedata     ( 32'd0 ),
    .reconfig_to_pll    ( reconfig_to_pll ),
    .reconfig_from_pll  ( reconfig_from_pll )
);

endmodule
