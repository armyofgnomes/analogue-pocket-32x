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
// The state machine runs on clk_ram (2x clk_sys, same PLL) and samples the clk_sys-domain
// requests directly, like upstream sdram.sv. One SRAM access at a time:
//   read  = 4 clk_ram cycles (address, then capture 3 cycles = 28 ns later)
//   write = 4 clk_ram cycles (address setup, WE low x2, hold)
// Priority: draw buffer (write, or read that isn't cached) first, then a display read whose
// address changed. The draw buffer comes from the VDP's FS bit (patch 0004 exports it as FB_FS).
// A heuristic based on RD levels was tried first and failed in simulation right after a buffer
// swap, when the new draw buffer's first access is a read.
// Worst-case latency (sample + access in progress + own access, plus one draw access ahead of a
// display read): draw 1 + 4 + 4 = 9 clk_ram (deadline 12), display 1 + 4 + 4 + 4 = 13 (deadline 16).
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

	// Async SRAM pins
	output reg [16:0] sram_a,
	inout      [15:0] sram_dq,
	output reg        sram_oe_n,
	output reg        sram_we_n,
	output reg        sram_ub_n,
	output reg        sram_lb_n
);

// Requests, sampled from the clk_sys domain
wire [15:0] ch_a [2] = '{FB0_A,  FB1_A};
wire [15:0] ch_d [2] = '{FB0_DO, FB1_DO};
wire  [1:0] ch_we[2] = '{FB0_WE, FB1_WE};
wire        ch_rd[2] = '{FB0_RD, FB1_RD};

wire draw_ch = ~FB_FS;

// Per-channel bookkeeping
reg        wr_done  [2];   // current write (A/D/WE) already performed
reg [15:0] wr_a     [2];
reg [15:0] wr_d     [2];
reg  [1:0] wr_we    [2];
reg        rd_valid [2];   // FBx_DI holds the data for rd_a
reg [15:0] rd_a     [2];

function automatic wr_pending(input bit c);
	wr_pending = (ch_we[c] != 2'b00) &&
	             !(wr_done[c] && wr_a[c] == ch_a[c] && wr_d[c] == ch_d[c] && wr_we[c] == ch_we[c]);
endfunction

function automatic rd_pending(input bit c);
	rd_pending = ch_rd[c] && (ch_we[c] == 2'b00) && !(rd_valid[c] && rd_a[c] == ch_a[c]);
endfunction

localparam ST_IDLE = 3'd0;
localparam ST_RD1  = 3'd1;
localparam ST_RD2  = 3'd2;
localparam ST_RD3  = 3'd6;
localparam ST_WR1  = 3'd3;
localparam ST_WR2  = 3'd4;
localparam ST_WR3  = 3'd5;

reg  [2:0] state;
reg        op_ch;
reg [15:0] op_a;
reg [15:0] dq_out;
reg        dq_oe;

assign sram_dq = dq_oe ? dq_out : 16'hZZZZ;

// Choose the next access: draw channel first, then the display channel.
// (always_comb, not continuous assigns: a function call in an assign only re-evaluates when
// its arguments change, not when the signals it reads change.)
wire       dc = draw_ch;
wire       pc = ~draw_ch;
logic      go_wr_d, go_rd_d, go_wr_p, go_rd_p;
always_comb begin
	go_wr_d = wr_pending(dc);
	go_rd_d = rd_pending(dc);
	go_wr_p = wr_pending(pc);
	go_rd_p = rd_pending(pc);
end

always @(posedge clk_ram) begin
	// A write to a channel makes its cached read data stale; a WE drop re-arms writes.
	for (int c = 0; c < 2; c++) begin
		if (ch_we[c] == 2'b00) wr_done[c] <= 0;
	end

	if (reset) begin
		state     <= ST_IDLE;
		sram_oe_n <= 1;
		sram_we_n <= 1;
		sram_ub_n <= 1;
		sram_lb_n <= 1;
		dq_oe     <= 0;
		for (int c = 0; c < 2; c++) begin
			wr_done[c]  <= 0;
			rd_valid[c] <= 0;
		end
	end
	else begin
		case (state)
			ST_IDLE: begin
				sram_we_n <= 1;
				dq_oe     <= 0;
				if (go_wr_d || (!go_rd_d && go_wr_p)) begin
					op_ch       <= go_wr_d ? dc : pc;
					op_a        <= ch_a[go_wr_d ? dc : pc];
					sram_a      <= {go_wr_d ? dc : pc, ch_a[go_wr_d ? dc : pc]};
					dq_out      <= ch_d[go_wr_d ? dc : pc];
					sram_ub_n   <= ~ch_we[go_wr_d ? dc : pc][1];
					sram_lb_n   <= ~ch_we[go_wr_d ? dc : pc][0];
					sram_oe_n   <= 1;
					wr_a [go_wr_d ? dc : pc] <= ch_a [go_wr_d ? dc : pc];
					wr_d [go_wr_d ? dc : pc] <= ch_d [go_wr_d ? dc : pc];
					wr_we[go_wr_d ? dc : pc] <= ch_we[go_wr_d ? dc : pc];
					state       <= ST_WR1;
				end
				else if (go_rd_d || go_rd_p) begin
					op_ch     <= go_rd_d ? dc : pc;
					op_a      <= ch_a[go_rd_d ? dc : pc];
					sram_a    <= {go_rd_d ? dc : pc, ch_a[go_rd_d ? dc : pc]};
					sram_ub_n <= 0;
					sram_lb_n <= 0;
					sram_oe_n <= 0;
					state     <= ST_RD1;
				end
			end

			ST_RD1: state <= ST_RD2;
			ST_RD2: state <= ST_RD3;
			ST_RD3: begin
				// Capture three cycles (28 ns) after the address was launched.
				if (op_ch) FB1_DI <= sram_dq; else FB0_DI <= sram_dq;
				rd_a[op_ch]     <= op_a;
				rd_valid[op_ch] <= 1;
				state <= ST_IDLE;
			end

			// Write: setup cycle with OE high and DQ still released (bus turnaround),
			// then WE low for two cycles with data driven, then a hold cycle.
			ST_WR1: begin
				dq_oe     <= 1;
				sram_we_n <= 0;
				state     <= ST_WR2;
			end
			ST_WR2: state <= ST_WR3;
			ST_WR3: begin
				sram_we_n <= 1;
				wr_done[op_ch]  <= 1;
				rd_valid[op_ch] <= 0;
				state <= ST_IDLE;
			end
		endcase
	end
end

endmodule
