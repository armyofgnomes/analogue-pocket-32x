//
// 32X framebuffer controller: both 128 KB framebuffers on the Pocket's 256 KB async SRAM
// (REQ-MEM-02). FB0 = SRAM words 0x00000-0x0FFFF, FB1 = 0x10000-0x1FFFF.
//
// The VDP side (clk_sys) is upstream S32X_VDP with USE_ASYNC_FB=1, which has no wait input, so
// every access must meet a fixed deadline (docs/architecture.md, "Framebuffer bandwidth"):
//   - display buffer: RD held high permanently, address changes at most once per dot
//     (8 MCLK in H40), data used at the next dot
//   - draw buffer: FIFO writes hold A/D/WE for 6 MCLK, SH-2 reads hold RD and sample after
//     6 MCLK, auto-fill holds WE for the whole ~7 MCLK step
//
// The state machine runs on clk_ram (2x clk_sys, same PLL). The VDP's requests change only on
// clk_sys edges, so of each pair of clk_ram edges only the one in the middle of the clk_sys cycle
// ("mid" edge) sees new values; the other coincides with the clk_sys edge and would only
// re-sample the same values under a zero-margin hold check. Requests are therefore sampled on mid
// edges only (core_constraints.sdc relaxes the hold check to match). On a mid edge the incoming
// values are compared against the registered ones and set a one-bit pending flag per channel and
// operation for anything new. The arbiter only looks at the flags (short paths at 107 MHz).
// One SRAM access at a time. With the production timing (cfg_rd = 4, cfg_we = 2, from the
// hardware sweep: the Pocket's SRAM needs more than 28 ns for reads, 37 ns works):
//   read  = address, capture cfg_rd cycles later in the I/O-cell register; the next access can
//           start on the capture edge
//   write = address setup, WE low for cfg_we cycles, one hold cycle
// Priority: an SH-2 read of the draw buffer, then the display read, then draw writes. The SH-2
// read may abort a display read in progress (async SRAM reads can simply be abandoned; it is
// re-issued after); writes never do. Worst cases: display waits for one access in progress, a
// write waits for one display read (a write burst from auto-fill must not starve the display;
// sim/vdp caught that as single wrong dots).
// The draw buffer comes from the VDP's FS bit (patch 0004 exports it as FB_FS); a heuristic based
// on RD levels failed in simulation right after a buffer swap. Measured latencies: sim/fb_sram.
//

module fb_sram
(
	input             clk_ram,
	input             reset,          // clk_ram domain, active high

	// VDP framebuffer ports (clk_sys domain)
	input      [15:0] FB0_A,
	input      [15:0] FB0_DO,         // write data from the VDP
	input       [1:0] FB0_WE,         // [1] = upper byte, [0] = lower byte
	input             FB0_RD,
	output reg [15:0] FB0_DI,         // read data to the VDP
	input      [15:0] FB1_A,
	input      [15:0] FB1_DO,
	input       [1:0] FB1_WE,
	input             FB1_RD,
	output reg [15:0] FB1_DI,
	input             FB_FS,          // 1: FB0 is the draw buffer, FB1 is displayed
	input             sys_tog,        // clk_sys-domain register that toggles every clk_sys cycle

	// Access timing in clk_ram cycles (9.3 ns). Normal builds: cfg_rd = 3, cfg_we = 2, as
	// analysed above. The MEMTEST sweep varies them to find what the Pocket's SRAM needs.
	input       [3:0] cfg_rd,         // read: capture this many cycles after the address (>= 1)
	input       [3:0] cfg_we,         // write: WE low for this many cycles (>= 1)
	input             cfg_half,       // memtest margin probe: capture half a cycle earlier
	                                  // (falling edge, fabric register). Production: 0.

	// Async SRAM pins
	output reg [16:0] sram_a,
	inout      [15:0] sram_dq,
	output reg        sram_oe_n,
	output reg        sram_we_n,
	output reg        sram_ub_n,
	output reg        sram_lb_n
);

