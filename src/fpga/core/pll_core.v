//
// Core PLL (REQ-CLK-01). All outputs come from one fractional PLL fed by clk_74a, so they are
// phase-related to each other (but treated as asynchronous to the bridge clocks).
//
//   outclk_0  clk_sys     53.693181 MHz  Genesis MCLK (NTSC)
//   outclk_1  clk_ram    107.386363 MHz  SDRAM controller, 2x MCLK
//   outclk_2  clk_vid     26.846590 MHz  video to the Pocket scaler, MCLK/2
//   outclk_3  clk_vid_90  26.846590 MHz  same, +90 degrees (9312 ps)
//
// H40 pixels are MCLK/8 (4 clk_vid cycles) and H32 pixels are MCLK/10 (5 clk_vid cycles), so one
// fixed video clock with video_skip covers both modes without switching clocks.
//

`timescale 1ns/10ps
module pll_core (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire locked
);

altera_pll #(
    .fractional_vco_multiplier("true"),
    .reference_clock_frequency("74.25 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(4),
    .output_clock_frequency0("53.693181 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("107.386363 MHz"),
    .phase_shift1("0 ps"),
    .duty_cycle1(50),
    .output_clock_frequency2("26.846590 MHz"),
    .phase_shift2("0 ps"),
    .duty_cycle2(50),
    .output_clock_frequency3("26.846590 MHz"),
    .phase_shift3("9312 ps"),
    .duty_cycle3(50),
    .pll_type("General"),
    .pll_subtype("General")
) altera_pll_i (
    .rst      ( rst ),
    .outclk   ( {outclk_3, outclk_2, outclk_1, outclk_0} ),
    .locked   ( locked ),
    .fboutclk ( ),
    .fbclk    ( 1'b0 ),
    .refclk   ( refclk )
);

endmodule
