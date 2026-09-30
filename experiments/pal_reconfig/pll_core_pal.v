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
// clk_74a (not a clock of this PLL).
//
// NTSC/PAL switch (REQ-ARCH-06): when `pal` differs from the current setting, `busy` goes high
// (the console must be held in reset from then on), and after a short wait the controller writes
// MODE = 0 (waitrequest mode), the fractional division register (DSM, 7) and START (2). START is
// held off by waitrequest until the PLL has relocked; `busy` then stays high for another ~1.8 ms.
//
// H40 pixels are MCLK/8 (4 clk_vid cycles) and H32 pixels are MCLK/10 (5 clk_vid cycles), so one
// fixed video clock with video_skip covers both modes without switching clocks.
//

`timescale 1ns/10ps
module pll_core (
    input  wire refclk,         // clk_74a, also the reconfiguration controller's clock
    input  wire rst,
    input  wire pal,            // wanted MCLK: 1 = PAL, 0 = NTSC (any clock domain, quasi-static)
    output wire busy,           // clk_74a: reconfiguring, hold the console in reset
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

    localparam [31:0] K_NTSC = 32'd2910637732;
    localparam [31:0] K_PAL  = 32'd2570680340;

    reg     [1:0]   pal_s = 0;
    reg     [1:0]   locked_s = 0;
    reg             cur_pal = 0;        // what the PLL is set to (power-up: NTSC)
    reg     [2:0]   st = 0;
    reg     [16:0]  wait_cnt = 0;
    reg             mgmt_write = 0;
    reg     [5:0]   mgmt_address = 0;
    reg     [31:0]  mgmt_writedata = 0;
    wire            mgmt_waitrequest;

    localparam ST_IDLE = 3'd0, ST_HOLD = 3'd1, ST_MODE = 3'd2, ST_DSM = 3'd3, ST_START = 3'd4,
               ST_SETTLE = 3'd5;

assign busy = st != ST_IDLE;

always @(posedge refclk) begin
    pal_s    <= {pal_s[0], pal};
    locked_s <= {locked_s[0], locked};
    if (cfg_por != 0) begin
        st <= ST_IDLE;
        mgmt_write <= 0;
    end else case (st)
    ST_IDLE:
        if (pal_s[1] != cur_pal) begin
            cur_pal  <= pal_s[1];
            wait_cnt <= 17'd1024;           // let the console see busy (reset) first
            st       <= ST_HOLD;
        end
    ST_HOLD:
        if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'd1;
        else begin
            mgmt_write     <= 1;
            mgmt_address   <= 6'd0;         // MODE: waitrequest mode
            mgmt_writedata <= 32'd0;
            st             <= ST_MODE;
        end
    ST_MODE:                                // a write completes when waitrequest is low
        if (!mgmt_waitrequest) begin
            mgmt_address   <= 6'd7;         // DSM: fractional division
            mgmt_writedata <= cur_pal ? K_PAL : K_NTSC;
            st             <= ST_DSM;
        end
    ST_DSM:
        if (!mgmt_waitrequest) begin
            mgmt_address   <= 6'd2;         // START
            mgmt_writedata <= 32'd0;
            st             <= ST_START;
        end
    ST_START:                               // held off until the PLL has relocked
        if (!mgmt_waitrequest) begin
            mgmt_write <= 0;
            wait_cnt   <= 17'h1FFFF;
            st         <= ST_SETTLE;
        end
    ST_SETTLE:
        if (!locked_s[1]) wait_cnt <= 17'h1FFFF;
        else if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'd1;
        else st <= ST_IDLE;                 // a change of `pal` meanwhile starts over from IDLE
    default: st <= ST_IDLE;
    endcase
end

pll_core_cfg cfg (
    .mgmt_clk           ( refclk ),
    .mgmt_reset         ( cfg_por != 0 ),
    .mgmt_waitrequest   ( mgmt_waitrequest ),
    .mgmt_read          ( 1'b0 ),
    .mgmt_write         ( mgmt_write ),
    .mgmt_readdata      ( ),
    .mgmt_address       ( mgmt_address ),
    .mgmt_writedata     ( mgmt_writedata ),
    .reconfig_to_pll    ( reconfig_to_pll ),
    .reconfig_from_pll  ( reconfig_from_pll )
);

endmodule
