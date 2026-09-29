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
// The state machine runs on clk_ram (2x clk_sys, same PLL). Requests are registered on clk_ram,
// and a change between two consecutive samples (new address/data/strobe) sets a one-bit pending
// flag per channel and operation, so the arbiter only looks at flags (short paths at 107 MHz).
// One SRAM access at a time (default timing):
//   read  = 4 clk_ram cycles (address, capture 3 cycles = 28 ns later in the I/O-cell register)
//   write = 4 clk_ram cycles (address setup, WE low x2, hold)
// Priority: draw buffer (write, then read) first, then a display read. The draw buffer comes
// from the VDP's FS bit (patch 0004 exports it as FB_FS). A heuristic based on RD levels was
// tried first and failed in simulation right after a buffer swap.
// Worst-case latency: input register + change detect + access in progress + own access +
// delivery, plus one draw access ahead of a display read. See sim/fb_sram for measured values.
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

	// Access timing in clk_ram cycles (9.3 ns). Normal builds: cfg_rd = 3, cfg_we = 2, as
	// analysed above. The MEMTEST sweep varies them to find what the Pocket's SRAM needs.
	input       [3:0] cfg_rd,         // read: capture this many cycles after the address (>= 1)
	input       [3:0] cfg_we,         // write: WE low for this many cycles (>= 1)

	// Async SRAM pins
	output reg [16:0] sram_a,
	inout      [15:0] sram_dq,
	output reg        sram_oe_n,
	output reg        sram_we_n,
	output reg        sram_ub_n,
	output reg        sram_lb_n
);

// Requests from the clk_sys domain: two stages of clk_ram registers. Stage 1 (ch_*) is a plain
// clock-domain register; stage 2 (p_*) is the previous sample, for change detection.
reg [15:0] ch_a [2], p_a [2];
reg [15:0] ch_d [2], p_d [2];
reg  [1:0] ch_we[2], p_we[2];
reg        ch_rd[2], p_rd[2];
reg        fs_r;
always @(posedge clk_ram) begin
	ch_a[0] <= FB0_A;  ch_d[0] <= FB0_DO; ch_we[0] <= FB0_WE; ch_rd[0] <= FB0_RD;
	ch_a[1] <= FB1_A;  ch_d[1] <= FB1_DO; ch_we[1] <= FB1_WE; ch_rd[1] <= FB1_RD;
	fs_r <= FB_FS;
	for (int c = 0; c < 2; c++) begin
		p_a[c] <= ch_a[c]; p_d[c] <= ch_d[c]; p_we[c] <= ch_we[c]; p_rd[c] <= ch_rd[c];
	end
end

wire draw_ch = ~fs_r;

// New-request events. A held write (VDP FIFO: 6 MCLK, fill: whole step) is one request until its
// address, data or byte enables change; a held read until its address changes.
wire wr_evt[2], rd_evt[2];
genvar c;
generate for (c = 0; c < 2; c++) begin : evt
	assign wr_evt[c] = (ch_we[c] != 2'b00) &&
	                   (p_we[c] == 2'b00 || ch_we[c] != p_we[c] || ch_a[c] != p_a[c] || ch_d[c] != p_d[c]);
	assign rd_evt[c] = ch_rd[c] && (ch_we[c] == 2'b00) &&
	                   (!p_rd[c] || p_we[c] != 2'b00 || ch_a[c] != p_a[c]);
end endgenerate

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

genvar gi;
generate for (gi = 0; gi < 16; gi++) begin : dq_pins
	assign sram_dq[gi] = dq_oe[gi] ? dq_out[gi] : 1'bZ;
end endgenerate

// Arbitration from the pending flags only: draw channel first (write, then read), then display.
wire dc = draw_ch;
wire pc = ~draw_ch;
wire do_wr   = wr_pend[dc] || (!rd_pend[dc] && wr_pend[pc]);
wire wr_ch   = wr_pend[dc] ? dc : pc;
wire do_rd   = rd_pend[dc] || rd_pend[pc];
wire rd_ch   = rd_pend[dc] ? dc : pc;

always @(posedge clk_ram) begin
	if (reset) begin
		state     <= ST_IDLE;
		sram_oe_n <= 1;
		sram_we_n <= 1;
		sram_ub_n <= 1;
		sram_lb_n <= 1;
		dq_oe     <= '0;
		xfer      <= 0;
		for (int c = 0; c < 2; c++) begin
			wr_pend[c] <= 0;
			rd_pend[c] <= 0;
		end
	end
	else begin
		// Deliver the previous read: rd_q holds the bus as sampled at its capture edge.
		xfer <= 0;
		if (xfer) begin
			if (xfer_ch) FB1_DI <= rd_q; else FB0_DI <= rd_q;
		end

		// New requests set their flag; issuing an access clears it (below, later assignment wins
		// only for the channel being issued, and a same-cycle event is the request being issued).
		for (int c = 0; c < 2; c++) begin
			if (wr_evt[c]) wr_pend[c] <= 1;
			if (rd_evt[c]) rd_pend[c] <= 1;
			if (ch_we[c] == 2'b00) wr_pend[c] <= 0;      // write withdrawn
			if (!ch_rd[c] || ch_we[c] != 2'b00) rd_pend[c] <= 0;
		end

		case (state)
			ST_IDLE: begin
				sram_we_n <= 1;
				dq_oe     <= '0;
				if (do_wr) begin
					op_ch       <= wr_ch;
					sram_a      <= {wr_ch, ch_a[wr_ch]};
					dq_out      <= ch_d[wr_ch];
					sram_ub_n   <= ~ch_we[wr_ch][1];
					sram_lb_n   <= ~ch_we[wr_ch][0];
					sram_oe_n   <= 1;
					if (!wr_evt[wr_ch]) wr_pend[wr_ch] <= 0;
					state       <= ST_WR1;
				end
				else if (do_rd) begin
					op_ch     <= rd_ch;
					sram_a    <= {rd_ch, ch_a[rd_ch]};
					sram_ub_n <= 0;
					sram_lb_n <= 0;
					sram_oe_n <= 0;
					if (!rd_evt[rd_ch]) rd_pend[rd_ch] <= 0;
					cnt       <= cfg_rd - 1'd1;
					state     <= ST_RD;
				end
			end

			ST_RD: begin
				// rd_q samples the bus cfg_rd cycles after the address was launched (3 = 28 ns);
				// it is delivered on the next cycle (xfer), while the next access may start.
				if (cnt != 0) cnt <= cnt - 1'd1;
				else begin
					xfer    <= 1;
					xfer_ch <= op_ch;
					state   <= ST_IDLE;
				end
			end

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
