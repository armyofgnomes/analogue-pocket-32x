//
// 32X SDRAM front end: the SH-2 side of the 32X's 256 KB SDRAM, on one port of sdram.sv
// (REQ-MEM-03). Plays the role of MiSTer's ddram.sv in the default MiSTer build.
//
// The SH-2 bus controller treats this area as SDRAM. It only honors WAIT on the first beat of a
// read (TRCAS); the other beats of a burst (a 16-byte cache-line fill is 8 beats) follow one per
// SH-2 cycle. Writes honor WAIT once per beat (TRAS). sdram.sv answers one 16-bit word per
// request, much slower than a burst, so:
//   - Reads go through a 16-byte line buffer. A miss holds WAIT while the whole line (8 words) is
//     fetched with one sdram.sv line read (patch 0008: 8 back-to-back column reads of one row);
//     then every beat of the burst is served from the buffer, combinationally.
//   - Writes go into a queue, waiting only when it is full. Each beat (WE rising, or address/byte
//     enables changing while WE is held) is one entry. A write that hits the line buffer also
//     updates it. The queue drains to SDRAM ahead of line fills, so a fill sees every earlier write.
// Without this, burst beats after the first returned stale data (full-system sim: the slave SH-2
// read its code as d116d116, e000e000, ... and crashed right after the BIOS handed over).
//
// Address mapping inside the port's SDRAM bank (bank 2; no other port uses it): sdram.sv takes the
// row from word address bits [13:1] and the column from [22:14], so a 32X word address w is placed
// as row = w[17:10], column = w[9:1]. A 16-byte line is then 8 consecutive columns of one row.
//
// All logic runs on clk_sys, the SH-2 bus clock. The SDRAM port is edge-triggered with a busy
// that is high from one clk_sys cycle after the request until the access is done.
//

module s32x_sdram_front
(
	input             clk,
	input             reset,

	// SH-2 side (32X.sv SDR_*)
	input      [17:1] a,
	input      [15:0] d,          // write data
	input             cs,
	input             rd,
	input       [1:0] we,         // byte write enables [1] = upper
	output     [15:0] q,          // read data
	output            wait_o,

	// sdram.sv port
	output reg [24:1] p_addr,
	output reg        p_rd,
	output reg  [1:0] p_wr,
	output reg [15:0] p_din,
	output reg        p_line,       // this read is a line read (8 words into p_dout_line)
	input     [127:0] p_dout_line,  // word 0 in [127:112]
	input             p_busy,

	output reg        overflow    // sticky: a write was lost (the SH-2 didn't wait on a full queue)
);

function automatic [24:1] sdr_addr(input [17:1] w);
	sdr_addr = {2'b10, w[9:1], 5'b00000, w[17:10]};   // bank 2, column w[9:1], row w[17:10]
endfunction

// Line buffer
reg  [17:4] lb_tag = 0;
reg         lb_valid = 0;
reg  [15:0] lb_data [8];
reg         filling = 0;
reg   [7:0] fill_wmask = 0;              // words written while this line was being filled

wire        r_req = cs & rd;
wire        hit   = lb_valid && (lb_tag == a[17:4]);
assign      q      = lb_data[a[3:1]];

// Write queue
localparam  QW = 3;
reg  [17:1] wq_a [1<<QW];
reg  [15:0] wq_d [1<<QW];
reg   [1:0] wq_we[1<<QW];
reg  [QW-1:0] wq_head = 0, wq_tail = 0;
reg  [QW:0]   wq_count = 0;

wire        w_req = cs & (|we);
reg         w_prev = 0;
reg         w_held = 0;
reg  [18:0] w_key = 0;
wire [18:0] w_cur = {a, we};
wire        w_new = w_req && (!w_prev || w_cur != w_key);
wire        wq_full = (wq_count == (1 << QW));
wire        w_take = w_new && !wq_full;         // a new beat with the queue full waits (TRAS)

assign      wait_o = (r_req & ~hit) | (w_new & wq_full);

// Port driver
localparam PS_IDLE = 3'd0, PS_W1 = 3'd1, PS_BUSY = 3'd2, PS_GAP = 3'd3;
reg   [2:0] ps = PS_IDLE;
reg         op_wr = 0;                   // current port access is a queued write

wire        wq_pop = (ps == PS_BUSY) && !p_busy && op_wr;

always @(posedge clk) begin
	if (reset) begin
		lb_valid   <= 0;
		filling    <= 0;
		fill_wmask <= 0;
		wq_head    <= 0;
		wq_tail    <= 0;
		wq_count   <= 0;
		w_prev     <= 0;
		ps         <= PS_IDLE;
		p_rd       <= 0;
		p_wr       <= 0;
		p_line     <= 0;
		overflow   <= 0;
	end
	else begin
		// Capture writes (never stalled: the SH-2 ignores WAIT for writes to this area)
		// A beat that finds the queue full keeps w_new set (its key isn't recorded) and waits.
		if (!w_new || w_take) w_prev <= w_req;
		w_held <= w_new & wq_full;
		if (w_held && !w_req) overflow <= 1;               // a held beat went away untaken
		if (w_take) begin
			w_key <= w_cur;
			wq_a[wq_tail]  <= a;
			wq_d[wq_tail]  <= d;
			wq_we[wq_tail] <= we;
			wq_tail        <= wq_tail + 1'd1;
			if (lb_tag == a[17:4]) begin
				if (we[1]) lb_data[a[3:1]][15:8] <= d[15:8];
				if (we[0]) lb_data[a[3:1]][7:0]  <= d[7:0];
				if (filling) fill_wmask[a[3:1]] <= 1;
			end
		end
		wq_count <= wq_count + w_take - wq_pop;

		// Start a line fill on a read miss
		if (r_req && !hit && !filling) begin
			lb_tag     <= a[17:4];
			lb_valid   <= 0;
			filling    <= 1;
			fill_wmask <= 0;
		end

		// One SDRAM access at a time: queued writes first, then the fill
		case (ps)
			PS_IDLE:
				if (wq_count != 0) begin
					p_addr <= sdr_addr(wq_a[wq_head]);
					p_din  <= wq_d[wq_head];
					p_wr   <= wq_we[wq_head];
					p_line <= 0;
					op_wr  <= 1;
					ps     <= PS_W1;
				end
				else if (filling) begin
					p_addr <= sdr_addr({lb_tag, 3'd0});
					p_rd   <= 1;
					p_line <= 1;
					op_wr  <= 0;
					ps     <= PS_W1;
				end
			PS_W1: ps <= PS_BUSY;                    // busy is up from here on
			PS_BUSY:
				if (!p_busy) begin
					p_rd <= 0;
					p_wr <= 0;
					if (op_wr) begin
						wq_head <= wq_head + 1'd1;
					end
					else begin
						for (int i = 0; i < 8; i++)
							if (!fill_wmask[i]) lb_data[i] <= p_dout_line[127 - 16*i -: 16];
						filling  <= 0;
						lb_valid <= 1;
					end
					ps <= PS_GAP;
				end
			PS_GAP: ps <= PS_IDLE;                   // strobes low for one mid clk_ram edge
			default: ps <= PS_IDLE;
		endcase
	end
end

endmodule