// Requests from the clk_sys domain, registered on clk_ram. New-request events compare the
// incoming values with the registered ones, so a request's flag is set on the same edge that
// registers it. A held write (VDP FIFO: 6 MCLK, fill: whole step) is one request until its
// address, data or byte enables change; a held read is one request until its address changes.
wire [15:0] in_a [2] = '{FB0_A,  FB1_A};
wire [15:0] in_d [2] = '{FB0_DO, FB1_DO};
wire  [1:0] in_we[2] = '{FB0_WE, FB1_WE};
wire        in_rd[2] = '{FB0_RD, FB1_RD};

reg [15:0] ch_a [2];
reg [15:0] ch_d [2];
reg  [1:0] ch_we[2];
reg        ch_rd[2];
reg        fs_r;

// Mid-edge detection: sys_tog sampled on the falling clk_ram edges (a quarter clk_sys cycle
// after each clk_sys edge, and a quarter before the next: 4.65 ns margin both ways) has changed
// since the previous rising edge exactly on the mid edges.
reg tog_n, tog_p;
always @(negedge clk_ram) tog_n <= sys_tog;
always @(posedge clk_ram) tog_p <= tog_n;
wire mid = tog_n ^ tog_p;

wire wr_evt[2], rd_evt[2];
genvar c;
generate for (c = 0; c < 2; c++) begin : evt
	assign wr_evt[c] = mid && (in_we[c] != 2'b00) &&
	                   (ch_we[c] == 2'b00 || in_we[c] != ch_we[c] || in_a[c] != ch_a[c] || in_d[c] != ch_d[c]);
	assign rd_evt[c] = mid && in_rd[c] && (in_we[c] == 2'b00) &&
	                   (!ch_rd[c] || ch_we[c] != 2'b00 || in_a[c] != ch_a[c]);
end endgenerate

always @(posedge clk_ram) if (mid) begin
	for (int i = 0; i < 2; i++) begin
		ch_a[i] <= in_a[i]; ch_d[i] <= in_d[i]; ch_we[i] <= in_we[i]; ch_rd[i] <= in_rd[i];
	end
	fs_r <= FB_FS;
end

wire draw_ch = ~fs_r;

reg wr_pend[2], rd_pend[2];

localparam ST_IDLE = 3'd0;
localparam ST_RD   = 3'd1;   // waiting for read data
localparam ST_WR1  = 3'd3;   // drive data, WE low
localparam ST_WR2  = 3'd4;   // WE held low

reg  [2:0] state;
reg  [3:0] cnt;
reg        op_ch;
reg [15:0] dq_out;
reg [15:0] dq_oe;       // one enable per pin so each can sit in its I/O cell

// I/O cell registers (FAST_*_REGISTER in ap_core.qsf): the bus is sampled every cycle into rd_q,
// right at the pins. A read's data is taken from rd_q one cycle after its capture edge (xfer).
reg [15:0] rd_q;
reg        xfer;
reg        xfer_ch;
always @(posedge clk_ram) rd_q <= sram_dq;

// Margin probe (cfg_half): a falling-edge sample, taken half a cycle before the capture edge.
reg [15:0] rd_qn, rd_half;
reg        xfer_half;
always @(negedge clk_ram) rd_qn <= sram_dq;

genvar gi;
generate for (gi = 0; gi < 16; gi++) begin : dq_pins
	assign sram_dq[gi] = dq_oe[gi] ? dq_out[gi] : 1'bZ;
end endgenerate

// Arbitration from the pending flags only: SH-2 read of the draw buffer (after any write to it
// that is still pending, so it sees the new data), then the display read, then writes.
wire dc = draw_ch;
wire pc = ~draw_ch;
wire draw_rd = rd_pend[dc] && !wr_pend[dc];
wire do_rd   = draw_rd || rd_pend[pc];
wire rd_ch   = draw_rd ? dc : pc;
wire do_wr   = wr_pend[dc] || wr_pend[pc];
wire wr_ch   = wr_pend[dc] ? dc : pc;

// When a new access may start: from idle, on a read's capture edge (the data is already in rd_q
// and the address may change afterwards), or by aborting a display read for an SH-2 read.
wire rd_done  = (state == ST_RD) && (cnt == 0);
wire rd_abort = (state == ST_RD) && (cnt != 0) && (op_ch != dc) && draw_rd;
wire can_start = (state == ST_IDLE) || rd_done || rd_abort;

always @(posedge clk_ram) begin
	if (reset) begin
		state     <= ST_IDLE;
		sram_oe_n <= 1;
		sram_we_n <= 1;
		sram_ub_n <= 1;
		sram_lb_n <= 1;
		dq_oe     <= '0;
		xfer      <= 0;
		for (int i = 0; i < 2; i++) begin
			wr_pend[i] <= 0;
			rd_pend[i] <= 0;
		end
	end
	else begin
		// Deliver the previous read: rd_q holds the bus as sampled at its capture edge.
		xfer <= 0;
		if (xfer) begin
			if (xfer_ch) FB1_DI <= xfer_half ? rd_half : rd_q;
			else         FB0_DI <= xfer_half ? rd_half : rd_q;
		end

		// New requests set their flag; a withdrawn strobe clears it. Issuing an access clears the
		// flag of the request issued, unless a newer request arrives on the same edge.
		for (int i = 0; i < 2; i++) begin
			if (wr_evt[i]) wr_pend[i] <= 1;
			if (rd_evt[i]) rd_pend[i] <= 1;
			if (mid && in_we[i] == 2'b00) wr_pend[i] <= 0;
			if (mid && (!in_rd[i] || in_we[i] != 2'b00)) rd_pend[i] <= 0;
		end

		// Finishing or abandoning a read
		if (rd_done) begin
			xfer      <= 1;
			xfer_ch   <= op_ch;
			xfer_half <= cfg_half;
			rd_half   <= rd_qn;                   // sampled half a cycle before this edge
		end
		if (rd_abort && !rd_evt[op_ch] && ch_rd[op_ch] && ch_we[op_ch] == 2'b00)
			rd_pend[op_ch] <= 1;                  // re-issue the abandoned display read later

		if (state == ST_RD && !rd_done && !rd_abort) cnt <= cnt - 1'd1;

		if (can_start && do_rd) begin
			op_ch     <= rd_ch;
			sram_a    <= {rd_ch, ch_a[rd_ch]};
			sram_ub_n <= 0;
			sram_lb_n <= 0;
			sram_oe_n <= 0;
			sram_we_n <= 1;
			dq_oe     <= '0;
			if (!rd_evt[rd_ch]) rd_pend[rd_ch] <= 0;
			cnt       <= cfg_rd - 1'd1;
			state     <= ST_RD;
		end
		else if (can_start && do_wr) begin
			op_ch       <= wr_ch;
			sram_a      <= {wr_ch, ch_a[wr_ch]};
			dq_out      <= ch_d[wr_ch];
			sram_ub_n   <= ~ch_we[wr_ch][1];
			sram_lb_n   <= ~ch_we[wr_ch][0];
			sram_oe_n   <= 1;
			sram_we_n   <= 1;
			dq_oe       <= '0;
			if (!wr_evt[wr_ch]) wr_pend[wr_ch] <= 0;
			state       <= ST_WR1;
		end
		else case (state)
			ST_IDLE: begin
				sram_we_n <= 1;
				dq_oe     <= '0;
			end
			ST_RD: if (rd_done || rd_abort) state <= ST_IDLE;

			// Write: setup cycle with OE high and DQ still released (bus turnaround),
			// then WE low for cfg_we cycles with data driven, then a hold cycle (in ST_IDLE).
			ST_WR1: begin
				dq_oe     <= '1;
				sram_we_n <= 0;
				cnt       <= cfg_we - 1'd1;
				state     <= ST_WR2;
			end
			ST_WR2: begin
				if (cnt != 0) cnt <= cnt - 1'd1;
				else begin
					sram_we_n <= 1;
					// A channel that reads what it just wrote must re-read.
					if (ch_rd[op_ch] && ch_we[op_ch] == 2'b00) rd_pend[op_ch] <= 1;
					state <= ST_IDLE;
				end
			end
		endcase
	end
end

endmodule
